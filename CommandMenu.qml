import QtQuick

FocusScope {
  id: menu
  property var palette: null
  property string fontFamily: ""
  property int fontSize: 14
  property var commands: []
  property string query: ""
  readonly property var matches: commands.filter(function(c) {
    return (c.label + " " + (c.keys || "")).toLowerCase().indexOf(menu.query.toLowerCase()) !== -1
  })
  signal triggered(string command)
  signal dismissed()
  visible: false
  z: 100
  onMatchesChanged: results.currentIndex = matches.length ? 0 : -1
  function open() {
    query = ""; search.text = ""
    results.currentIndex = matches.length ? 0 : -1   // onMatchesChanged stays quiet when the query was already empty
    visible = true; search.forceActiveFocus()
  }
  function cancel() { visible = false; dismissed() }
  function choose() {
    if (results.currentIndex < 0 || results.currentIndex >= matches.length) return
    var id = matches[results.currentIndex].id
    visible = false
    triggered(id)
  }
  function move(delta) {
    if (matches.length) results.currentIndex = (results.currentIndex + delta + matches.length) % matches.length
  }
  Rectangle { anchors.fill: parent; color: "#66000000" }
  MouseArea { anchors.fill: parent; onClicked: menu.cancel() }
  Rectangle {
    anchors.centerIn: parent
    width: Math.min(parent.width - 24, menu.fontSize * 48)
    height: Math.min(parent.height - 24, menu.fontSize * 30)
    color: menu.palette ? menu.palette.background : "#222222"
    border.width: 1; border.color: menu.palette ? menu.palette.accentPrimary : "#ffffff"
    MouseArea { anchors.fill: parent }
    Column {
      anchors.fill: parent; anchors.margins: 12; spacing: 10
      Text {
        id: heading
        text: "Onote commands"; font.bold: true
        font.family: menu.fontFamily; font.pixelSize: menu.fontSize
        color: menu.palette ? menu.palette.accentPrimary : "#ffffff"
      }
      Rectangle {
        id: searchBox
        width: parent.width; height: menu.fontSize * 2.2
        color: menu.palette ? menu.palette.currentLine : "#444444"
        TextInput {
          id: search
          anchors.fill: parent; anchors.margins: 6
          font.family: menu.fontFamily; font.pixelSize: menu.fontSize
          color: menu.palette ? menu.palette.foreground : "#ffffff"
          selectByMouse: true; clip: true
          onTextEdited: menu.query = text
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) menu.cancel()
            else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) menu.move(-1)
            else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) menu.move(1)
            else if (event.key === Qt.Key_PageUp) results.currentIndex = Math.max(0, results.currentIndex - 6)
            else if (event.key === Qt.Key_PageDown) results.currentIndex = Math.min(menu.matches.length - 1, results.currentIndex + 6)
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) menu.choose()
            else { event.accepted = false; return }
            event.accepted = true
          }
          Text {
            anchors.fill: parent; visible: !search.text.length
            text: "Type to find an action or shortcut…"
            color: menu.palette ? menu.palette.comment : "#aaaaaa"
            font: search.font
          }
        }
      }
      ListView {
        id: results
        width: parent.width; height: parent.height - heading.height - searchBox.height - footer.height - parent.spacing * 3
        model: menu.matches; clip: true
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        delegate: Rectangle {
          required property var modelData
          required property int index
          width: results.width; height: menu.fontSize * 2.2
          color: index === results.currentIndex ? (menu.palette ? menu.palette.currentLine : "#444444") : "transparent"
          Row {
            anchors.fill: parent; anchors.margins: 5; spacing: 8
            Text {
              width: parent.width * 0.62; elide: Text.ElideRight
              text: modelData.label
              color: menu.palette ? menu.palette.foreground : "#ffffff"
              font.family: menu.fontFamily; font.pixelSize: menu.fontSize
            }
            Text {
              width: parent.width * 0.38 - parent.spacing; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight
              text: modelData.keys || ""
              color: menu.palette ? menu.palette.accentPrimary : "#dddddd"
              font.family: menu.fontFamily; font.pixelSize: menu.fontSize
            }
          }
          MouseArea { anchors.fill: parent; onClicked: { results.currentIndex = index; menu.choose() } }
        }
        Text {
          visible: !menu.matches.length; anchors.centerIn: parent
          text: "No matching commands"; color: menu.palette ? menu.palette.comment : "#aaaaaa"
          font.family: menu.fontFamily; font.pixelSize: menu.fontSize
        }
      }
      Text {
        id: footer
        text: "↑↓ / Tab select · Enter run · Esc back"
        font.family: menu.fontFamily; font.pixelSize: Math.round(menu.fontSize * 0.85)
        color: menu.palette ? menu.palette.comment : "#aaaaaa"
      }
    }
  }
}
