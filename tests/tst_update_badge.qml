// The update square is invisible until an update exists, then one click asks
// the service to run the update.
import QtQuick
import QtTest
import ".."

Item {
  width: 200; height: 100
  property int clicks: 0
  UpdateBadge {
    id: badge
    anchors { right: parent.right; bottom: parent.bottom; margins: 10 }
    size: 12
    onActivated: clicks++
  }

  TestCase {
    name: "UpdateBadge"
    when: windowShown
    function init() { badge.available = false; clicks = 0 }
    function test_hidden_until_available() {
      verify(!badge.visible)
      badge.available = true
      verify(badge.visible)
      compare(badge.width, 12); compare(badge.height, 12)
    }
    function test_click_activates_once() {
      badge.available = true
      mouseClick(badge, 6, 6)
      compare(clicks, 1)
    }
  }
}
