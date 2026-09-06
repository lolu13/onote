// Resolves a note's themeName into colours. For "system" (and unknown names)
// every property binds straight to Omarchy's Color singleton, so a theme
// switch repaints open notes live.
import QtQuick
import qs.Commons
import "Themes.js" as Themes

QtObject {
  id: palette

  property string themeName: "system"
  property var customThemes: []

  readonly property var custom: Themes.resolve(themeName, customThemes)
  readonly property bool isSystem: custom === null

  readonly property color background:      custom ? custom.background      : Color.background
  readonly property color foreground:      custom ? custom.foreground      : Color.foreground
  readonly property color accentPrimary:   custom ? custom.accentPrimary   : Color.accent
  readonly property color accentSecondary: custom ? custom.accentSecondary : Color.muted
  readonly property color comment:         custom ? custom.comment         : Color.muted
  readonly property color currentLine:     custom ? custom.currentLine     : Color.menu.selectedBackground
  readonly property var labelColors:       custom ? custom.labelColors
                                                  : [Color.accent, Color.muted, Color.urgent, Color.foreground]
  readonly property color selection: Qt.rgba(accentPrimary.r, accentPrimary.g, accentPrimary.b, 0.35)
}
