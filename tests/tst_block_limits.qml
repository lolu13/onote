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
    property string tooLarge: ""
    signal saveRefusalChanged(string id)
    function isTooLarge(id) { return id === tooLarge }
    property var sources: null
    function clipboardImage(s, titleIcon, cb) { sources = s; reply = cb }
    function updateTab(id, patch) { saved = { id: id, patch: patch } }
    function updateNote(id, patch) { saved = { id: id, patch: patch } }
  }
  BlockEditor { id: editor; anchors.fill: parent; store: limitStore; noteId: "note"; tabId: "first" }

  TestCase {
    name: "BlockLimits"
    function init() { limitStore.reply = null; limitStore.saved = null; limitStore.tooLarge = "" }

    function json(n) {
      var a = []
      for (var i = 0; i < n; i++) a.push({ type: "text", content: "b" + i })
      return JSON.stringify(a)
    }

    // A longer note from the desktop edition shows the first 2000 blocks; the
    // rest is neither lost nor touched when an edit here is saved.
    function test_load_shows_at_most_the_cap_and_saves_the_rest_unchanged() {
      var full = JSON.parse(json(editor.maxBlocks + 500))
      full[editor.maxBlocks + 7].unknownField = "kept verbatim"
      editor.load(JSON.stringify(full))
      compare(editor.count, editor.maxBlocks)
      verify(editor.notice.indexOf("Showing 2000 of 2500") === 0, editor.notice)
      verify(!editor.isEmpty(), "closing must still ask")
      editor.setContent(0, "edited")
      editor.flush()
      var saved = JSON.parse(limitStore.saved.patch.contentBlocks)
      compare(saved.length, editor.maxBlocks + 500)
      compare(saved[0].content, "edited")
      compare(saved[editor.maxBlocks + 7].unknownField, "kept verbatim")
      compare(saved[editor.maxBlocks + 499].content, "b" + (editor.maxBlocks + 499))
      editor.load(json(3))
      compare(editor.count, 3, "a normal note is untouched")
      compare(editor.notice, "")
      editor.markDirty(); editor.flush()
      compare(JSON.parse(limitStore.saved.patch.contentBlocks).length, 3, "no tail leaks into the next note")
    }

    // Widths dragged in the desktop edition are not editable here but survive a save.
    function test_desktop_sizing_fields_survive_a_round_trip() {
      editor.load(JSON.stringify([
        { type: "code", content: "x", manualWidth: 320 },
        { type: "label", label: "k", content: "v", labelWidth: 120.4 },
        { type: "text", content: "t", manualWidth: 5 }]))
      editor.markDirty(); editor.flush()
      var saved = JSON.parse(limitStore.saved.patch.contentBlocks)
      compare(saved[0].manualWidth, 320)
      compare(saved[1].labelWidth, 120)
      compare(saved[2].manualWidth, undefined, "only where the desktop uses it")
      compare(saved[0].labelWidth, undefined)
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

    // The real limit is 5 MB; a small one keeps the text drawable in a test.
    function withLimit(bytes, body) {
      var real = editor.maxBytes
      editor.maxBytes = bytes
      try { body() } finally { editor.maxBytes = real }
    }
    function text(n) { return JSON.stringify([{ type: "text", content: new Array(n + 1).join("x") }]) }

    // The warning follows the helper's refusal as the store records it, not a
    // size guess: a legacy note over 5 MB that does not grow still saves.
    function test_notice_follows_the_store_refusal() {
      editor.load(text(10))
      compare(editor.notice, "")
      limitStore.tooLarge = "first"; limitStore.saveRefusalChanged("first")
      verify(editor.notice.length > 0)
      editor.load(text(10))
      verify(editor.notice.length > 0, "a refused draft keeps its warning when shown again")
      limitStore.tooLarge = ""; limitStore.saveRefusalChanged("first")
      compare(editor.notice, "", "saved again: the warning goes")
      limitStore.tooLarge = "other"; limitStore.saveRefusalChanged("other")
      compare(editor.notice, "", "another note's refusal is not ours")
    }

    function test_large_content_without_a_refusal_shows_no_warning() {
      withLimit(300, function() {
        editor.load(text(400))
        editor.markDirty()
        editor.flush()
        verify(limitStore.saved !== null, "handed to the store, which lets the helper decide")
        compare(editor.notice, "")
      })
    }

    // UTF-8, not UTF-16: "é" is 2 bytes, "€" 3, an emoji (two UTF-16 units) 4.
    function test_size_is_measured_in_utf8() {
      withLimit(600, function() {
        verify(!editor._tooBig(new Array(301).join("é")), "600 bytes fit")
        verify(editor._tooBig(new Array(302).join("é")), "602 do not")
        verify(editor._tooBig(new Array(201).join("€") + "x"), "601 do not")
        verify(!editor._tooBig(new Array(151).join("😀")), "150 emoji are 600 bytes")
        verify(editor._tooBig(new Array(152).join("😀")))
      })
    }

    function test_image_paste_hands_the_helper_the_images_already_in_the_note() {
      editor.load(JSON.stringify([{ type: "image", src: "data:image/png;base64,AA==" }, { type: "text", content: "" }]))
      var handled = null
      editor.pasteImage(1, true, function(h) { handled = h })
      compare(limitStore.sources.length, 1)
      compare(limitStore.sources[0], "data:image/png;base64,AA==")
      limitStore.reply("Images in one note can total at most 16 megapixels", null)
      compare(handled, true, "refused, and no text paste instead")
      compare(editor.count, 2)
      verify(editor.notice.indexOf("Image not added: Images in one note") === 0)
    }

    function test_overlapping_pastes_run_one_at_a_time_against_the_current_images() {
      editor.load(JSON.stringify([{ type: "image", src: "data:image/png;base64,AA==" }, { type: "text", content: "" }]))
      var h1 = null, h2 = null
      editor.pasteImage(1, true, function(h) { h1 = h })
      var first = limitStore.reply
      editor.pasteImage(1, true, function(h) { h2 = h })
      compare(h2, true, "a second paste while one is pending is dropped, not pasted as text")
      verify(limitStore.reply === first, "and asks the helper nothing")
      editor.removeBlock(0)                                    // the image went meanwhile
      first("A note holds at most 20 images", null)              // a refusal about the old note
      compare(limitStore.sources.length, 0, "asked again with the images as they are now")
      compare(editor.notice, "", "and the stale refusal is not shown")
      compare(h1, null)
      limitStore.reply(null, { src: "data:image/png;base64,AQ==" })
      compare(h1, true)
      compare(editor.count, 2)
      compare(editor._pasting, false)
      editor.pasteImage(0, false, function(h) { h2 = h })
      compare(limitStore.sources.length, 1, "the next paste sees the pasted image")
    }

    function test_image_paste_refused_past_the_size_limit() {
      withLimit(1000, function() {
        editor.load(text(500))
        var handled = null
        editor.pasteImage(0, false, function(h) { handled = h })
        limitStore.reply(null, { src: "data:image/png;base64," + new Array(601).join("A") })
        compare(handled, true, "refused, and no text paste instead")
        compare(editor.count, 1)
        verify(editor.notice.indexOf("Image not added") === 0)
      })
    }
  }
}
