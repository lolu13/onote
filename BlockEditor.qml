// The block list of one note. Holds a ListModel of blocks, renders one
// delegate per block, and batches saves: edits only touch the model; the JSON
// for the database is built once per save timer tick (autoSaveInterval).
import QtQuick
import "blocks"
import "ColumnLayout.js" as ColumnLayout

FocusScope {
  id: editorRoot

  property var store: null
  property string noteId: ""
  property string tabId: ""        // empty: this editor shows the note itself (tab 1)
  property var palette: null
  property int fontSize: 15
  property string fontFamily: ""
  property int saveInterval: 500
  property int columns: 1
  readonly property int columnCount: Math.max(1, Math.min(3, columns))
  readonly property int columnGap: Math.round(fontSize * 1.5)
  readonly property real columnWidth: Math.max(1, (width - columnGap * (columnCount - 1)) / columnCount)
  property var blockLayout: ({positions: [], height: 0})
  function arrangeBlocks() {
    var heights = [], types = []
    for (var i = 0; i < repeater.count; i++) {
      var item = repeater.itemAt(i)
      heights.push(item ? item.height : fontSize * 1.5)
      types.push(item ? item.type : "text")
    }
    blockLayout = ColumnLayout.arrange(heights, types, columnCount, 4)
  }
  onColumnCountChanged: layoutTimer.restart()
  Timer { id: layoutTimer; interval: 0; onTriggered: editorRoot.arrangeBlocks() }

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
  // Blocks past the cap (a note the desktop edition grew) are neither shown
  // nor editable, but they are kept exactly as loaded and written back after
  // the shown ones, so an edit here never shortens the note.
  property var _tail: []
  readonly property string hiddenNotice: _tail.length
    ? "Showing " + maxBlocks + " of " + (maxBlocks + _tail.length) + " blocks; the rest is kept unchanged" : ""

  // The helper refuses content over 5 MB of UTF-8 (MAX_NOTE_CONTENT_BYTES),
  // except a legacy note already that large which does not grow. The store
  // keeps refused content unsaved and never resends it; `notice` follows the
  // store's record of the refusal, so it shows only what really did not save.
  property int maxBytes: 5 * 1024 * 1024   // lowered by the tests only
  property string notice: ""
  readonly property string tooLargeNotice: "Over the 5 MB limit, not saved: remove an image or some text"

  function refreshNotice() {
    var id = editorRoot.tabId || editorRoot.noteId
    var refused = !!editorRoot.store && typeof editorRoot.store.isTooLarge === "function" && editorRoot.store.isTooLarge(id)
    editorRoot.notice = refused ? editorRoot.tooLargeNotice : editorRoot.hiddenNotice
  }
  Connections {
    target: editorRoot.store
    ignoreUnknownSignals: true
    function onSaveRefusalChanged(id) { if (id === (editorRoot.tabId || editorRoot.noteId)) editorRoot.refreshNotice() }
  }

  function _tooBig(s) {
    if (s.length > editorRoot.maxBytes) return true
    if (s.length * 3 <= editorRoot.maxBytes) return false   // a UTF-16 unit is 1-3 bytes
    var n = s.length
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i)
      // 2 bytes below U+0800, 3 above, 4 per surrogate pair.
      if (c >= 0x80) n += (c >= 0x800 && (c < 0xD800 || c > 0xDFFF)) ? 2 : 1
    }
    return n > editorRoot.maxBytes
  }

  function _serialize() {
    var arr = []
    for (var i = 0; i < blocksModel.count; i++) arr.push(rowToBlock(blocksModel.get(i)))
    return JSON.stringify(editorRoot._tail.length ? arr.concat(editorRoot._tail) : arr)
  }

  function _full(extra) {
    if (blocksModel.count + extra <= editorRoot.maxBlocks) return false
    if (!editorRoot._warnedFull) {
      editorRoot._warnedFull = true
      console.warn("onote: a note holds at most " + editorRoot.maxBlocks + " blocks")
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
      imageWidth: typeof b.imageWidth === "number" ? Math.round(b.imageWidth) : 0,
      // Sizes the desktop edition lets the user drag; carried, not shown.
      manualWidth: typeof b.manualWidth === "number" ? Math.round(b.manualWidth) : 0,
      labelWidth: typeof b.labelWidth === "number" ? Math.round(b.labelWidth) : 0
    }
  }

  function rowToBlock(r) {
    var out = { type: r.type, content: r.content }
    if (r.type === "todo") out.checked = r.checked
    if (r.type === "label") { out.label = r.label; if (r.color) out.color = r.color; if (r.labelWidth) out.labelWidth = r.labelWidth }
    if (r.type === "code" && r.manualWidth) out.manualWidth = r.manualWidth
    if (r.type === "image") { out.src = r.src; if (r.imageWidth) out.imageWidth = r.imageWidth }
    return out
  }

  function load(json) {
    // The picker is a row index: left open across a load it would own
    // whichever block the new content puts at that row, and Enter would
    // convert (empty) that block, on another tab even.
    pickerClose()
    var arr = []
    try { arr = JSON.parse(json || "[]") } catch (e) { arr = [] }
    if (!Array.isArray(arr) || arr.length === 0) arr = [{ type: "text", content: "" }]
    editorRoot._tail = arr.length > editorRoot.maxBlocks ? arr.slice(editorRoot.maxBlocks) : []
    if (editorRoot._tail.length) {
      console.warn("onote: note has " + arr.length + " blocks; the first " + editorRoot.maxBlocks + " are shown")
      arr = arr.slice(0, editorRoot.maxBlocks)
    }
    editorRoot._warnedFull = false
    // A draft the store kept unsaved comes back with its warning.
    editorRoot.refreshNotice()
    blocksModel.clear()
    for (var i = 0; i < arr.length; i++) blocksModel.append(normalize(arr[i]))
    editorRoot.dirty = false
    editorRoot.loadGen++
  }

  function markDirty() { editorRoot.dirty = true; saveTimer.restart() }

  function flush() {
    if (!editorRoot.dirty) return
    var json = editorRoot._serialize()
    editorRoot.refreshNotice()   // drops a paste refusal; a new refusal arrives as a signal
    editorRoot.dirty = false
    if (!editorRoot.store) return
    if (editorRoot.tabId) editorRoot.store.updateTab(editorRoot.tabId, { contentBlocks: json })
    else if (editorRoot.noteId) editorRoot.store.updateNote(editorRoot.noteId, { contentBlocks: json })
  }

  function isEmpty() {
    if (editorRoot._tail.length) return false
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

  function focusColumn(delta) {
    var i = Math.max(0, editorRoot.focusedIndex)
    var current = blockLayout.positions[i]
    if (!current) return
    var wanted = current.column + delta, best = -1, distance = Infinity
    for (var j = 0; j < blockLayout.positions.length; j++) {
      var p = blockLayout.positions[j]
      if (p.column === wanted && Math.abs(p.y - current.y) < distance) {
        best = j; distance = Math.abs(p.y - current.y)
      }
    }
    if (best >= 0) focusBlock(best, false)
  }

  function focusLabel() {
    var item = repeater.itemAt(editorRoot.focusedIndex)
    if (item) item.focusLabelEditor()
  }

  Keys.onPressed: function(event) {
    // Ctrl+Home / Ctrl+End from a block that does not handle them itself
    // (an image, a divider): text blocks answer them before this.
    if ((event.key === Qt.Key_Home || event.key === Qt.Key_End)
        && (event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier | Qt.AltModifier | Qt.MetaModifier)) === Qt.ControlModifier) {
      editorRoot.focusBlock(event.key === Qt.Key_End ? blocksModel.count - 1 : 0, event.key === Qt.Key_End)
      event.accepted = true
      return
    }
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      editorRoot.focusBlock(editorRoot.focusedIndex + ((event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)) ? -1 : 1), false)
      event.accepted = true
    }
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
    // One paste at a time: the helper checks the note's image budget (count,
    // pixels over all images, as the desktop edition does) against the
    // images it is handed, so two pastes in flight would both pass on the
    // same note. A second paste meanwhile is dropped, not pasted as text.
    if (editorRoot._pasting) { console.warn("onote: image paste dropped, one is in progress"); cb(true); return }
    editorRoot._pasting = true
    var done = function(handled) { editorRoot._pasting = false; cb(handled) }
    var gen = editorRoot.loadGen, tab = editorRoot.tabId, note = editorRoot.noteId
    var sources = editorRoot._imageSources(), icon = editorRoot._titleIcon(), asked = 0
    var ask = function() { asked++; editorRoot.store.clipboardImage(sources, icon, function(err, img) {
      // The editor moved on (tab switch, reload): drop the paste rather than
      // applying it to whatever now occupies row i. cb(true) so the caller
      // does not paste text into the new content either.
      if (gen !== editorRoot.loadGen || tab !== editorRoot.tabId || note !== editorRoot.noteId) {
        console.warn("onote: image paste dropped, the editor changed content meanwhile")
        done(true); return
      }
      // The note's images changed while the clipboard was read (one removed,
      // say): the answer, a refusal included, was about the old note, so the
      // helper is asked again against the current images, a few times at most.
      var now = editorRoot._imageSources()
      if (now.join("\n") !== sources.join("\n")) {
        if (asked < 4) { sources = now; ask(); return }
        editorRoot.notice = "Image not added: the note kept changing"; done(true); return
      }
      if (err) { editorRoot.notice = "Image not added: " + err; done(true); return }
      if (!img || !img.src) { done(false); return }
      // The image and the text row that follows it are two more blocks.
      if (editorRoot._full(2)) { done(true); return }
      // The block's own JSON around the data URI stays under 64 bytes.
      if (editorRoot._tooBig(editorRoot._serialize() + img.src + new Array(65).join(" "))) {
        editorRoot.notice = "Image not added: the note would pass the 5 MB limit"
        done(true); return
      }
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
      done(true)
    }) }
    ask()
  }

  property bool _pasting: false
  function _imageSources() {
    var sources = []
    for (var s = 0; s < blocksModel.count; s++) { var b = blocksModel.get(s); if (b.type === "image" && b.src) sources.push(b.src) }
    // Blocks past maxBlocks are not shown but are saved with the note: their
    // images count against the same budget.
    for (var t = 0; t < editorRoot._tail.length; t++) {
      var h = editorRoot._tail[t]
      if (h && h.type === "image" && typeof h.src === "string" && h.src) sources.push(h.src)
    }
    return sources
  }

  // The note's title icon when it is an image (set by the desktop edition;
  // this one cannot show or change it): the desktop charges its pixels to
  // the note body's image budget, not to a tab's and not as one of the 20.
  function _titleIcon() {
    if (editorRoot.tabId || !editorRoot.store || !editorRoot.store.notes) return ""
    var n = editorRoot.store.notes[editorRoot.noteId]
    var icon = n && typeof n.icon === "string" ? n.icon : ""
    return icon.indexOf("data:image/") === 0 ? icon : ""
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
    if (pickerIndex === i) pickerClose()
    blocksModel.move(i, j, 1)
    // The moved delegate keeps its focus and only its index changes, so the
    // row never announces the new position: record it here, or the next
    // shortcut acts on the neighbour that took the old index.
    if (focusedIndex === i) focusedIndex = j
    markDirty()
    focusBlock(j, true)
  }

  // Only text-like blocks become to-dos (as on the desktop): an image, label
  // or code block converted would lose its src, badge or content, with no undo.
  function toggleTodo(i) {
    if (i < 0 || i >= blocksModel.count) return
    var r = blocksModel.get(i)
    if (r.type === "todo") setChecked(i, !r.checked)
    else if (r.type === "text" || r.type === "bullet" || r.type === "subtitle") convertBlock(i, "todo")
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

    Item {
      id: column
      width: flick.width
      height: editorRoot.blockLayout.height
      Repeater {
        model: editorRoot.columnCount - 1
        Rectangle {
          required property int index
          x: (index + 1) * (editorRoot.columnWidth + editorRoot.columnGap) - editorRoot.columnGap / 2
          width: 1; height: Math.max(flick.height, column.height)
          color: editorRoot.palette ? editorRoot.palette.currentLine : "#777777"
        }
      }
      Repeater {
        id: repeater
        onCountChanged: layoutTimer.restart()
        model: blocksModel
        delegate: BlockRow {
          editor: editorRoot
          width: editorRoot.columnWidth
          onHeightChanged: layoutTimer.restart()
          onTypeChanged: layoutTimer.restart()
          // A moved row keeps its height and type, and the count stays: only its index tells.
          onRowIndexChanged: layoutTimer.restart()
          Component.onCompleted: layoutTimer.restart()
          readonly property var placement: editorRoot.blockLayout.positions[rowIndex] || ({column: 0, y: 0})
          x: placement.column * (editorRoot.columnWidth + editorRoot.columnGap)
          y: placement.y
        }
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
