// code: monospace, multi-line, on a currentLine background. Enter inserts a
// newline; Enter on an empty last line leaves the block. Tab inserts 2 spaces.
import QtQuick

Item {
  id: block

  property var row: null
  readonly property var pal: row ? row.palette : null
  readonly property int size: row ? Math.max(10, row.fontSize - 1) : 14
  readonly property color fg: pal ? pal.foreground : "#f8f8f2"
  readonly property color bg: pal ? pal.currentLine : "#44475a"

  width: parent ? parent.width : 0
  height: edit.height + block.size * 1.2

  function focusEditor(atEnd) { edit.focusAt(atEnd) }

  Rectangle {
    anchors.fill: parent
    radius: 0
    color: block.bg
  }

  BlockTextEdit {
    id: edit
    x: block.size * 0.6
    y: block.size * 0.6
    width: parent.width - block.size * 1.2
    initialText: row ? row.content : ""
    palette: block.pal
    fontSize: block.size
    font.family: row ? row.fontFamily : "monospace"
    color: block.fg
    multiline: true

    onEdited: function(t) { if (row) row.setContent(t) }
    onEnterPressed: if (row) row.enter()   // only fired via Shift+Enter in multiline mode
    onBackspaceOnEmpty: if (row) row.backspaceOnEmpty()
    onUpAtStart: if (row) row.moveFocus(-1)
    onDownAtEnd: if (row) row.moveFocus(1)
    onTabPressed: {
      var p = edit.cursorPosition
      edit.insert(p, "  ")
      edit.cursorPosition = p + 2
    }

    Keys.onPressed: function(event) {
      // Enter on an empty trailing line: drop that line and leave the block.
      if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier))) {
        if (edit.cursorPosition === edit.length && edit.length > 0 && edit.text.charAt(edit.length - 1) === "\n") {
          edit.remove(edit.length - 1, edit.length)
          if (row) row.enter()
          event.accepted = true
        }
      }
    }
  }
}
