// One plain TextEdit per block. The text is set ONCE from the model when the
// item is created; afterwards edits flow model-ward through `edited`, never
// back into `text`, so the cursor is never disturbed by saves.
import QtQuick

TextEdit {
  id: edit

  property string initialText: ""
  property var palette: null
  property int fontSize: 15
  property bool multiline: false        // code: Enter inserts a newline

  signal edited(string text)
  signal enterPressed()
  signal backspaceOnEmpty()
  signal upAtStart()
  signal downAtEnd()
  signal tabPressed()
  signal pasteRequested()      // Ctrl+V: the row decides between an image block and text
  property bool pickerActive: false
  signal pickerMove(int delta)
  signal pickerAccept()
  signal pickerCancel()

  width: parent ? parent.width : implicitWidth
  height: Math.max(implicitHeight, fontSize * 1.4)
  textFormat: TextEdit.PlainText
  wrapMode: TextEdit.Wrap
  selectByMouse: true
  persistentSelection: false
  font.pixelSize: fontSize
  color: palette ? palette.foreground : "#f8f8f2"
  selectionColor: palette ? palette.selection : "#6272a4"
  selectedTextColor: palette ? palette.foreground : "#f8f8f2"
  cursorVisible: activeFocus
  activeFocusOnTab: false

  property bool syncing: false
  property bool userEdited: false

  Component.onCompleted: text = initialText
  // If the row arrives after creation, adopt its content unless the user already typed.
  onInitialTextChanged: if (!userEdited && !activeFocus) syncText(initialText)
  onTextChanged: if (!syncing && (text !== initialText || activeFocus)) { userEdited = true; edited(text) }

  // Model-driven reset (type conversion cleared the content): no echo back.
  function syncText(t) {
    if (text === t) return
    syncing = true
    text = t
    cursorPosition = length
    syncing = false
  }

  function focusAt(atEnd) {
    forceActiveFocus()
    cursorPosition = atEnd ? length : 0
  }

  function wrapSelection(left, right) {
    var s = selectionStart, e = selectionEnd
    if (s === e) { insert(s, left + right); cursorPosition = s + left.length; return }
    var sel = getText(s, e)
    remove(s, e)
    insert(s, left + sel + right)
    select(s + left.length, s + left.length + sel.length)
  }

  Keys.onPressed: function(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var shift = event.modifiers & Qt.ShiftModifier
    if (ctrl && !shift && event.key === Qt.Key_B) { wrapSelection("**", "**"); event.accepted = true; return }
    if (ctrl && !shift && event.key === Qt.Key_I) { wrapSelection("*", "*"); event.accepted = true; return }
    if (ctrl && !shift && event.key === Qt.Key_U) { wrapSelection("<u>", "</u>"); event.accepted = true; return }
    if (ctrl && !shift && event.key === Qt.Key_V) { edit.pasteRequested(); event.accepted = true; return }
    if (ctrl || (event.modifiers & Qt.AltModifier)) return   // window-level shortcuts handle the rest

    if (edit.pickerActive) {
      if (event.key === Qt.Key_Up)   { edit.pickerMove(-1); event.accepted = true; return }
      if (event.key === Qt.Key_Down) { edit.pickerMove(1); event.accepted = true; return }
      if (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ControlModifier))  { edit.pickerMove(1); event.accepted = true; return }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { edit.pickerAccept(); event.accepted = true; return }
      if (event.key === Qt.Key_Escape) { edit.pickerCancel(); event.accepted = true; return }
    }

    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      if (edit.multiline && !(event.modifiers & Qt.ShiftModifier)) return   // plain newline in code
      if (!edit.multiline && shift) return                                  // Shift+Enter: newline in text
      edit.enterPressed(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Backspace && edit.length === 0) {
      edit.backspaceOnEmpty(); event.accepted = true; return
    }
    // Leave the block from its first / last visual line (not only from the very ends).
    var noSelection = edit.selectionStart === edit.selectionEnd
    if (event.key === Qt.Key_Up && noSelection && edit.cursorRectangle.y <= 1) {
      edit.upAtStart(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Down && noSelection && edit.cursorRectangle.y + edit.cursorRectangle.height >= edit.contentHeight - 1) {
      edit.downAtEnd(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ControlModifier)) { edit.tabPressed(); event.accepted = true; return }
  }
}
