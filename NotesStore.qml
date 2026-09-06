// In-memory cache of notes plus the API the windows and the library use.
// openNotes / stackedNotes are plain JS arrays that are always REASSIGNED
// (never mutated in place) so bindings and Variants see the change.
import QtQuick

Item {
  id: store

  property var client: null

  property var notes: Object.create(null)          // id -> note object (full row, contentBlocks as JSON string)
  property var openNotes: []
  property var stackedNotes: []
  property var customThemes: []
  property var settings: ({})
  property bool ready: false
  property string helperError: ""

  signal noteChanged(string id)
  signal noteRemoved(string id)
  signal resynced()
  signal noteTabsChanged(string noteId)

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

  function _unsaved(id) { return store._dirty[id] === true || store._sent[id] !== undefined }
  function _tabUnsaved(id) { return store._dirtyTabs[id] === true || store._tabSent[id] !== undefined }

  function _recount() {
    var seen = Object.create(null), n = 0
    var maps = [store._dirty, store._sent, store._dirtyTabs, store._tabSent]
    for (var m = 0; m < maps.length; m++)
      for (var k in maps[m]) if (!seen[k]) { seen[k] = true; n++ }
    store.unsavedCount = n
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

  function _tabFromServer(row) {
    if (!store._tabUnsaved(row.id)) return row
    var list = store.tabsFor(row.noteId)
    for (var i = 0; i < list.length; i++) if (list[i].id === row.id) return list[i]
    return row
  }

  function tabsFor(noteId) { return store.tabs[noteId] || [] }

  function _setTabs(noteId, list) {
    list.sort(function(a, b) { return a.position - b.position })
    var next = Object.create(null)
    for (var k in store.tabs) next[k] = store.tabs[k]
    if (list.length) next[noteId] = list; else delete next[noteId]
    store.tabs = next
    store.noteTabsChanged(noteId)
  }

  function _loadTabs(cb) {
    store._call("listTabs", {}, function(err, list) {
      if (err) { if (cb) cb(err); return }
      var grouped = Object.create(null), index = Object.create(null)
      for (var i = 0; i < list.length; i++) {
        var t = store._tabFromServer(list[i])
        if (!grouped[t.noteId]) grouped[t.noteId] = []
        grouped[t.noteId].push(t)
        index[t.id] = t.noteId
      }
      for (var id in grouped) grouped[id].sort(function(a, b) { return a.position - b.position })
      store.tabs = grouped
      store._tabNote = index
      if (cb) cb(null)
    })
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

  function deleteTab(tabId, cb) {
    var noteId = store._tabNote[tabId]
    var d = store._dirtyTabs; delete d[tabId]; store._dirtyTabs = d
    var s = store._tabSent; delete s[tabId]; store._tabSent = s
    store._recount()
    store._call("deleteTab", { tabId: tabId }, function(err) {
      if (!err && noteId) {
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
    var open = [], stacked = []
    for (var id in store.notes) {
      var n = store.notes[id]
      if (n.piled) stacked.push(n); else open.push(n)
    }
    open.sort(function(a, b) { return a.zOrder - b.zOrder || (a.createdAt < b.createdAt ? -1 : 1) })
    stacked.sort(function(a, b) { return a.updatedAt < b.updatedAt ? 1 : -1 })
    store.openNotes = open
    store.stackedNotes = stacked
  }

  function _put(note) {
    note = store._fromServer(note)
    var next = Object.create(null)
    for (var k in store.notes) next[k] = store.notes[k]
    next[note.id] = note
    store.notes = next
    store._rebuild()
    store.noteChanged(note.id)
  }

  function _remove(id) {
    var next = Object.create(null)
    for (var k in store.notes) if (k !== id) next[k] = store.notes[k]
    store.notes = next
    if (store.tabs[id]) store._setTabs(id, [])
    var d = store._dirty; delete d[id]; store._dirty = d
    var s = store._sent; delete s[id]; store._sent = s
    var e = store.saveErrors; delete e[id]; store.saveErrors = e
    store._recount()
    store._rebuild()
    store.noteRemoved(id)
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

  function reload(cb) {
    store._call("listNotes", {}, function(err, list) {
      if (err) { if (cb) cb(err); return }
      var next = Object.create(null)
      for (var i = 0; i < list.length; i++) next[list[i].id] = store._fromServer(list[i])
      store.notes = next
      store._rebuild()
      store._loadTabs(function(eT) {
        if (eT) console.warn("onote: listTabs failed:", eT)
        // Edits that waited out a helper restart go now.
        if (Object.keys(store._dirty).length || Object.keys(store._dirtyTabs).length) store.flush()
      })
      store._call("listSettings", {}, function(e2, s) {
        if (!e2 && s) store.settings = s
        store._call("listThemes", {}, function(e3, t) {
          if (!e3 && t) store.customThemes = t
          store.ready = true
          store.helperError = ""
          store.resynced()
          if (cb) cb(null)
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
  function clipboardImage(cb) { store._call("clipboardImage", {}, cb) }
  function exportNote(id, cb) { store._call("exportNote", { noteId: id }, cb) }

  // Markdown mirror folder; "" or "off" disables. Refreshes the cached settings.
  function setMirrorDir(dir, cb) {
    store._call("setMirrorDir", { dir: dir }, function(err, result) {
      store._call("listSettings", {}, function(e2, s) { if (!e2 && s) store.settings = s; if (cb) cb(err, result) })
    })
  }

  // Merge a partial patch into the cached note and schedule a write.
  function updateNote(id, patch) {
    var cur = store.notes[id]
    if (!cur) return
    var merged = ({})
    for (var k in cur) merged[k] = cur[k]
    for (var p in patch) merged[p] = patch[p]
    // Update the cache without rebuilding the lists (content edits must not
    // reorder or recreate windows).
    var next = Object.create(null)
    for (var n in store.notes) next[n] = store.notes[n]
    next[id] = merged
    store.notes = next
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
    var s = store._tabSent; s[tabId] = rev; store._tabSent = s
    store._call("updateTab", { tab: tab }, function(err, saved) {
      if (store._tabSent[tabId] === rev) { var s2 = store._tabSent; delete s2[tabId]; store._tabSent = s2 }
      var latest = (store._tabRev[tabId] || 0) === rev
      if (err) {
        // Keep the content pending unless a newer revision is already queued.
        if (latest && store._tabNote[tabId]) { var d = store._dirtyTabs; d[tabId] = true; store._dirtyTabs = d; store._scheduleRetry() }
      }
      store._recount()
    })
  }

  function _sendNote(id, rev) {
    var note = store.notes[id]
    if (!note) return
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
          store._scheduleRetry()
        }
        store._recount()
        return
      }
      if (store.saveErrors[id] !== undefined) { var e2 = store.saveErrors; delete e2[id]; store.saveErrors = e2 }
      retryTimer.interval = 2000
      // Install the acknowledged row only when nothing newer exists locally.
      if (saved && latest && store.notes[id]) {
        var next = Object.create(null)
        for (var n in store.notes) next[n] = store.notes[n]
        next[saved.id] = saved
        store.notes = next
      }
      store._recount()
    })
  }

  function flush() {
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
    store._call("stackNote", { noteId: id }, function(err, note) {
      if (!err && note) store._put(note)
      if (cb) cb(err, note)
    })
  }

  function restoreNote(id, cb) {
    store._call("unstackNote", { noteId: id }, function(err, note) {
      if (!err && note) store._put(note)
      if (cb) cb(err, note)
    })
  }

  function deleteNote(id, cb) {
    var d = store._dirty; delete d[id]; store._dirty = d
    store._call("deleteNote", { noteId: id }, function(err) {
      if (!err) store._remove(id)
      if (cb) cb(err)
    })
  }

  function stackAll(cb) {
    store.flush()
    store._call("stackAll", {}, function(err) { store.reload(cb) })
  }

  function restoreAll(cb) {
    store.flush()
    store._call("restoreAll", {}, function(err) { store.reload(cb) })
  }

  function search(query, cb) {
    store._call("searchNoteIds", { q: query }, cb)
  }

  function getSetting(key, fallback) {
    var v = store.settings[key]
    return (v === undefined || v === null || v === "") ? fallback : v
  }

  function setSetting(key, value) {
    var s = ({})
    for (var k in store.settings) s[k] = store.settings[k]
    s[key] = String(value)
    store.settings = s
    store._call("setSetting", { key: key, value: String(value) })
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
    id: retryTimer
    interval: 2000
    repeat: false
    onTriggered: {
      var pending = Object.keys(store._dirty).length || Object.keys(store._dirtyTabs).length
      if (!pending) { retryTimer.interval = 2000; return }
      retryTimer.interval = Math.min(30000, retryTimer.interval * 2)
      store.flush()
    }
  }

  Connections {
    target: store.client
    function onBecameReady() { store.reload() }
    function onDied(reason) { store.ready = false; store.helperError = reason }
  }

  Component.onDestruction: store.flush()
}
