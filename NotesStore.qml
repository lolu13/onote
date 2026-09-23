// In-memory cache of notes plus the API the windows and the library use.
// openNotes / stackedNotes are plain JS arrays that are always REASSIGNED
// (never mutated in place) so bindings and Variants see the change.
import QtQuick
import "NotePreview.js" as NotePreview

Item {
  id: store

  property var client: null

  property var notes: Object.create(null)          // id -> note object (full row, contentBlocks as JSON string)
  property var openNotes: []
  property var stackedNotes: []
  property var customThemes: []
  property var settings: ({})
  property bool ready: false
  // A reload is under way: notes may be installed before their tabs and
  // settings have arrived (resynced() marks the end).
  property bool syncing: false
  property string helperError: ""

  signal noteChanged(string id)
  signal noteRemoved(string id)
  signal resynced()
  signal noteTabsChanged(string noteId)
  signal noteStacked(string id)            // stacked on disk, about to drop its body and tabs: flush editors now
  signal saveRefusalChanged(string id)   // a note or tab was refused as over 5 MB, or saved again

  // Save bookkeeping. A note (or tab) is "unsaved" while it is dirty (edited,
  // not yet sent) or in flight (sent, not yet acknowledged). Every edit bumps
  // its revision; an acknowledgement or failure only counts for the revision
  // it belongs to, so an older reply can never overwrite newer content and a
  // failed write stays pending until it succeeds.
  property var _dirty: Object.create(null)         // id -> true: edited, waiting for a flush
  property var _rev: Object.create(null)           // id -> revision of the cached note
  property var _sent: Object.create(null)          // id -> revision currently in flight
  property var saveErrors: Object.create(null)     // id -> last error from the helper, cleared on success
  property int unsavedCount: 0      // notes + tabs that are dirty or in flight

  // Extra tabs per note (tab 1 is the note itself): noteId -> [tab], by position.
  property var tabs: Object.create(null)
  property var _tabNote: Object.create(null)       // tabId -> noteId
  property var _dirtyTabs: Object.create(null)     // tabId -> true
  property var _tabRev: Object.create(null)        // tabId -> revision
  property var _tabSent: Object.create(null)       // tabId -> revision in flight

  property var _dirtySettings: Object.create(null) // key -> true: its write failed; flush() resends it
  // id -> the revision the helper refused as over 5 MB (note and tab ids are
  // both UUIDs). That exact content stays here, unsaved, and is never resent,
  // so it cannot be retried forever; the next edit makes a new revision.
  property var _tooLarge: Object.create(null)

  function isTooLarge(id) { return store._tooLarge[id] !== undefined }

  function _markTooLarge(id, err, rev) {
    if (!/exceeds 5 MB/.test(String(err))) return false
    var t = store._tooLarge; t[id] = rev; store._tooLarge = t
    store.saveRefusalChanged(id)
    return true
  }

  function _savedAgain(id) {
    if (store._tooLarge[id] === undefined) return
    var t = store._tooLarge; delete t[id]; store._tooLarge = t
    store.saveRefusalChanged(id)
  }

  // Notes whose window the compositor closed wait here before the helper
  // stacks them (id -> { at, sent }). Omarchy's shutdown, reboot and logout
  // close every window about 2 s before the session ends, so a note still
  // waiting then was never stacked on disk and reopens on its workspace at
  // the next login. The UI counts it as stacked meanwhile; the cached row
  // keeps piled=false, so content saves never stack it early. Never flushed
  // on teardown: that is the point.
  property var _pendingStack: Object.create(null)
  property int stackDelayMs: 10000
  property int _restoreAllSeq: 0
  // Per-note lifecycle generation: a reopen in flight (tabsFor, bodies,
  // unstackNote) is abandoned once a newer stack, hide or delete comes in,
  // so its late unstackNote cannot undo the newer action on disk.
  property var _life: Object.create(null)

  function _bumpLife(id) { var l = store._life; l[id] = (l[id] || 0) + 1; store._life = l; return l[id] }

  function isStacked(note) { return !!note && (note.piled === true || store._pendingStack[note.id] !== undefined) }

  function _unsaved(id) { return store._dirty[id] === true || store._sent[id] !== undefined }
  function _tabUnsaved(id) { return store._dirtyTabs[id] === true || store._tabSent[id] !== undefined }

  function _recount() {
    var seen = Object.create(null), n = 0
    var maps = [store._dirty, store._sent, store._dirtyTabs, store._tabSent]
    for (var m = 0; m < maps.length; m++)
      for (var k in maps[m]) if (!seen[k]) { seen[k] = true; n++ }
    store.unsavedCount = n
    store._checkSettled()
  }

  // Copy and export read the database, so they wait here until the note's
  // own edits and its tabs' are acknowledged, and learn when one was refused
  // or could not be sent: otherwise "Copied" could cover the previous body.
  // Answers as soon as nothing is in flight; a write that failed, or never
  // went (helper away, over 5 MB), is reported, never waited for.
  property var _settleWaiters: []

  function settled(id, cb) {
    store.flush()
    store._settleWaiters = store._settleWaiters.concat([{ id: id, cb: cb }])
    store._checkSettled()
  }

  function _inFlight(id) {
    if (store._sent[id] !== undefined) return true
    var tabs = store.tabsFor(id)
    for (var i = 0; i < tabs.length; i++) if (store._tabSent[tabs[i].id] !== undefined) return true
    return false
  }

  function _unsavedError(id) {
    var ids = [id], tabs = store.tabsFor(id)
    for (var i = 0; i < tabs.length; i++) ids.push(tabs[i].id)
    for (var j = 0; j < ids.length; j++) {
      var k = ids[j], own = k === id
      if (store.isTooLarge(k)) return (own ? "the note" : "a tab") + " exceeds 5 MB and is not saved"
      if (own ? store._dirty[k] === true : store._dirtyTabs[k] === true)
        return store.saveErrors[k] !== undefined ? "not saved: " + store.saveErrors[k] : "unsaved changes could not be written"
    }
    return null
  }

  function _checkSettled() {
    if (!store._settleWaiters.length) return
    var keep = [], done = []
    for (var i = 0; i < store._settleWaiters.length; i++) {
      var w = store._settleWaiters[i]
      if (store._inFlight(w.id)) keep.push(w); else done.push(w)
    }
    store._settleWaiters = keep
    for (var j = 0; j < done.length; j++) done[j].cb(store._unsavedError(done[j].id))
  }

  // A row from the helper, unless local edits are still unsaved: then the
  // local copy wins and only the fields the helper owns are taken over.
  function _fromServer(row) {
    var local = store.notes[row.id]
    if (!local || !store._unsaved(row.id)) return row
    var merged = ({})
    for (var k in local) merged[k] = local[k]
    merged.piled = row.piled
    merged.updatedAt = row.updatedAt
    return merged
  }

  // A row without its body (past the reply budget), or one older than a save
  // acknowledged since the rows were listed (`touched`), is never installed as is.
  function _tabFromServer(row, touched) {
    if (!row.bodyPending && !store._tabUnsaved(row.id) && !(touched && touched[row.id])) return row
    return store._tabById(row.id) || row
  }

  // While a reload waits for bodies the helper left out of its list, the list
  // is already a snapshot: every note (or note's tabs) the cache changes
  // meanwhile (created, saved, stacked, restored, deleted) is recorded here
  // and wins over its row when the list is installed. null when no reload
  // is waiting.
  property var _touched: null
  property var _touchedTabNotes: null   // a note whose tab list changed (created, deleted, edited, restored)
  property var _touchedTabs: null       // a tab whose save was acknowledged
  property var _deletedTabs: null       // a tab the helper deleted
  function _touch(id) { if (store._touched) store._touched[id] = true }
  function _touchTabs(noteId) { if (store._touchedTabNotes && noteId) store._touchedTabNotes[noteId] = true }
  function _touchTab(tabId) { if (store._touchedTabs) store._touchedTabs[tabId] = true }
  function _touchDeletedTab(tabId) { if (store._deletedTabs) store._deletedTabs[tabId] = true }

  // Several requests at once; cb(err, results) once every one has answered,
  // results in request order (the first error wins).
  function _fetchEach(reqs, cb) {
    var results = new Array(reqs.length), left = reqs.length, failed = null
    if (!left) { cb(null, results); return }
    reqs.forEach(function(r, i) {
      store._call(r[0], r[1], function(err, result) {
        if (err && failed === null) failed = err
        results[i] = result
        if (--left === 0) cb(failed, results)
      })
    })
  }

  function _tabById(tabId) {
    var list = store.tabsFor(store._tabNote[tabId])
    for (var i = 0; i < list.length; i++) if (list[i].id === tabId) return list[i]
    return null
  }

  function tabsFor(noteId) { return store.tabs[noteId] || [] }

  // Server rows for one or every note, merged with the cache: an unsaved local
  // tab wins over its row and is kept even when the helper did not list it
  // (a stacked note's tabs are not listed until the note is restored).
  function _mergeTabs(rows, noteId, touched) {
    var grouped = Object.create(null), index = Object.create(null)
    function add(t) {
      if (!grouped[t.noteId]) grouped[t.noteId] = []
      grouped[t.noteId].push(t)
      index[t.id] = t.noteId
    }
    for (var i = 0; i < rows.length; i++) add(store._tabFromServer(rows[i], touched))
    for (var tabId in store._tabNote) {
      if (index[tabId] || !store._tabUnsaved(tabId)) continue
      if (noteId && store._tabNote[tabId] !== noteId) continue
      var local = store._tabById(tabId)
      if (local) add(local)
    }
    for (var id in grouped) grouped[id].sort(function(a, b) { return a.position - b.position })
    return { grouped: grouped, index: index }
  }

  function _setTabs(noteId, list) {
    list.sort(function(a, b) { return a.position - b.position })
    var next = Object.create(null)
    for (var k in store.tabs) next[k] = store.tabs[k]
    if (list.length) next[noteId] = list; else delete next[noteId]
    store.tabs = next
    store._touchTabs(noteId)
    store.noteTabsChanged(noteId)
  }

  function _loadTabs(cb) {
    store._call("listTabs", {}, function(err, list) {
      if (err) { if (cb) cb(err); return }
      // Bodies past the helper's reply budget (bodyPending) come one by one;
      // an unsaved tab keeps its local copy instead. Meanwhile the cache's
      // changes are recorded: a note whose tabs changed keeps them.
      var want = []
      for (var p = 0; p < list.length; p++) if (list[p].bodyPending && !store._tabUnsaved(list[p].id)) want.push(p)
      store._touchedTabNotes = Object.create(null)
      store._touchedTabs = Object.create(null)
      store._deletedTabs = Object.create(null)
      store._fetchEach(want.map(function(p) { return ["getTab", { tabId: list[p].id }] }), function(e, got) {
        var touched = store._touchedTabNotes || Object.create(null)
        var touchedTabs = store._touchedTabs || Object.create(null)
        var deleted = store._deletedTabs || Object.create(null)
        // A note being restored: its tabs were fetched and installed while the
        // list (made while it was still stacked) left them out.
        for (var rid in store._restoring) touched[rid] = true
        store._touchedTabNotes = null
        store._touchedTabs = null
        store._deletedTabs = null
        if (e) { if (cb) cb(e); return }
        var byId = Object.create(null)
        for (var g = 0; g < want.length; g++) list[want[g]] = got[g]   // null: deleted meanwhile
        for (var b = 0; b < list.length; b++) if (list[b]) byId[list[b].id] = list[b]
        var merged = store._mergeTabs(list.filter(function(r) { return !!r && !touched[r.noteId] }), "", touchedTabs)
        // A note whose tab list changed meanwhile gets the union of its cached
        // tabs (the cache may hold only the new one at startup) and its listed
        // ones, minus the deleted; a listed body still lands on a cached tab
        // unless that tab is newer, and the cache decides positions.
        for (var tn in touched) {
          var out = [], seen = Object.create(null)
          if (store.notes[tn]) {
            var cur = store.tabsFor(tn)
            for (var c = 0; c < cur.length; c++) {
              var t = cur[c], row = byId[t.id]
              seen[t.id] = true
              if (store._tabUnsaved(t.id) || touchedTabs[t.id] || !row || row.bodyPending) { out.push(t); continue }
              var withBody = ({}); for (var k in row) withBody[k] = row[k]
              withBody.position = t.position
              out.push(withBody)
            }
            for (var l = 0; l < list.length; l++) {
              var r = list[l]
              if (!r || r.noteId !== tn || seen[r.id] || deleted[r.id]) continue
              out.push(store._tabFromServer(r, touchedTabs))
            }
            out.sort(function(a, b) { return a.position - b.position })
          }
          if (out.length) merged.grouped[tn] = out; else delete merged.grouped[tn]
          for (var j = 0; j < out.length; j++) merged.index[out[j].id] = tn
        }
        store.tabs = merged.grouped
        store._tabNote = merged.index
        if (cb) cb(null)
      })
    })
  }

  // One note's tabs from the helper (bodies included), installed in the cache.
  // `touched`: tabs whose save was acknowledged after the rows were listed.
  function _installTabs(noteId, rows, touched) {
    var merged = store._mergeTabs(rows, noteId, touched)
    var index = Object.create(null)
    for (var k in store._tabNote) if (store._tabNote[k] !== noteId) index[k] = store._tabNote[k]
    for (var t in merged.index) index[t] = noteId
    store._tabNote = index
    store._setTabs(noteId, merged.grouped[noteId] || [])
  }

  function createTab(noteId, cb) {
    store._call("createTab", { noteId: noteId }, function(err, tab) {
      if (!err && tab) {
        var idx = store._tabNote; idx[tab.id] = noteId; store._tabNote = idx
        store._setTabs(noteId, store.tabsFor(noteId).concat([tab]))
      }
      if (cb) cb(err, tab)
    })
  }

  // Merge a patch into a cached tab and schedule a write, like updateNote.
  function updateTab(tabId, patch) {
    var noteId = store._tabNote[tabId]
    if (!noteId) return
    var list = store.tabsFor(noteId).slice()
    for (var i = 0; i < list.length; i++) {
      if (list[i].id !== tabId) continue
      var merged = ({})
      for (var k in list[i]) merged[k] = list[i][k]
      for (var q in patch) merged[q] = patch[q]
      list[i] = merged
    }
    store._setTabs(noteId, list)
    var d = store._dirtyTabs; d[tabId] = true; store._dirtyTabs = d
    var r = store._tabRev; r[tabId] = (r[tabId] || 0) + 1; store._tabRev = r
    store._recount()
    flushTimer.restart()
  }

  // The tab, its unsaved edits and its settings go only once the helper has
  // deleted it; a refused or failed deletion changes nothing.
  function deleteTab(tabId, cb) {
    var noteId = store._tabNote[tabId]
    store._call("deleteTab", { tabId: tabId }, function(err) {
      if (!err && noteId) {
        var d = store._dirtyTabs; delete d[tabId]; store._dirtyTabs = d
        var s = store._tabSent; delete s[tabId]; store._tabSent = s
        var big = store._tooLarge; delete big[tabId]; store._tooLarge = big
        store._recount()
        store._touchDeletedTab(tabId)
        store._dropSettings("note." + noteId + ".", "." + tabId)
        var idx = store._tabNote; delete idx[tabId]; store._tabNote = idx
        var rest = [], pos = 1
        var list = store.tabsFor(noteId)
        for (var i = 0; i < list.length; i++) {
          if (list[i].id === tabId) continue
          var t = ({}); for (var k in list[i]) t[k] = list[i][k]
          t.position = pos++
          rest.push(t)
        }
        store._setTabs(noteId, rest)
      }
      if (cb) cb(err)
    })
  }

  function noteById(id) { return store.notes[id] || null }

  function _rebuild() {
    var open = [], waiting = [], stacked = []
    for (var id in store.notes) {
      var n = store.notes[id]
      if (store._pendingStack[id] !== undefined) waiting.push(n)
      else if (n.piled) stacked.push(n)
      else open.push(n)
    }
    open.sort(function(a, b) { return a.zOrder - b.zOrder || (a.createdAt < b.createdAt ? -1 : 1) })
    // Notes still waiting to be stacked are the newest ones in the stack.
    waiting.sort(function(a, b) { return store._pendingStack[b.id].at - store._pendingStack[a.id].at })
    stacked.sort(function(a, b) { return a.updatedAt < b.updatedAt ? 1 : -1 })
    store.openNotes = open
    store.stackedNotes = waiting.concat(stacked)
  }

  function _put(note) {
    note = store._fromServer(note)
    if (store._landedOpen[note.id]) { var lo = store._landedOpen; delete lo[note.id]; store._landedOpen = lo }
    var next = Object.create(null)
    for (var k in store.notes) next[k] = store.notes[k]
    next[note.id] = note
    store.notes = next
    store._touch(note.id)
    store._rebuild()
    store.noteChanged(note.id)
  }

  function _remove(id) {
    var next = Object.create(null)
    for (var k in store.notes) if (k !== id) next[k] = store.notes[k]
    store.notes = next
    store._touch(id)
    if (store.tabs[id]) store._setTabs(id, [])
    store._dropPendingStack(id)
    if (store._landedOpen[id]) { var lo = store._landedOpen; delete lo[id]; store._landedOpen = lo }
    var d = store._dirty; delete d[id]; store._dirty = d
    var s = store._sent; delete s[id]; store._sent = s
    var e = store.saveErrors; delete e[id]; store.saveErrors = e
    var big = store._tooLarge; delete big[id]; store._tooLarge = big
    store._dropSettings("note." + id + ".", "")
    store._recount()
    store._rebuild()
    store.noteRemoved(id)
  }

  // Forget the settings the helper purged with a note or a tab (keys starting
  // with `prefix` and, when given, ending with `suffix`).
  function _dropSettings(prefix, suffix) {
    function matches(k) {
      return k.indexOf(prefix) === 0 && (!suffix || (k.length > suffix.length && k.lastIndexOf(suffix) === k.length - suffix.length))
    }
    var s = ({}), changed = false
    for (var k in store.settings) { if (matches(k)) changed = true; else s[k] = store.settings[k] }
    if (changed) store.settings = s
    var d = Object.create(null)
    for (var p in store._dirtySettings) if (!matches(p)) d[p] = true
    store._dirtySettings = d
  }

  function _call(op, args, cb) {
    if (!store.client) { if (cb) cb("no helper client", null); return }
    store.client.request(op, args, function(err, result) {
      if (err) {
        store.helperError = op + ": " + err
        console.warn("onote:", store.helperError)
      }
      if (cb) cb(err, result)
    })
  }

  // One reload at a time: two side by side would share the change trackers
  // (_touched and the tab maps), and a save acknowledged between their lists
  // could be replaced by the older list's row (an empty bodyPending one,
  // even) and written back on the next edit. A reload asked for meanwhile
  // runs once this one ends, and every caller is answered by the run that
  // finishes.
  property bool _reloading: false
  property bool _reloadAgain: false
  property var _reloadWaiters: []

  function reload(cb) {
    if (cb) store._reloadWaiters = store._reloadWaiters.concat([cb])
    if (store._reloading) { store._reloadAgain = true; return }
    store._reloading = true
    store._reloadNow(store._reloadDone)
  }

  function _reloadDone(err) {
    if (store._reloadAgain) { store._reloadAgain = false; store._reloadNow(store._reloadDone); return }
    store._reloading = false
    var waiters = store._reloadWaiters
    store._reloadWaiters = []
    for (var i = 0; i < waiters.length; i++) waiters[i](err)
  }

  function _reloadNow(cb) {
    store.syncing = true
    var landedBefore = store._landedSeq   // records newer than this list are not settled by it
    store._call("listNotes", {}, function(err, list) {
      if (err) { store.syncing = false; if (cb) cb(err); return }
      // Bodies the helper left out to keep its reply bounded (bodyPending)
      // come one by one before any note is installed: a window must never
      // open on an empty body it could then save. An unsaved note is not
      // fetched; its local copy wins either way. Meanwhile the cache's
      // changes are recorded (_touched) and win over the older list.
      var want = []
      // A row without its body, or an open note's without the desktop's image
      // icon (iconPending, read by the paste budget), is fetched whole before
      // anything is installed. Never a stacked note: fetched whole it would
      // bring its body into the cache; a restore returns the whole row.
      for (var p = 0; p < list.length; p++) if ((list[p].bodyPending || (list[p].iconPending && list[p].piled !== true)) && !store._unsaved(list[p].id)) want.push(p)
      store._touched = Object.create(null)
      store._fetchEach(want.map(function(p) { return ["getNote", { noteId: list[p].id }] }), function(e, got) {
        var touched = store._touched || Object.create(null)
        store._touched = null
        if (e) { store.syncing = false; if (cb) cb(e); return }
        for (var g = 0; g < want.length; g++) list[want[g]] = got[g]   // null: deleted meanwhile
        var next = Object.create(null)
        for (var i = 0; i < list.length; i++) {
          var row = list[i]
          if (!row) continue
          if (touched[row.id]) { if (store.notes[row.id]) next[row.id] = store.notes[row.id]; continue }
          next[row.id] = store._fromServer(row)
        }
        for (var c in touched) if (!next[c] && store.notes[c]) next[c] = store.notes[c]
        store.notes = next
        // This list settles the landed reopens recorded before it was asked
        // for; one recorded since needs a list taken after it.
        var lo = Object.create(null), unsettled = false
        for (var l in store._landedOpen) if (next[l] && store._landedOpen[l] > landedBefore) { lo[l] = store._landedOpen[l]; unsettled = true }
        store._landedOpen = lo
        // A note deleted elsewhere takes its waiting stack with it.
        for (var w in store._pendingStack) if (!next[w]) store._dropPendingStack(w)
        store._rebuild()
        // Tabs and settings load side by side; the reload is done only when
        // both are in, and fails once if either fails: windows would apply
        // their remembered tab against missing tabs or settings and never
        // try again.
        var tabsDone = false, settingsDone = false, failed = false
        var finish = function() {
          if (failed || !tabsDone || !settingsDone) return
          store.ready = true
          store.helperError = ""
          store.syncing = false
          store.resynced()
          if (cb) cb(null)
          if (unsettled) Qt.callLater(function() { store.reload() })
        }
        var failOnce = function(e) { if (failed) return; failed = true; store.syncing = false; if (cb) cb(e) }
        store._loadTabs(function(eT) {
          if (eT) { failOnce(eT); return }
          // Edits that waited out a helper restart go now.
          if (store._hasPending()) store.flush()
          tabsDone = true; finish()
        })
        store._call("listSettings", {}, function(e2, s) {
          if (e2) { failOnce(e2); return }
          store._takeSettings(s || {})
          store._call("listThemes", {}, function(e3, t) {
            if (e3) { failOnce(e3); return }   // themes too: a custom-* note would show the system palette, and a theme cycle would overwrite its name
            store.customThemes = t || []
            settingsDone = true; finish()
          })
        })
      })
    })
  }

  function createNote(cb) {
    store._call("createNote", {}, function(err, note) {
      if (!err && note) store._put(note)
      if (cb) cb(err, note)
    })
  }

  // New note prefilled with the clipboard text (one block per line).
  function createNoteFromClipboard(cb) {
    store._call("createNoteFromClipboard", {}, function(err, note) {
      if (!err && note) store._put(note)
      if (cb) cb(err, note)
    })
  }

  function copyMarkdown(id, cb) { store._call("copyMarkdown", { noteId: id }, cb) }
  // { src, width, height } when the clipboard holds an image, else null.
  // `titleIcon`: the note's image icon, if any, charged to the pixel budget.
  function clipboardImage(sources, titleIcon, cb) { store._call("clipboardImage", { sources: sources || [], titleIcon: titleIcon || "" }, cb) }
  function exportNote(id, cb) { store._call("exportNote", { noteId: id }, cb) }

  // Markdown mirror folder; "" or "off" disables. Refreshes the cached settings.
  function setMirrorDir(dir, cb) {
    store._call("setMirrorDir", { dir: dir }, function(err, result) {
      store._call("listSettings", {}, function(e2, s) { if (!e2 && s) store._takeSettings(s); if (cb) cb(err, result) })
    })
  }

  // Merge a partial patch into the cached note and schedule a write.
  function updateNote(id, patch) {
    var cur = store.notes[id]
    if (!cur) return
    var merged = ({})
    for (var k in cur) merged[k] = cur[k]
    for (var p in patch) merged[p] = patch[p]
    // The helper's preview describes the body it was made from.
    if (patch.contentBlocks !== undefined) delete merged.preview
    // Update the cache without rebuilding the lists (content edits must not
    // reorder or recreate windows); the Library, if open, rebuilds its rows
    // on noteChanged.
    var next = Object.create(null)
    for (var n in store.notes) next[n] = store.notes[n]
    next[id] = merged
    store.notes = next
    store.noteChanged(id)
    var d = store._dirty
    d[id] = true
    store._dirty = d
    var r = store._rev; r[id] = (r[id] || 0) + 1; store._rev = r
    store._recount()
    flushTimer.restart()
  }

  function _sendTab(tabId, rev) {
    var noteId = store._tabNote[tabId]
    var list = store.tabsFor(noteId), tab = null
    for (var j = 0; j < list.length; j++) if (list[j].id === tabId) tab = list[j]
    if (!tab) return
    if (store._tooLarge[tabId] === rev) { var p = store._dirtyTabs; p[tabId] = true; store._dirtyTabs = p; return }
    var s = store._tabSent; s[tabId] = rev; store._tabSent = s
    store._call("updateTab", { tab: tab }, function(err, saved) {
      if (store._tabSent[tabId] === rev) { var s2 = store._tabSent; delete s2[tabId]; store._tabSent = s2 }
      var latest = (store._tabRev[tabId] || 0) === rev
      if (err) {
        // Keep the content pending unless a newer revision is already queued.
        if (latest && store._tabNote[tabId]) {
          var d = store._dirtyTabs; d[tabId] = true; store._dirtyTabs = d
          if (!store._markTooLarge(tabId, err, rev)) store._scheduleRetry()
        }
      } else if (latest) {
        store._savedAgain(tabId); store._touchTab(tabId)
        var acked = store._restoreAcked[noteId]; if (acked) acked[tabId] = true
        store._evictStacked(noteId)
      }
      store._recount()
    })
  }

  function _sendNote(id, rev) {
    var note = store.notes[id]
    if (!note) return
    if (store._tooLarge[id] === rev) { var p = store._dirty; p[id] = true; store._dirty = p; return }
    var s = store._sent; s[id] = rev; store._sent = s
    store._call("updateNote", { note: note }, function(err, saved) {
      if (store._sent[id] === rev) { var s2 = store._sent; delete s2[id]; store._sent = s2 }
      var latest = (store._rev[id] || 0) === rev
      if (err) {
        // Keep the content pending unless a newer revision is already queued
        // or in flight; that one decides.
        if (latest && store.notes[id]) {
          var d = store._dirty; d[id] = true; store._dirty = d
          var e = store.saveErrors; e[id] = err; store.saveErrors = e
          if (!store._markTooLarge(id, err, rev)) store._scheduleRetry()
        }
        store._recount()
        return
      }
      if (store.saveErrors[id] !== undefined) { var e2 = store.saveErrors; delete e2[id]; store.saveErrors = e2 }
      if (latest) store._savedAgain(id)
      retryTimer.interval = 2000
      // Install the acknowledged row only when nothing newer exists locally.
      if (saved && latest && store.notes[id]) {
        var next = Object.create(null)
        for (var n in store.notes) next[n] = store.notes[n]
        next[saved.id] = saved
        store.notes = next
        store._touch(saved.id)
        if (saved.piled) store._evictStacked(id)   // acknowledged after the stack
        store.noteChanged(saved.id)
      }
      store._recount()
    })
  }

  function _hasPending() {
    return Object.keys(store._dirty).length > 0 || Object.keys(store._dirtyTabs).length > 0
      || Object.keys(store._dirtySettings).length > 0
  }

  function flush() {
    // A failed setting keeps its marker until a write of its value succeeds, so
    // a reload answered meanwhile cannot put the old value back.
    // A retry for a note being deleted is held like a new write would be.
    var keys = Object.keys(store._dirtySettings)
    for (var k = 0; k < keys.length; k++) {
      if (store._holdForDeletion(keys[k], store.settings[keys[k]])) {
        var ds = store._dirtySettings; delete ds[keys[k]]; store._dirtySettings = ds
      } else store._sendSetting(keys[k])
    }
    var tabIds = Object.keys(store._dirtyTabs)
    store._dirtyTabs = Object.create(null)
    for (var t = 0; t < tabIds.length; t++) store._sendTab(tabIds[t], store._tabRev[tabIds[t]] || 0)
    var ids = Object.keys(store._dirty)
    store._dirty = Object.create(null)
    for (var i = 0; i < ids.length; i++) store._sendNote(ids[i], store._rev[ids[i]] || 0)
    store._recount()
  }

  // Failed writes are retried with a growing delay while the helper is up;
  // while it is down, reload() flushes them once it is back.
  function _scheduleRetry() {
    if (!store.client || !store.client.ready) return
    if (!retryTimer.running) retryTimer.start()
  }

  function stackNote(id, cb) {
    store.flush()
    store._bumpLife(id)
    store._call("stackNote", { noteId: id }, function(err, note) {
      if (!err && note) { store._put(note); store._evictStacked(id) }
      if (cb) cb(err, note)
    })
  }

  // A stacked note keeps what the Library shows (its fields and a preview)
  // and nothing more, like after a reload: the body and the tabs are fetched
  // again when it is restored, so the shell does not hold every body it ever
  // stacked. Unsaved edits stay (body and tabs) until acknowledged.
  function _evictStacked(id) {
    var note = store.notes[id]
    if (!note || note.piled !== true || store._restoring[id]) return
    // The note's window may still be up (an explicit hide keeps it until this
    // reply) with keystrokes typed since its last flush: it hands them over
    // now, while the tabs are still indexed, so they count as unsaved below.
    store.noteStacked(id)
    if (!store._unsaved(id) && note.contentBlocks) {
      var slim = ({}); for (var f in note) slim[f] = note[f]
      if (typeof slim.preview !== "string") slim.preview = NotePreview.text(slim.contentBlocks)
      slim.contentBlocks = ""
      var next = Object.create(null)
      for (var k in store.notes) next[k] = store.notes[k]
      next[id] = slim; store.notes = next
      store._touch(id)
      store._rebuild()
    }
    var tabs = store.tabsFor(id)
    for (var i = 0; i < tabs.length; i++) if (!store._tabUnsaved(tabs[i].id)) { store._installTabs(id, []); break }
  }

  // The compositor closed the window (Super+W, or Omarchy closing everything
  // before a shutdown): stacked in the UI now, on disk once no window has
  // closed for stackDelayMs.
  function stackNoteLater(id) {
    var note = store.notes[id]
    if (!note || store.isStacked(note)) return
    store.flush()
    store._bumpLife(id)
    var p = store._pendingStack; p[id] = { at: Date.now(), sent: false }; store._pendingStack = p
    store._rebuild()
    stackTimer.restart()
  }

  function _dropPendingStack(id) {
    if (store._pendingStack[id] === undefined) return false
    var p = store._pendingStack; delete p[id]; store._pendingStack = p
    return true
  }

  // The entry stays until the reply, so the note never flashes open; a reply
  // for an entry that was reopened, deleted or replaced meanwhile is ignored.
  // A failed write waits for the next tick, or for the helper to come back.
  function _commitPendingStacks() {
    Object.keys(store._pendingStack).forEach(function(id) {
      var entry = store._pendingStack[id]
      // In flight already, held by a Restore All, or a reopen is settling
      // the disk itself: a retry now could land after the unstack and stack
      // the note behind its back.
      if (entry.sent || entry.held || store._restoring[id]) return
      // sent: in flight now; tried: sent at least once, so the write may
      // have landed even when its reply was an error (helper gone mid-way).
      entry.sent = true; entry.tried = true
      store._call("stackNote", { noteId: id }, function(err, note) {
        if (store._pendingStack[id] !== entry) return
        if (err && !/not found/i.test(String(err))) {
          entry.sent = false
          if (store.client && store.client.ready) stackTimer.restart()
          return
        }
        // Gone (deleted elsewhere): the cached row goes with the waiting
        // entry, or a rebuild would reopen a note that no longer exists.
        if (err) { store._remove(id); return }
        store._dropPendingStack(id)
        if (note) { store._put(note); store._evictStacked(id) } else store._rebuild()
      })
    })
  }

  // Restores in flight (id -> lifecycle generation): the tabs fetched for
  // one must survive a save acknowledged meanwhile, which would otherwise
  // evict them while the cached row still says stacked. The generation
  // keeps an older reopen's end from clearing a newer reopen's guard.
  property var _restoring: Object.create(null)
  // Per restore in flight: tabs whose save was acknowledged after tabsFor
  // was asked. The rows are a snapshot like a reload's list, and a retry sent
  // behind tabsFor is answered after it; its row would otherwise be installed
  // over the acknowledged body and written back on the next edit.
  property var _restoreAcked: Object.create(null)

  // A delayed stack that waited for the reopen (closed again meanwhile, or
  // a retry) goes back to the timer, whatever the reopen's outcome. Only the
  // reopen that owns the guard ends it: a superseded one has nothing to
  // hand back, the newer reopen will.
  function _restoreDone(id, gen) {
    if (store._restoring[id] !== gen) return
    var r = store._restoring; delete r[id]; store._restoring = r
    var a = store._restoreAcked; delete a[id]; store._restoreAcked = a
    var w = store._pendingStack[id]
    if (w !== undefined && !w.sent && !w.held) stackTimer.restart()
  }

  // A stacked note's tabs are not cached (listTabs leaves them out), so their
  // bodies are fetched before the note opens: a tab is never shown, or saved,
  // empty. If they cannot be fetched the note stays stacked.
  function restoreNote(id, cb) {
    var note = store.notes[id]
    var waiting = store._pendingStack[id]
    // Still waiting with nothing ever sent: the disk is open and the cache is
    // current, tabs included, so the window opens at once and only
    // unstackNote is sent (a no-op on disk). Once a stack has been sent, even
    // one whose reply was an error, it may have landed, and a reload
    // meanwhile may have dropped the tabs: the
    // note stays shown stacked, its entry kept so the stack reply is taken
    // as usual, and it reopens like any stacked note, tabs fetched first.
    var unsent = waiting !== undefined && !waiting.tried && note && note.piled !== true
    if (unsent) { store._dropPendingStack(id); store._rebuild() }
    var gen = store._bumpLife(id)
    var r0 = store._restoring; r0[id] = gen; store._restoring = r0
    var acked = Object.create(null), a0 = store._restoreAcked; a0[id] = acked; store._restoreAcked = a0
    // Superseded by a newer stack, hide, delete or reopen: that one owns the disk now.
    var stale = function() { if (store._life[id] === gen) return false; store._restoreDone(id, gen); if (cb) cb(null, null); return true }
    var fail = function(e) {
      store._restoreDone(id, gen)
      // An older reopen's unstack landed meanwhile: the disk is open, show it.
      store._settleLandedOpen(id)
      if (cb) cb(e, null)
    }
    var unstack = function() {
      store._call("unstackNote", { noteId: id }, function(e2, n2) {
        // Superseded, but the disk is open now: kept aside (_landedOpen) so
        // the newer operation, if refused, can put the open row back; one
        // that goes through settles the row itself. No window opens meanwhile.
        if (!e2 && n2 && store._life[id] !== gen) {
          // The stack this reopen answered is void: neither its reply nor a
          // retry may stack the note again. A close queued since has its own entry.
          if (waiting !== undefined && store._pendingStack[id] === waiting) store._dropPendingStack(id)
          var u = store._landedOpen; u[id] = ++store._landedSeq; store._landedOpen = u
        }
        if (stale()) return
        if (e2) { fail(e2); return }
        // A stack still waiting or unanswered is void now: neither its
        // reply nor a retry may stack the note again.
        store._dropPendingStack(id)
        store._restoreDone(id, gen)
        if (n2) store._put(n2)
        if (cb) cb(null, n2)
      })
    }
    if (unsent) { unstack(); return }
    store._call("tabsFor", { noteId: id }, function(err, rows) {
      if (stale()) return
      if (err) { fail(err); return }
      rows = rows || []
      // Bodies past the helper's reply budget come one by one, like a reload's.
      var want = []
      for (var p = 0; p < rows.length; p++) if (rows[p].bodyPending && !store._tabUnsaved(rows[p].id)) want.push(p)
      store._fetchEach(want.map(function(p) { return ["getTab", { tabId: rows[p].id }] }), function(e, got) {
        if (stale()) return
        if (e) { fail(e); return }
        for (var g = 0; g < want.length; g++) rows[want[g]] = got[g]   // null: deleted meanwhile
        store._installTabs(id, rows.filter(function(r) { return !!r }), acked)
        unstack()
      })
    })
  }

  // Like deleteTab: the note's unsaved edits stay protected until the helper
  // has deleted it (_remove drops every marker); a refused deletion changes nothing.
  // Notes with a deletion in flight (id -> true): a per-note setting written
  // meanwhile (a title still in its debounce, the window's teardown flush)
  // would land after the helper's purge and outlive the note.
  // Such writes are held (id -> { key: value }) until the outcome is known:
  // dropped with the note, applied when the deletion was refused.
  property var _deleting: Object.create(null)
  // A superseded reopen whose unstack reached the disk (id -> a sequence
  // number): the cache may say stacked over an open row until the operation
  // that superseded it settles the row. One that is refused settles it with
  // a reload instead, which installs the disk's state whole (bodies, tabs,
  // pending closes and unsaved edits respected). The record outlives every
  // reload sent before it, and every one that fails; it goes with a newer
  // row installed (_put), a reload sent after it that succeeds, a confirmed
  // Hide All, or the note's removal.
  property var _landedOpen: Object.create(null)
  property int _landedSeq: 0

  function _settleLandedOpen(id) {
    if (!store._landedOpen[id]) return
    store.reload()
  }

  function deleteNote(id, cb) {
    var d = store._deleting; d[id] = Object.create(null); store._deleting = d
    var gen = store._bumpLife(id)
    store._call("deleteNote", { noteId: id }, function(err) {
      var held = store._deleting[id] || Object.create(null)
      var d2 = store._deleting; delete d2[id]; store._deleting = d2
      if (!err) store._remove(id)
      else {
        // Refused, and nothing newer (a Hide All queued behind it, say) owns
        // the row: a reopen that landed underneath is settled by a reload.
        // Otherwise the newer operation's reply settles the row.
        if (store._life[id] === gen) store._settleLandedOpen(id)
        for (var k in held) store.setSetting(k, held[k])
      }
      if (cb) cb(err)
    })
  }

  // Stacking everything covers the notes waiting to be stacked at that
  // moment; they are let go only once the helper has done it, and stay
  // waiting (timer and all) if it could not. A note closed after the request
  // went out (behind a Restore All, say) is not covered: its own delayed
  // write still owes the disk.
  function stackAll(cb) {
    store.flush()
    for (var id in store.notes) store._bumpLife(id)
    stackTimer.stop()
    var covered = Object.create(null)
    // Covered entries count as attempted: the bulk write may land even if
    // its reply is lost, so a reopen or Restore All meanwhile waits for the
    // disk instead of showing the note open over a stacked row.
    for (var w in store._pendingStack) { covered[w] = store._pendingStack[w]; covered[w].tried = true }
    store._call("stackAll", {}, function(err) {
      if (err) { if (Object.keys(store._pendingStack).length) stackTimer.restart() }
      else {
        // Everything is stacked on disk now: an unstack that landed before
        // (its reply came first) is void.
        store._landedOpen = Object.create(null)
      }
      if (!err) for (var c in covered) {
        // The entry goes if it is still the one covered (a close queued since
        // keeps its own). The row is stacked on disk either way, entry or no
        // entry (a reopen's unstack may have superseded it meanwhile): the
        // cached row says so too, or the note would show open (window and
        // all) until the reload, and for good if the reload fails.
        if (store._pendingStack[c] === covered[c]) store._dropPendingStack(c)
        var row = store.notes[c]
        if (row && row.piled !== true) {
          var stacked = ({}); for (var f in row) stacked[f] = row[f]
          stacked.piled = true
          store._put(stacked); store._evictStacked(c)
        }
      }
      store._rebuild()
      store._reloadAfter("stackAll", err, cb)
    })
  }

  // Restoring everything cancels the waiting stacks never sent: the disk is
  // open there. One sent at least once may have landed (its reply lost with
  // the helper), so it stays shown stacked, held from retries, until the
  // helper confirms it restored everything; if it could not, the entry is
  // handed back to the timer.
  function restoreAll(cb) {
    store.flush()
    for (var id in store.notes) store._bumpLife(id)   // a single reopen in flight must not re-queue a stack
    stackTimer.stop()
    var held = Object.create(null), keep = Object.create(null)
    var token = ++store._restoreAllSeq   // the hold belongs to this call
    for (var w in store._pendingStack) {
      var entry = store._pendingStack[w]
      if (entry.tried) { entry.held = token; held[w] = entry; keep[w] = entry }
    }
    store._pendingStack = keep   // its own object: a close queued later is not "held"
    store._rebuild()
    store._call("restoreAll", {}, function(err) {
      for (var h in held) {
        if (store._pendingStack[h] !== held[h]) continue
        // Restored on disk: the entry goes whoever holds it. Refused: only
        // this call's own hold is released, a newer Restore All keeps its.
        if (!err) store._dropPendingStack(h)
        else if (held[h].held === token) held[h].held = false
      }
      if (err && Object.keys(store._pendingStack).length && store.client && store.client.ready) stackTimer.restart()
      store._rebuild()
      store._reloadAfter("restoreAll", err, cb)
    })
  }

  // Resync after a bulk change, but report the change's own failure: a
  // successful reload would otherwise clear the error and answer null.
  function _reloadAfter(op, err, cb) {
    store.reload(function(e2) {
      if (err) store.helperError = op + ": " + err
      if (cb) cb(err || e2)
    })
  }

  function search(query, cb) {
    store._call("searchNoteIds", { q: query }, cb)
  }

  function getSetting(key, fallback) {
    var v = store.settings[key]
    return (v === undefined || v === null || v === "") ? fallback : v
  }

  // A note's setting written while the note's deletion is in flight is held
  // until the outcome (see _deleting); true when it was.
  function _holdForDeletion(key, value) {
    var m = /^note\.([^.]+)\./.exec(key)
    if (!m || !store._deleting[m[1]]) return false
    store._deleting[m[1]][key] = String(value)
    return true
  }

  function setSetting(key, value) {
    if (store._holdForDeletion(key, value)) return
    var m = /^note\.([^.]+)\./.exec(key)
    if (m && !store.notes[m[1]]) return   // its note is gone
    var s = ({})
    for (var k in store.settings) s[k] = store.settings[k]
    s[key] = String(value)
    store.settings = s
    store._sendSetting(key)
  }

  // Writes in flight (key -> value): a settings list queued before one of
  // them answers with the older value, which must not replace the new one.
  property var _sentSettings: Object.create(null)

  // A failed write stays pending like a note's (flush() and the retry timer
  // resend it), unless a newer value for the key went out after it.
  function _sendSetting(key) {
    var value = store.settings[key]
    var sent = store._sentSettings; sent[key] = value; store._sentSettings = sent
    store._call("setSetting", { key: key, value: value }, function(err) {
      if (store._sentSettings[key] === value) { var s2 = store._sentSettings; delete s2[key]; store._sentSettings = s2 }
      if (store.settings[key] !== value) return
      var d = store._dirtySettings
      if (err) d[key] = true; else delete d[key]
      store._dirtySettings = d
      if (err) store._scheduleRetry()
    })
  }

  // Settings from the helper, except keys whose local value has not reached
  // it (failed, or still on its way).
  function _takeSettings(s) {
    var merged = ({})
    for (var k in s) merged[k] = s[k]
    for (var d in store._dirtySettings) merged[d] = store.settings[d]
    for (var f in store._sentSettings) merged[f] = store.settings[f]
    store.settings = merged
  }

  function saveTheme(theme, cb) {
    store._call("saveTheme", { theme: theme }, function(err) {
      store._call("listThemes", {}, function(e, t) { if (!e) store.customThemes = t; if (cb) cb(err) })
    })
  }

  function deleteTheme(id, cb) {
    store._call("deleteTheme", { themeId: id }, function(err) {
      store._call("listThemes", {}, function(e, t) { if (!e) store.customThemes = t; if (cb) cb(err) })
    })
  }

  function renderMarkdown(id, cb) {
    store._call("renderMarkdown", { noteId: id }, cb)
  }

  Timer {
    id: flushTimer
    interval: 300
    repeat: false
    onTriggered: store.flush()
  }

  Timer {
    id: stackTimer
    interval: store.stackDelayMs
    repeat: false
    onTriggered: store._commitPendingStacks()
  }

  Timer {
    id: retryTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (!store._hasPending()) { retryTimer.interval = 2000; return }
      retryTimer.interval = Math.min(30000, retryTimer.interval * 2)
      store.flush()
    }
  }

  Connections {
    target: store.client
    function onBecameReady() {
      store.reload()
      if (Object.keys(store._pendingStack).length) stackTimer.restart()
    }
    function onDied(reason) { store.ready = false; store.helperError = reason }
  }

  Component.onDestruction: store.flush()
}
