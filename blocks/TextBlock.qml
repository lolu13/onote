// text / subtitle / bullet / todo share this delegate; only the prefix differs.
import QtQuick

Item {
  id: block

  property var row: null           // BlockRow (index, type, content, checked, editor, palette, fontSize)
  readonly property string type: row ? row.type : "text"
  readonly property bool isTodo: type === "todo"
  readonly property bool isBullet: type === "bullet"
  readonly property bool isSubtitle: type === "subtitle"
  readonly property int baseSize: row ? row.fontSize : 15
  readonly property var pal: row ? row.palette : null
  readonly property color accent: pal ? pal.accentPrimary : "#ff79c6"
  readonly property color fg: pal ? pal.foreground : "#f8f8f2"
  readonly property color dim: pal ? pal.comment : "#6272a4"
  readonly property color accent2: pal ? pal.accentSecondary : "#bd93f9"
  readonly property bool checked: row ? row.checked : false
  readonly property int size: isSubtitle ? Math.round(baseSize * 1.25) : baseSize

  width: parent ? parent.width : 0
  height: Math.max(edit.height, prefix.height)

  function focusEditor(atEnd) { edit.focusAt(atEnd) }
  function toggleChecked() { if (isTodo && row) row.setChecked(!row.checked) }

  Item {
    id: prefix
    width: (isTodo || isBullet) ? block.size + 6 : 0
    height: block.size * 1.4
    visible: isTodo || isBullet

    // bullet: small filled square; todo: hollow square that fills when checked
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: 2
      width: isTodo ? block.size * 0.8 : block.size * 0.35
      height: width
      radius: 0
      color: isTodo ? (block.checked ? block.accent : "transparent") : block.accent
      border.width: isTodo ? 2 : 0
      border.color: block.accent
      MouseArea {
        anchors.fill: parent
        anchors.margins: -4
        enabled: isTodo
        cursorShape: Qt.PointingHandCursor
        onClicked: block.toggleChecked()
      }
    }
  }

  BlockTextEdit {
    id: edit
    x: prefix.width
    width: parent.width - prefix.width
    initialText: row ? row.content : ""
    palette: block.pal
    fontSize: block.size
    font.family: row ? row.fontFamily : ""
    font.bold: isSubtitle
    color: isTodo && block.checked ? block.dim : (isSubtitle ? block.accent2 : block.fg)
    font.strikeout: isTodo && block.checked

    onEdited: function(t) { row.setContent(t) }
    onEnterPressed: row.enter()
    onBackspaceOnEmpty: row.backspaceOnEmpty()
    onUpAtStart: row.moveFocus(-1)
    onDownAtEnd: row.moveFocus(1)
    onTabPressed: {}
    // An image on the clipboard becomes an image block; anything else pastes as text.
    onPasteRequested: {
      if (row && row.editor) row.editor.pasteImage(row.rowIndex, edit.length === 0, function(handled) { if (!handled) edit.paste() })
      else edit.paste()
    }

    // Same delegate serves text/bullet/todo/subtitle, so a type conversion that
    // clears the content must also reset the visible text.
    Connections {
      target: row
      function onContentChanged() { if (row) edit.syncText(row.content) }
    }

    pickerActive: row ? row.pickerActive : false
    onPickerMove: function(d) { if (row && row.editor) row.editor.pickerMove(d) }
    onPickerAccept: if (row && row.editor) row.editor.pickerAccept()
    onPickerCancel: if (row && row.editor) row.editor.pickerClose()

    Text {
      textFormat: Text.PlainText
      anchors.fill: parent
      visible: edit.length === 0 && row && row.rowIndex === 0 && row.editor && row.editor.count === 1 && !isTodo && !isBullet
      text: "Type here, or / for block types"
      font: edit.font
      color: block.dim
    }
  }
}
