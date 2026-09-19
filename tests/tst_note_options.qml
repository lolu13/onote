import QtQuick
import QtTest
import ".."
import "../ColumnLayout.js" as ColumnLayout

Item {
  QtObject {
    id: mock
    property var settings: ({})
    property var note: ({title: "Original"})
    property bool sawPendingDuringWrite: false
    function noteById(id) { return note }
    function getSetting(key, fallback) { return settings[key] === undefined ? fallback : settings[key] }
    function setSetting(key, value) { var next = Object.assign({}, settings); next[key] = value; settings = next }
    function updateNote(id, patch) { note = Object.assign({}, note, patch) }
  }
  NoteOptions { id: options; store: mock; noteId: "test" }
  BlockEditor { id: editor; width: 900; height: 500; fontSize: 15 }
  TestCase {
    name: "NoteOptions"
    function init() { mock.settings = ({}); mock.note = ({title: "Original"}); options.tabId = "" }
    function test_title_typing_is_written_once() {
      options.editTitle("S"); options.editTitle("Sh"); options.editTitle("Shop")
      compare(options.displayTitle, "Shop", "typing shows at once")
      compare(mock.settings["note.test.title.main"], undefined, "nothing written yet")
      compare(mock.note.title, "Original")
      mock.settingsChanged.connect(function() { if (options._titlePending) mock.sawPendingDuringWrite = true })
      options.flushTitle()
      compare(mock.settings["note.test.title.main"], "Shop")
      compare(mock.note.title, "Shop")
      compare(options.displayTitle, "Shop", "still shown after the flush")
      options.flushTitle()
      options.editTitle("Shopping")
      options.tabId = "second"
      options.editTitle("Other")
      compare(mock.settings["note.test.title.main"], "Shopping", "a pending title is written before another tab's begins")
      compare(mock.settings["note.test.title.second"], undefined)
      compare(options.displayTitle, "Other")
      options.flushTitle()
      compare(mock.settings["note.test.title.second"], "Other")
      compare(mock.note.title, "Shopping", "tab 2 titles never touch the note")
    }
    function test_active_tab_is_remembered_by_id() {
      var tabs = [{ id: "b" }, { id: "c" }]
      compare(options.savedTab(tabs), 0, "nothing remembered opens tab 1")
      options.rememberTab("c")
      compare(mock.settings["note.test.activeTab"], "c")
      compare(options.savedTab(tabs), 2)
      compare(options.savedTab([{ id: "c" }]), 1, "the same tab after another was deleted")
      compare(options.savedTab([{ id: "b" }]), 0, "a tab that is gone means tab 1")
      compare(options.savedTab([]), 0)
      compare(options.savedTab(null), 0)
      options.rememberTab("")
      compare(mock.settings["note.test.activeTab"], "main", "tab 1 has no row id")
      compare(options.savedTab(tabs), 0)
      mock.setSetting("note.test.activeTab", "__proto__")
      compare(options.savedTab(tabs), 0, "a damaged value opens tab 1")
    }
    function test_titles_survive_lock_and_unlock() {
      options.editTitle("First")
      options.tabId = "second"
      options.editTitle("Second")
      compare(options.displayTitle, "Second")
      options.toggleTitleLock()
      verify(options.titleLocked)
      options.tabId = ""
      compare(options.displayTitle, "Second")
      options.editTitle("Must not change")
      compare(options.displayTitle, "Second")
      compare(mock.note.title, "Second", "locking shares the visible title through the note")
      options.toggleTitleLock()
      compare(options.displayTitle, "First")
      compare(mock.note.title, "First", "unlocking gives the note tab 1's title back")
      options.tabId = "second"
      compare(options.displayTitle, "Second")
      options.editTitle("")
      compare(options.displayTitle, "")
    }
    function test_locking_from_an_untitled_tab_keeps_the_note_title() {
      options.tabId = "second"
      compare(options.displayTitle, "")
      options.toggleTitleLock()
      compare(options.displayTitle, "Original")
      compare(mock.note.title, "Original")
      options.toggleTitleLock()
      compare(mock.note.title, "Original")
    }
    function test_columns_are_per_tab_and_persist() {
      options.cycleColumns(); compare(options.columns, 2)
      options.cycleColumns(); compare(options.columns, 3)
      options.tabId = "second"; compare(options.columns, 1)
      options.cycleColumns(); compare(options.columns, 2)
      options.tabId = ""; compare(options.columns, 3)
      options.cycleColumns(); compare(options.columns, 1)
    }
    function test_tab_labels_are_independent_of_titles_and_lock() {
      compare(options.tabLabel(""), "")
      options.renameTab("", "  Short name  ")
      compare(options.tabLabel(""), "Short name")
      compare(options.displayTitle, "Original")
      options.editTitle("Long note title")
      compare(options.tabLabel(""), "Short name")
      options.toggleTitleLock()
      options.renameTab("", "Renamed while locked")
      compare(options.displayTitle, "Long note title")
      compare(options.tabLabel(""), "Renamed while locked")
      options.renameTab("second", "Other")
      compare(options.tabLabel("second"), "Other")
      compare(options.tabLabel("third"), "")
      options.renameTab("", " ")
      compare(options.tabLabel(""), "")
    }
    function test_heading_stays_with_following_block() {
      var result = ColumnLayout.arrange([20, 20, 20, 20, 20, 20], ["text", "subtitle", "text", "text", "text", "text"], 3, 4)
      compare(result.positions[1].column, result.positions[2].column)
      for (var i = 1; i < result.positions.length; i++) {
        verify(result.positions[i].column >= result.positions[i - 1].column)
        if (result.positions[i].column === result.positions[i - 1].column)
          verify(result.positions[i].y >= result.positions[i - 1].y + 24)
      }
    }
    function test_editor_reflows_without_changing_content() {
      var blocks = []
      for (var i = 0; i < 24; i++) blocks.push({type: "text", content: "Shortcut " + i})
      editor.columns = 1
      editor.load(JSON.stringify(blocks))
      wait(50)
      var tall = editor.blockLayout.height
      editor.columns = 3
      wait(50)
      verify(editor.blockLayout.height < tall)
      compare(editor.blockLayout.positions[23].column, 2)
      compare(editor.count, 24)
      compare(editor.dirty, false)
    }
  }
}
