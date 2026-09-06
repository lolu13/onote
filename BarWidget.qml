import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.lolu13.onote"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰎞"
    tooltipText: "Onote · Left: notes & stack · Middle: new note · Right: stack all"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton)
        Quickshell.execDetached(["/usr/bin/omarchy-shell", "onote", "newNote"])
      else if (mouseButton === Qt.RightButton)
        Quickshell.execDetached(["/usr/bin/omarchy-shell", "onote", "hideAll"])
      else
        Quickshell.execDetached(["/usr/bin/omarchy-shell", "shell", "toggle", "io.github.lolu13.onote"])
    }
  }
}
