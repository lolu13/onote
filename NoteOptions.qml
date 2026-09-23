import QtQuick

QtObject {
  id: options
  property var store: null
  property string noteId: ""
  property string tabId: ""
  readonly property string prefix: "note." + noteId + "."
  readonly property var note: store ? store.noteById(noteId) : null
  readonly property bool titleLocked: store ? store.getSetting(prefix + "titleLocked", "false") === "true" : false
  readonly property string displayTitle: titleLocked ? (note ? note.title : "") : tabTitle(tabId)
  readonly property int columns: store ? Math.max(1, Math.min(3, Number(store.getSetting(prefix + "columns." + (tabId || "main"), "1")) || 1)) : 1

  function tabTitle(id) {
    if (_titlePending && (id || "") === _pendingTab) return _pendingText
    var key = prefix + "title." + (id || "main")
    var value = store ? store.settings[key] : undefined
    if (value !== undefined) return String(value)
    return !id && note ? note.title : ""
  }

  // Typing in the title is shown at once but written once: every setSetting
  // re-copies the whole settings map, re-evaluates its bindings in every open
  // window and costs a helper round trip. The window's timer, a tab switch,
  // a lock toggle or a save flush it.
  property bool _titlePending: false
  property string _pendingTab: ""
  property string _pendingText: ""
  signal titlePending()

  function editTitle(text) {
    if (!store || titleLocked) return
    if (_titlePending && _pendingTab !== tabId) flushTitle()
    _pendingTab = tabId; _pendingText = text; _titlePending = true
    titlePending()
  }

  function flushTitle() {
    if (!_titlePending || !store) return
    // Store first, then drop the pending flag: displayTitle never shows the
    // old value in between, so the bound title field is not rewritten twice
    // (which would reset its cursor, selection and undo history).
    store.setSetting(prefix + "title." + (_pendingTab || "main"), _pendingText)
    if (!_pendingTab) store.updateNote(noteId, { title: _pendingText })
    _titlePending = false
  }

  function tabLabel(id) {
    return store ? store.getSetting(prefix + "label." + (id || "main"), "") : ""
  }

  // Text the user wrote for a tab outside its body (a title, pending or
  // saved, or a name): closing such a tab asks first like any other content.
  function tabHasText(id) {
    return String(tabTitle(id)).trim().length > 0 || String(tabLabel(id)).trim().length > 0
  }

  function renameTab(id, text) {
    if (store) store.setSetting(prefix + "label." + (id || "main"), text.trim().slice(0, 80))
  }

  // The tab the window reopens on, like a browser restoring its active tab.
  // Keyed by tab id ("main" for tab 1) so deleting or reordering other tabs
  // cannot make it point elsewhere; a tab that is gone means tab 1.
  function savedTab(extraTabs) {
    var id = store ? String(store.getSetting(prefix + "activeTab", "main")) : "main"
    for (var i = 0; extraTabs && i < extraTabs.length; i++) if (extraTabs[i].id === id) return i + 1
    return 0
  }

  function rememberTab(id) {
    if (store) store.setSetting(prefix + "activeTab", id || "main")
  }

  // Locking shares one title across tabs by writing it to the note itself (the
  // library, mirror and exports read note.title). Tab 1's own title is kept
  // aside under title.main and put back on unlock.
  function toggleTitleLock() {
    if (!store) return
    flushTitle()
    if (titleLocked) {
      store.updateNote(noteId, { title: tabTitle("") })
    } else {
      store.setSetting(prefix + "title.main", tabTitle(""))
      store.updateNote(noteId, { title: displayTitle || (note ? note.title : "") })
    }
    store.setSetting(prefix + "titleLocked", titleLocked ? "false" : "true")
  }

  function cycleColumns(delta) {
    if (store) store.setSetting(prefix + "columns." + (tabId || "main"), String((columns - 1 + (delta || 1) + 3) % 3 + 1))
  }
}
