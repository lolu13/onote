// The block list of one note. Holds a ListModel of blocks, renders one
// delegate per block, and batches saves: edits only touch the model; the JSON
// for the database is built once per save timer tick (autoSaveInterval).
import QtQuick
import "blocks"

FocusScope {
  id: editorRoot

  property var store: null
  property string noteId: ""
  property string tabId: ""        // empty: this editor shows the note itself (tab 1)
  property var palette: null
  property int fontSize: 15
  property string fontFamily: ""
  property int saveInterval: 500

  property bool dirty: false
  property int focusedIndex: -1
  // Bumped by every load(); async work started against an earlier generation
  // (a paste that arrives after a tab switch) must not touch the model.
  property int loadGen: 0
  readonly property int count: blocksModel.count

  // One ListModel row and one eagerly built delegate per block, so the count is
  // capped: a pasted, imported or shared-database note must not be able to make
  // the shell instantiate an unbounded number of items.
  readonly property int maxBlocks: 2000
  property bool _warnedFull: false   // one warning per load, not one per keystroke

  function _full(extra) {
    if (blocksModel.count + extra <= editorRoot.maxBlocks) return false
    if (!editorRoot._warnedFull) {
      editorRoot._warnedFull = true
      console.warn("desknotes: a note holds at most " + editorRoot.maxBlocks + " blocks")
    }
    return true
  }

  // ---- slash picker ("/" typed into an empty text block)
  readonly property var pickerAll: [
    { type: "text",     label: "Text",     hint: "" },
    { type: "subtitle", label: "Heading",  hint: "#" },
    { type: "bullet",   label: "Bullet",   hint: "-" },
    { type: "todo",     label: "To-do",    hint: "[]" },
    { type: "label",    label: "Label",    hint: "" },
    { type: "code",     label: "Code",     hint: "```" },
    { type: "divider",  label: "Divider",  hint: "---" }
  ]
  property int pickerIndex: -1
  property string pickerFilter: ""
  property int pickerSelection: 0
  readonly property var pickerItems: {
    if (pickerIndex < 0) return []
    var f = pickerFilter.toLowerCase()
    return pickerAll.filter(function(it) { return !f.length || it.label.toLowerCase().indexOf(f) === 0 || it.type.indexOf(f) === 0 })
  }

  function pickerOpen(i, filter) { pickerIndex = i; pickerFilter = filter || ""; pickerSelection = 0 }
  function pickerClose() { pickerIndex = -1; pickerFilter = ""; pickerSelection = 0 }
  function pickerMove(delta) {
    var n = pickerItems.length
    if (!n) return
    pickerSelection = (pickerSelection + delta + n) % n
  }
  function pickerAccept() {
    var i = pickerIndex
    var items = pickerItems
    if (i < 0 || !items.length) { pickerClose(); return }
    var type = items[Math.min(pickerSelection, items.length - 1)].type
    pickerClose()
    convertBlock(i, type, "")
  }

  ListModel { id: blocksModel }

  function normalize(b) {
    b = b || {}
    return {
      type: typeof b.type === "string" ? b.type : "text",
      content: typeof b.content === "string" ? b.content : "",
      checked: b.checked === true,
      label: typeof b.label === "string" ? b.label : "",
      color: typeof b.color === "string" ? b.color : "",
      src: typeof b.src === "string" ? b.src : "",
      imageWidth: typeof b.imageWidth === "number" ? Math.round(b.imageWidth) : 0
    }
  }

  function rowToBlock(r) {
    var out = { type: r.type, content: r.content }
    if (r.type === "todo") out.checked = r.checked
    if (r.type === "label") { out.label = r.label; if (r.color) out.color = r.color }
    if (r.type === "image") { out.src = r.src; if (r.imageWidth) out.imageWidth = r.imageWidth }
    return out
  }

  function load(json) {
    var arr = []
    try { arr = JSON.parse(json || "[]") } catch (e) { arr = [] }
    if (!Array.isArray(arr) || arr.length === 0) arr = [{ type: "text", content: "" }]
    if (arr.length > editorRoot.maxBlocks) {
      console.warn("desknotes: note has " + arr.length + " blocks; only the first " + editorRoot.maxBlocks + " are kept")
      arr = arr.slice(0, editorRoot.maxBlocks)
    }
    editorRoot._warnedFull = false
    blocksModel.clear()
    for (var i = 0; i < arr.length; i++) blocksModel.append(normalize(arr[i]))
    editorRoot.dirty = false
    editorRoot.loadGen++
  }

  function markDirty() { editorRoot.dirty = true; saveTimer.restart() }

  function flush() {
    if (!editorRoot.dirty) return
    var arr = []
    for (var i = 0; i < blocksModel.count; i++) arr.push(rowToBlock(blocksModel.get(i)))
    editorRoot.dirty = false
    if (!editorRoot.store) return
    if (editorRoot.tabId) editorRoot.store.updateTab(editorRoot.tabId, { contentBlocks: JSON.stringify(arr) })
    else if (editorRoot.noteId) editorRoot.store.updateNote(editorRoot.noteId, { contentBlocks: JSON.stringify(arr) })
  }

  function isEmpty() {
    for (var i = 0; i < blocksModel.count; i++) {
      var b = rowToBlock(blocksModel.get(i))
      if (b.type === "image" || b.type === "divider") return false
      if ((b.content || "").length || (b.label || "").length) return false
    }
    return true
  }

  // Emitted when Up is pressed on the first line of the first block.
  signal leaveTop()

  function focusBlock(i, atEnd) {
    if (blocksModel.count === 0) return
    if (i < 0) { editorRoot.leaveTop(); return }
    i = Math.max(0, Math.min(blocksModel.count - 1, i))
    var it = repeater.itemAt(i)
    if (!it) { Qt.callLater(function() { var j = repeater.itemAt(i); if (j) j.focusEditor(atEnd) }); return }
    it.focusEditor(atEnd)
    Qt.callLater(function() { editorRoot.ensureVisible(i) })
  }

  function ensureVisible(i) {
    var it = repeater.itemAt(i)
    if (!it) return
    var top = it.y, bottom = it.y + it.height
    if (top < flick.contentY) flick.contentY = Math.max(0, top - 8)
    else if (bottom > flick.contentY + flick.height) flick.contentY = Math.min(flick.contentHeight - flick.height, bottom - flick.height + 8)
  }

  function setContent(i, t) {
    if (i < 0 || i >= blocksModel.count) return
    var r = blocksModel.get(i)
    if (r.type === "text") {
      if (t === "# ")  { convertBlock(i, "subtitle", ""); return }
      if (t === "- ")  { convertBlock(i, "bullet", ""); return }
      if (t === "[] " || t === "[ ] ") { convertBlock(i, "todo", ""); return }
    }
    blocksModel.setProperty(i, "content", t)
    markDirty()
    // slash picker lifecycle
    if (r.type === "text" && t.length && t.charAt(0) === "/" && t.indexOf(" ") === -1 && t.length < 16) {
      if (pickerIndex !== i) pickerOpen(i, t.slice(1)); else { pickerFilter = t.slice(1); pickerSelection = 0 }
    } else if (pickerIndex === i) {
      pickerClose()
    }
  }

  function setChecked(i, b) { blocksModel.setProperty(i, "checked", b === true); markDirty() }
  function setLabel(i, t) { blocksModel.setProperty(i, "label", t); markDirty() }
  function setColor(i, c) { blocksModel.setProperty(i, "color", c); markDirty() }

  function insertBlock(i, block) {
    if (editorRoot._full(1)) return
    i = Math.max(0, Math.min(blocksModel.count, i))
    blocksModel.insert(i, normalize(block))
    markDirty()
    focusBlock(i, false)
  }

  // Insert the clipboard image after row i (or in place of an empty text row),
  // followed by a text row to keep typing. cb(true) when handled, cb(false) to
  // let the caller paste text instead. Limits match src/imageLimits.ts.
  function pasteImage(i, rowIsEmpty, cb) {
    if (!editorRoot.store || typeof editorRoot.store.clipboardImage !== "function") { cb(false); return }
    var gen = editorRoot.loadGen, tab = editorRoot.tabId, note = editorRoot.noteId
    editorRoot.store.clipboardImage(function(err, img) {
      // The editor moved on (tab switch, reload): drop the paste rather than
      // applying it to whatever now occupies row i. cb(true) so the caller
      // does not paste text into the new content either.
      if (gen !== editorRoot.loadGen || tab !== editorRoot.tabId || note !== editorRoot.noteId) {
        console.warn("desknotes: image paste dropped, the editor changed content meanwhile")
        cb(true); return
      }
      if (err) { console.warn("desknotes: image paste refused:", err); cb(true); return }
      if (!img || !img.src) { cb(false); return }
      var images = 0
      for (var k = 0; k < blocksModel.count; k++) if (blocksModel.get(k).type === "image") images++
      if (images >= 20) { console.warn("desknotes: a note holds at most 20 images"); cb(true); return }
      // The image and the text row that follows it are two more blocks.
      if (editorRoot._full(2)) { cb(true); return }
      var at = Math.max(0, Math.min(blocksModel.count - 1, i))
      var row = blocksModel.get(at)
      // Re-check emptiness now: typing may have filled the row while waiting.
      if (rowIsEmpty && row && row.type === "text" && !row.content.length) {
        blocksModel.set(at, normalize({ type: "image", src: img.src }))
      } else {
        at = at + 1
        blocksModel.insert(at, normalize({ type: "image", src: img.src }))
      }
      blocksModel.insert(at + 1, normalize({ type: "text", content: "" }))
      markDirty()
      focusBlock(at + 1, true)
      cb(true)
    })
  }

  function removeBlock(i) {
    if (i < 0 || i >= blocksModel.count) return
    if (blocksModel.count === 1) { convertBlock(0, "text", ""); return }
    blocksModel.remove(i)
    markDirty()
    focusBlock(i > 0 ? i - 1 : 0, true)
  }

  // Changing the type swaps the delegate; the model keeps the content.
  function convertBlock(i, type, content) {
    if (i < 0 || i >= blocksModel.count) return
    if (pickerIndex === i) pickerClose()
    if (content !== undefined) blocksModel.setProperty(i, "content", content)
    if (type === "todo") blocksModel.setProperty(i, "checked", false)
    blocksModel.setProperty(i, "type", type)
    markDirty()
    focusBlock(i, true)
  }

  function moveBlock(i, delta) {
    var j = i + delta
    if (i < 0 || j < 0 || i >= blocksModel.count || j >= blocksModel.count) return
    blocksModel.move(i, j, 1)
    markDirty()
    focusBlock(j, true)
  }

  function toggleTodo(i) {
    if (i < 0 || i >= blocksModel.count) return
    var r = blocksModel.get(i)
    if (r.type === "todo") setChecked(i, !r.checked)
    else convertBlock(i, "todo")
  }

  function cycleLabelColor(i) {
    if (i < 0 || i >= blocksModel.count || !editorRoot.palette) return
    var r = blocksModel.get(i)
    if (r.type !== "label") return
    var colors = editorRoot.palette.labelColors || []
    if (!colors.length) return
    var cur = colors.indexOf(String(r.color))
    var next = colors[(cur + 1) % colors.length]
    setColor(i, String(next))
  }

  // Enter behaviour, mirroring the React editorRoot.
  function onEnter(i) {
    var r = blocksModel.get(i)
    switch (r.type) {
      case "bullet": insertBlock(i + 1, { type: "bullet" }); break
      case "todo":   insertBlock(i + 1, { type: "todo" }); break
      case "label":  insertBlock(i + 1, { type: "label" }); break
      case "code":   insertBlock(i + 1, { type: "text" }); break
      case "subtitle": case "divider": case "image":
        insertBlock(i + 1, { type: "text" }); break
      default: {
        var v = r.content.trim()
        if (v === "---" || v === "***") {
          blocksModel.setProperty(i, "content", "")
          blocksModel.setProperty(i, "type", "divider")
          insertBlock(i + 1, { type: "text" })
        } else if (v === "```") {
          convertBlock(i, "code", "")
        } else {
          insertBlock(i + 1, { type: "text" })
        }
      }
    }
  }

  function onBackspaceOnEmpty(i) {
    var r = blocksModel.get(i)
    switch (r.type) {
      case "text":
        if (blocksModel.count > 1) { blocksModel.remove(i); markDirty(); focusBlock(i > 0 ? i - 1 : 0, true) }
        break
      case "bullet": case "todo": case "subtitle": case "code":
        convertBlock(i, "text"); break
      case "label":
        if ((r.label || "") === "") convertBlock(i, "text")
        break
      case "divider": case "image":
        removeBlock(i); break
    }
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.height + editorRoot.fontSize * 2
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick

    // Click below the last block: put the caret at the end of the note.
    MouseArea {
      width: flick.width
      height: Math.max(flick.height, flick.contentHeight)
      onClicked: editorRoot.focusBlock(blocksModel.count - 1, true)
    }

    Column {
      id: column
      width: flick.width
      spacing: 4
      Repeater {
        id: repeater
        model: blocksModel
        delegate: BlockRow { editor: editorRoot; width: column.width }
      }
    }
  }

  Timer {
    id: saveTimer
    interval: editorRoot.saveInterval
    repeat: false
    onTriggered: editorRoot.flush()
  }

  onActiveFocusChanged: if (!activeFocus) flush()
  Component.onDestruction: flush()
}
