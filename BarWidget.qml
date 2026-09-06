import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "lolu13.desknotes"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰎞"
    tooltipText: "DeskNotes · Left: notes & stack · Middle: new note · Right: stack all"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton)
        Quickshell.execDetached(["/usr/bin/omarchy-shell", "desknotes", "newNote"])
      else if (mouseButton === Qt.RightButton)
        Quickshell.execDetached(["/usr/bin/omarchy-shell", "desknotes", "hideAll"])
      else
        Quickshell.execDetached(["/usr/bin/omarchy-shell", "shell", "toggle", "lolu13.desknotes"])
    }
  }
}
