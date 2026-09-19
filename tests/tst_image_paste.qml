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
    property var icon: null
    property var notes: ({ note: { id: "note", icon: "data:image/png;base64,AA==" } })
    property var sources: []
    function clipboardImage(list, titleIcon, cb) { sources = list; icon = titleIcon; reply = cb }
    function updateTab(id, patch) { saved = { id: id, patch: patch } }
    function updateNote(id, patch) { saved = { id: id, patch: patch } }
  }
  BlockEditor { id: editor; anchors.fill: parent; store: imageStore; noteId: "note"; tabId: "first" }

  TestCase {
    name: "ImagePasteTargeting"
    function init() { imageStore.reply = null; imageStore.saved = null; editor.tabId = "first" }
    function blocks() { editor.flush(); return JSON.parse(imageStore.saved.patch.contentBlocks) }

    // The desktop edition charges an image title icon to the note body's
    // pixel budget; the helper is handed it for the body, never for a tab,
    // and an emoji icon is not an image.
    function test_paste_hands_the_helper_the_notes_image_icon_for_the_body_only() {
      editor.load('[{"type":"text","content":""}]')
      editor.pasteImage(0, true, function() {})
      compare(imageStore.icon, "", "a tab paste carries no icon")
      imageStore.reply(null, null)
      editor.tabId = ""
      editor.pasteImage(0, true, function() {})
      compare(imageStore.icon, "data:image/png;base64,AA==", "the body paste carries the icon")
      imageStore.reply(null, null)
      imageStore.notes = { note: { id: "note", icon: "\ud83d\ude00" } }
      editor.pasteImage(0, true, function() {})
      compare(imageStore.icon, "", "an emoji icon is no image")
      imageStore.reply(null, null)
      imageStore.notes = { note: { id: "note", icon: "data:image/png;base64,AA==" } }
    }

    // Blocks past the editor's cap are hidden but saved with the note, so
    // their images are handed to the budget check like the visible ones.
    function test_paste_counts_the_images_kept_past_the_block_cap() {
      var all = []
      for (var i = 0; i < editor.maxBlocks; i++) all.push({ type: "text", content: "t" + i })
      all[3] = { type: "image", src: "data:image/png;base64,VISIBLE" }
      all.push({ type: "image", src: "data:image/png;base64,HIDDEN" }, { type: "text", content: "tail" })
      editor.load(JSON.stringify(all))
      editor.pasteImage(0, false, function() {})
      compare(imageStore.sources.length, 2)
      verify(imageStore.sources.indexOf("data:image/png;base64,HIDDEN") !== -1, "the hidden image is charged")
      imageStore.reply(null, null)
      editor.load('[{"type":"text","content":""}]')
    }

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
