// divider: a 1px rule. Focusable so Backspace/Delete removes it and Enter
// continues below it.
import QtQuick

FocusScope {
  id: block

  property var row: null
  readonly property var pal: row ? row.palette : null
  readonly property int size: row ? row.fontSize : 15

  width: parent ? parent.width : 0
  height: block.size * 1.2

  function focusEditor(atEnd) { block.forceActiveFocus() }

  Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width
    height: block.activeFocus ? 2 : 1
    color: block.activeFocus ? (pal ? pal.accentPrimary : "#ff79c6") : (pal ? pal.comment : "#6272a4")
  }

  MouseArea { anchors.fill: parent; onClicked: block.forceActiveFocus() }

  Keys.onPressed: function(event) {
    if (!row) return
    switch (event.key) {
      case Qt.Key_Backspace: case Qt.Key_Delete: row.remove(); event.accepted = true; break
      case Qt.Key_Return: case Qt.Key_Enter: row.enter(); event.accepted = true; break
      case Qt.Key_Up: row.moveFocus(-1); event.accepted = true; break
      case Qt.Key_Down: row.moveFocus(1); event.accepted = true; break
    }
  }
}
