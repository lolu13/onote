// A small red square in a note's bottom-right corner while a newer Onote is
// published. Hover names it; a click runs the update in a terminal (see
// scripts/update.py), where Omarchy's own updater shows the diff and asks.
import QtQuick

Item {
  id: badge

  property bool available: false
  property int size: 12
  property var palette: null
  property string fontFamily: ""
  property int fontSize: 12
  signal activated()

  visible: badge.available
  width: badge.size
  height: badge.size

  // Built only while hovered: every open note carries a badge, most never show it.
  Loader {
    active: hover.containsMouse
    anchors { right: parent.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
    sourceComponent: Rectangle {
      width: hintText.implicitWidth + 12
      height: hintText.implicitHeight + 6
      radius: 0
      color: badge.palette ? badge.palette.background : "#202020"
      border.width: 1
      border.color: badge.palette ? badge.palette.currentLine : "#808080"
      Text {
        id: hintText
        anchors.centerIn: parent
        text: "Onote update · click to install"
        textFormat: Text.PlainText
        font.family: badge.fontFamily
        font.pixelSize: badge.fontSize
        color: badge.palette ? badge.palette.foreground : "#e0e0e0"
      }
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: 0
    color: hover.containsMouse ? "#ff5a5a" : "#e0393e"
    Behavior on color { ColorAnimation { duration: 150 } }
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: badge.activated()
  }
}
