// image: displays the embedded data: URI. Decoded asynchronously, capped at
// 1024px wide in memory, never cached (the cache key would be the whole URI).
//
// A block's src comes from the note row, which the helper writes but a shared
// database (or a hand-edited note) can also carry. Only a base64 data: URI in
// one of the three formats the helper produces reaches Image.source: anything
// else (file://, http://, a local path) would make the shell process open it.
import QtQuick

FocusScope {
  id: block

  property var row: null
  readonly property var pal: row ? row.palette : null
  readonly property int size: row ? row.fontSize : 15
  readonly property int wanted: row && row.imageWidth > 0 ? row.imageWidth : 300
  // Painted height cap: three times the wanted width leaves a phone screenshot
  // (9:19.5) untouched and bounds a valid 1×8192 strip, which would otherwise
  // paint 300 px wide and two and a half million px tall, the note's scroll
  // extent with it. The height is decided first, the width follows the ratio.
  readonly property int maxHeight: block.wanted * 3

  // Prefix match plus one linear scan for anything outside the base64 alphabet,
  // so validating a multi-megabyte src stays a single pass with no backtracking.
  readonly property string src: {
    var s = row ? String(row.src || "") : ""
    if (s.indexOf("data:image/png;base64,") !== 0
        && s.indexOf("data:image/jpeg;base64,") !== 0
        && s.indexOf("data:image/gif;base64,") !== 0) return ""
    var body = s.slice(s.indexOf(",") + 1)
    if (!body.length || /[^A-Za-z0-9+\/=]/.test(body)) return ""
    return s
  }
  readonly property bool rejected: row && String(row.src || "").length > 0 && block.src.length === 0
  // What was decoded (tests check the decode never grows an image).
  readonly property bool decoded: img.status === Image.Ready
  readonly property bool failed: img.status === Image.Error
  readonly property size decodedSize: Qt.size(img.implicitWidth, img.implicitHeight)

  width: parent ? parent.width : 0
  height: img.status === Image.Ready ? img.height + 4 : block.size * 3

  function focusEditor(atEnd) { block.forceActiveFocus() }

  Rectangle {
    anchors.fill: parent
    color: "transparent"
    border.width: block.activeFocus ? 2 : 0
    border.color: pal ? pal.accentPrimary : "#ff79c6"
  }

  // Stretch, not PreserveAspectFit: with a fit mode Qt scales the decode to
  // the requested width even upward, so a valid 1×8192 image would be decoded
  // at 1024×8388608. With Stretch the 1024 px request only ever shrinks, and
  // the aspect ratio is kept by sizing the item from the decoded image.
  Image {
    id: img
    x: 2; y: 2
    readonly property real fitWidth: Math.min(block.wanted, block.width - 4)
    height: implicitWidth > 0 ? Math.max(1, Math.min(block.maxHeight, Math.round(fitWidth * implicitHeight / implicitWidth))) : 0
    width: implicitHeight > 0 ? Math.min(fitWidth, Math.max(1, Math.round(height * implicitWidth / implicitHeight))) : fitWidth
    source: block.src
    asynchronous: true
    cache: false
    fillMode: Image.Stretch
    sourceSize.width: 1024
    smooth: true
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: block.rejected || img.status === Image.Error || img.status === Image.Loading
    text: block.rejected || img.status === Image.Error ? "image could not be decoded" : "loading image…"
    color: pal ? pal.comment : "#6272a4"
    font.pixelSize: block.size
    font.family: row ? row.fontFamily : ""
  }

  MouseArea { anchors.fill: parent; onClicked: block.forceActiveFocus() }

  Keys.onPressed: function(event) {
    if (!row) return
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
    switch (event.key) {
      case Qt.Key_Backspace: case Qt.Key_Delete: row.remove(); event.accepted = true; break
      case Qt.Key_Return: case Qt.Key_Enter: row.enter(); event.accepted = true; break
      case Qt.Key_Up: row.moveFocus(-1); event.accepted = true; break
      case Qt.Key_Down: row.moveFocus(1); event.accepted = true; break
    }
  }
}
