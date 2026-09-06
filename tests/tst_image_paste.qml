// A clipboard image that arrives late must land where the paste started, or
// nowhere: never in another tab and never over text typed meanwhile.
import QtQuick
import QtTest
import ".."

Item {
  width: 400; height: 400
  QtObject {
    id: imageStore
    property var reply: null
    property var saved: null
    function clipboardImage(cb) { reply = cb }
    function updateTab(id, patch) { saved = { id: id, patch: patch } }
    function updateNote(id, patch) { saved = { id: id, patch: patch } }
  }
  BlockEditor { id: editor; anchors.fill: parent; store: imageStore; noteId: "note"; tabId: "first" }

  TestCase {
    name: "ImagePasteTargeting"
    function init() { imageStore.reply = null; imageStore.saved = null; editor.tabId = "first" }
    function blocks() { editor.flush(); return JSON.parse(imageStore.saved.patch.contentBlocks) }

    function test_paste_after_tab_switch_is_dropped() {
      editor.load('[{"type":"text","content":""}]')
      var handled = null
      editor.pasteImage(0, true, function(h) { handled = h })
      editor.tabId = "second"
      editor.load('[{"type":"text","content":"keep me"}]')
      imageStore.reply(null, { src: "data:image/png;base64,AA==" })
      compare(handled, true, "the caller must not paste text into the new tab either")
      editor.markDirty()
      var b = blocks()
      compare(imageStore.saved.id, "second")
      compare(b.length, 1)
      compare(b[0].type, "text")
      compare(b[0].content, "keep me")
    }

    function test_paste_into_row_typed_meanwhile_inserts_below() {
      editor.load('[{"type":"text","content":""}]')
      editor.pasteImage(0, true, function() {})
      editor.setContent(0, "typed meanwhile")
      imageStore.reply(null, { src: "data:image/png;base64,AA==" })
      var b = blocks()
      compare(imageStore.saved.id, "first")
      compare(b.map(function(x) { return x.type }), ["text", "image", "text"])
      compare(b[0].content, "typed meanwhile")
    }

    function test_paste_into_still_empty_row_replaces_it() {
      editor.load('[{"type":"text","content":"above"},{"type":"text","content":""}]')
      editor.pasteImage(1, true, function() {})
      imageStore.reply(null, { src: "data:image/png;base64,AA==" })
      var b = blocks()
      compare(b.map(function(x) { return x.type }), ["text", "image", "text"])
      compare(b[1].src, "data:image/png;base64,AA==")
    }

    function test_paste_after_rows_vanished_clamps_to_the_end() {
      editor.load('[{"type":"text","content":"a"},{"type":"text","content":"b"},{"type":"text","content":"c"}]')
      editor.pasteImage(2, false, function() {})
      editor.removeBlock(2); editor.removeBlock(1)
      imageStore.reply(null, { src: "data:image/png;base64,AA==" })
      var b = blocks()
      compare(b.map(function(x) { return x.type }), ["text", "image", "text"])
      compare(b[0].content, "a")
    }
  }
}
