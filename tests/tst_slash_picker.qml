import QtQuick
import QtTest
import ".."
import "../Themes.js" as Themes

Item {
  width: 600; height: 480
  QtObject {
    id: testPalette
    property var colors: ({})
    property color foreground: colors.foreground || "#eeeeee"
    property color background: colors.background || "#333333"
    property color accentPrimary: colors.accentPrimary || "#a58a42"
    property color accentSecondary: colors.accentSecondary || "#c89f50"
    property color currentLine: colors.currentLine || "#555555"
    property color comment: colors.comment || "#888888"
    property color selection: "#777777"
    property var labelColors: ["#a58a42"]
  }
  QtObject {
    id: testStore
    property string saved: ""
    function updateNote(id, patch) { saved = patch.contentBlocks }
  }
  BlockEditor {
    id: editor
    anchors.fill: parent
    palette: testPalette
    store: testStore
    noteId: "isolated-test-note"
    fontFamily: "monospace"
  }
  TestCase {
    name: "SlashPickerLifecycle"
    when: windowShown
    function menus(item, result) {
      result = result || []
      if (String(item).indexOf("SlashPicker_QMLTYPE") === 0) result.push(item)
      var children = item.children || []
      for (var i = 0; i < children.length; i++) menus(children[i], result)
      return result
    }
    function init() {
      editor.pickerClose()
      var blocks = [{ type: "text", content: "" }]
      for (var i = 1; i < 300; i++) blocks.push({ type: "text", content: "Block " + i })
      editor.load(JSON.stringify(blocks))
      testStore.saved = ""
      wait(0)
    }
    function test_keyboard_menu_data() {
      var data = []
      var names = Themes.BUILTIN_NAMES.concat(["system-test", "custom-light-test"])
      for (var i = 0; i < names.length; i++) {
        var colors = Themes.resolve(names[i], []) || {}
        if (names[i] === "custom-light-test") colors = { foreground: "#302d23", background: "#f7f0df", currentLine: "#ded5bf" }
        for (var j = 0; j < 3; j++) {
          var size = [14, 24, 32][j]
          data.push({ tag: names[i] + "-" + size, colors: colors, size: size })
        }
      }
      return data
    }
    function test_keyboard_menu(data) {
      testPalette.colors = data.colors
      editor.fontSize = data.size
      editor.focusBlock(0, false)
      wait(0)
      compare(menus(editor).length, 0)
      keyClick(Qt.Key_Slash)
      tryCompare(editor, "pickerIndex", 0)
      var active = menus(editor)
      compare(active.length, 1, "Only the focused row may instantiate a menu")
      compare(active[0].items.length, 7)
      verify(active[0].width > 0 && active[0].width <= editor.width)
      verify(active[0].height > 0)
      keyClick(Qt.Key_C)
      keyClick(Qt.Key_O)
      tryCompare(editor, "pickerFilter", "co")
      compare(menus(editor)[0].items.length, 1)
      compare(menus(editor)[0].items[0].type, "code")
      keyClick(Qt.Key_Return)
      tryCompare(editor, "pickerIndex", -1)
      compare(menus(editor).length, 0)
      keyClick(Qt.Key_A)
      editor.flush()
      var saved = JSON.parse(testStore.saved)
      compare(saved.length, 300)
      compare(saved[0].type, "code")
      compare(saved[0].content, "a", "Focus and typing must survive menu destruction")
    }
    function test_mouse_selection_survives_menu_destruction() {
      editor.fontSize = 14
      editor.focusBlock(0, false)
      wait(0)
      keyClick(Qt.Key_Slash)
      var active = menus(editor)
      compare(active.length, 1)
      // Second menu row is Heading. A click destroys the menu's Loader item.
      mouseClick(active[0], active[0].width / 2, 14 * (0.3 + 1.7 * 1.5))
      tryCompare(editor, "pickerIndex", -1)
      compare(menus(editor).length, 0)
      editor.flush()
      compare(JSON.parse(testStore.saved)[0].type, "subtitle")
    }
    function test_switching_rows_does_not_retain_menus() {
      editor.pickerOpen(0, "")
      compare(menus(editor).length, 1)
      editor.pickerOpen(250, "")
      compare(menus(editor).length, 1)
      editor.pickerClose()
      compare(menus(editor).length, 0)
    }
  }
}
