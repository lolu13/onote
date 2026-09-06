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

  width: parent ? parent.width : 0
  height: img.status === Image.Ready ? img.height + 4 : block.size * 3

  function focusEditor(atEnd) { block.forceActiveFocus() }

  Rectangle {
    anchors.fill: parent
    color: "transparent"
    border.width: block.activeFocus ? 2 : 0
    border.color: pal ? pal.accentPrimary : "#ff79c6"
  }

  Image {
    id: img
    x: 2; y: 2
    width: Math.min(block.wanted, block.width - 4)
    source: block.src
    asynchronous: true
    cache: false
    fillMode: Image.PreserveAspectFit
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
    switch (event.key) {
      case Qt.Key_Backspace: case Qt.Key_Delete: row.remove(); event.accepted = true; break
      case Qt.Key_Return: case Qt.Key_Enter: row.enter(); event.accepted = true; break
      case Qt.Key_Up: row.moveFocus(-1); event.accepted = true; break
      case Qt.Key_Down: row.moveFocus(1); event.accepted = true; break
    }
  }
}
