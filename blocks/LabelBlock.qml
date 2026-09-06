// label: a coloured badge holding the label name, followed by the value text.
import QtQuick

Item {
  id: block

  property var row: null
  readonly property var pal: row ? row.palette : null
  readonly property int size: row ? row.fontSize : 15
  readonly property string badgeColor: {
    var c = row ? row.color : ""
    if (/^#[0-9a-fA-F]{6}$/.test(c)) return c
    return pal ? String(pal.accentPrimary) : "#ff79c6"
  }
  readonly property color fg: pal ? pal.foreground : "#f8f8f2"
  readonly property color dim: pal ? pal.comment : "#6272a4"

  width: parent ? parent.width : 0
  height: Math.max(badge.height, value.height)

  // An unnamed label always takes focus on its name first; a named one goes to the value.
  function focusEditor(atEnd) {
    if (row && (row.label || "").length === 0) block.focusLabel()
    else value.focusAt(atEnd)
  }
  function focusLabel() { labelInput.forceActiveFocus(); labelInput.cursorPosition = labelInput.length }

  Rectangle {
    id: badge
    width: Math.min(Math.max(labelInput.contentWidth + block.size * 1.2, block.size * 4), block.width * 0.5)
    height: Math.max(labelInput.height + block.size * 0.4, block.size * 1.6)
    radius: 0
    color: Qt.rgba(Qt.color(block.badgeColor).r, Qt.color(block.badgeColor).g, Qt.color(block.badgeColor).b, 0.18)

    Rectangle { width: 3; height: parent.height; color: block.badgeColor }

    TextInput {
      id: labelInput
      anchors.left: parent.left
      anchors.leftMargin: block.size * 0.6
      anchors.right: parent.right
      anchors.rightMargin: block.size * 0.4
      anchors.verticalCenter: parent.verticalCenter
      text: row ? row.label : ""
      font.pixelSize: block.size
      font.family: row ? row.fontFamily : ""
      font.bold: true
      color: block.badgeColor
      selectByMouse: true
      clip: true
      maximumLength: 200
      activeFocusOnTab: false

      Text {
        textFormat: Text.PlainText
        anchors.fill: parent
        visible: !labelInput.text.length && !labelInput.activeFocus
        text: "Label"
        font: labelInput.font
        color: block.dim
      }

      onTextEdited: if (row) row.setLabel(text)
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Tab) { value.focusAt(true); event.accepted = true; return }
        if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
          if (row) row.enter(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Backspace && labelInput.length === 0 && value.length === 0) {
          if (row) row.backspaceOnEmpty(); event.accepted = true; return
        }
        if (event.key === Qt.Key_Up && labelInput.cursorPosition === 0) { if (row) row.moveFocus(-1); event.accepted = true; return }
        if (event.key === Qt.Key_Down && labelInput.cursorPosition === labelInput.length) { if (row) row.moveFocus(1); event.accepted = true; return }
      }
    }
  }

  BlockTextEdit {
    id: value
    x: badge.width + block.size * 0.6
    width: parent.width - x
    y: Math.max(0, (badge.height - height) / 2)
    initialText: row ? row.content : ""
    palette: block.pal
    fontSize: block.size
    font.family: row ? row.fontFamily : ""
    color: block.fg

    onEdited: function(t) { if (row) row.setContent(t) }
    onEnterPressed: if (row) row.enter()
    onBackspaceOnEmpty: {
      if (!row) return
      if ((row.label || "").length) block.focusLabel()
      else row.backspaceOnEmpty()
    }
    onUpAtStart: if (row) row.moveFocus(-1)
    onDownAtEnd: if (row) row.moveFocus(1)
    onTabPressed: {}
  }
}
