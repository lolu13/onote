// Inline block-type picker shown under a text block after typing "/".
// Keyboard only: the focused TextEdit forwards Up/Down/Enter/Esc while open.
import QtQuick

Rectangle {
  id: picker

  property var editor: null
  property var pal: null
  property int size: 15
  readonly property var items: editor ? editor.pickerItems : []
  readonly property int selected: editor ? editor.pickerSelection : 0

  width: Math.min(parent ? parent.width : 300, size * 18)
  height: items.length ? column.height + size * 0.6 : 0
  visible: items.length > 0
  radius: 0
  color: pal ? pal.currentLine : "#44475a"
  border.width: 1
  border.color: pal ? pal.accentPrimary : "#ff79c6"

  Column {
    id: column
    x: size * 0.3
    y: size * 0.3
    width: parent.width - size * 0.6

    Repeater {
      model: picker.items
      delegate: Rectangle {
        required property var modelData
        required property int index
        width: column.width
        height: picker.size * 1.7
        radius: 0
        color: index === picker.selected ? (picker.pal ? picker.pal.accentPrimary : "#ff79c6") : "transparent"

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.leftMargin: picker.size * 0.5
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.label
          font.pixelSize: picker.size
          font.bold: index === picker.selected
          color: index === picker.selected ? (picker.pal ? picker.pal.background : "#282a36") : (picker.pal ? picker.pal.foreground : "#f8f8f2")
        }
        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.rightMargin: picker.size * 0.5
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.hint
          font.pixelSize: Math.round(picker.size * 0.85)
          color: index === picker.selected ? (picker.pal ? picker.pal.background : "#282a36") : (picker.pal ? picker.pal.comment : "#6272a4")
        }
        MouseArea {
          anchors.fill: parent
          onClicked: { if (picker.editor) { picker.editor.pickerSelection = index; picker.editor.pickerAccept() } }
        }
      }
    }
  }
}
