// One ListModel row and one eagerly built delegate per block, so the block
// count is bounded. A note loaded from the shared database, an Enter held
// down and a clipboard image must all stop at the cap rather than grow it.
import QtQuick
import QtTest
import ".."

Item {
  width: 400; height: 400
  QtObject {
    id: limitStore
    property var reply: null
    property var saved: null
    function clipboardImage(cb) { reply = cb }
    function updateTab(id, patch) { saved = { id: id, patch: patch } }
    function updateNote(id, patch) { saved = { id: id, patch: patch } }
  }
  BlockEditor { id: editor; anchors.fill: parent; store: limitStore; noteId: "note"; tabId: "first" }

  TestCase {
    name: "BlockLimits"
    function init() { limitStore.reply = null; limitStore.saved = null }

    function json(n) {
      var a = []
      for (var i = 0; i < n; i++) a.push({ type: "text", content: "b" + i })
      return JSON.stringify(a)
    }

    function test_load_keeps_at_most_the_cap() {
      editor.load(json(editor.maxBlocks + 500))
      compare(editor.count, editor.maxBlocks)
      editor.load(json(3))
      compare(editor.count, 3, "a normal note is untouched")
    }

    function test_insert_block_stops_at_the_cap() {
      editor.load(json(editor.maxBlocks - 1))
      editor.insertBlock(0, { type: "text" })
      compare(editor.count, editor.maxBlocks, "the last free slot is still usable")
      editor.insertBlock(0, { type: "text" })
      compare(editor.count, editor.maxBlocks)
    }

    function test_enter_stops_at_the_cap() {
      editor.load(json(editor.maxBlocks))
      editor.onEnter(0)
      compare(editor.count, editor.maxBlocks)
    }

    // The image and the text row that follows it are two blocks, so a paste is
    // refused one short of the cap; the caller must not paste text instead.
    function test_image_paste_stops_at_the_cap() {
      editor.load(json(editor.maxBlocks - 1))
      var handled = null
      editor.pasteImage(0, false, function(h) { handled = h })
      limitStore.reply(null, { src: "data:image/png;base64,AA==" })
      compare(handled, true)
      compare(editor.count, editor.maxBlocks - 1)
    }
  }
}
