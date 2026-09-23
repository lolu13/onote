// One open note = one ordinary toplevel window that Hyprland tiles.
// Closing the window (Super+W or Ctrl+W) saves the note to the stack; it is
// never deleted from here.
import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import "Themes.js" as Themes
import "NoteLayout.js" as NoteLayout

FloatingWindow {
  id: win

  required property string noteId
  property var store: null
  property var service: null
  property var windows: null

  property var note: null
  readonly property string localTitle: options.displayTitle
  NoteOptions {
    id: options
    store: win.store
    noteId: win.noteId
    tabId: win.tabIdAt(win.activeTab)
    onTitlePending: titleTimer.restart()
  }
  Timer { id: titleTimer; interval: 400; onTriggered: options.flushTitle() }
  // A reload or unload before the timer fires must not lose the title.
  Component.onDestruction: options.flushTitle()
  property string themeName: "system"
  // Notes follow the Omarchy font size ([font] base-size) unless the note or
  // the "text size for new notes" setting says otherwise.
  property int fontSize: Style.font.body
  property bool closing: false
  readonly property string fontFamily: Style.font.family

  // The tag lets Hyprland rules and dispatchers target this one window; every
  // Quickshell window shares the class org.quickshell.
  readonly property string tag: windows ? windows.tag(noteId) : "[dn:" + noteId.replace(/-/g, "").slice(0, 12) + "]"
  // A tab without a title of its own still names the window after the note.
  title: (localTitle.length ? localTitle : (options.note && options.note.title ? options.note.title : "Untitled")) + " — Onote " + tag
  minimumSize: Qt.size(320, 240)
  implicitWidth: note ? Math.max(320, Math.round(note.width)) : 320
  implicitHeight: note ? Math.max(240, Math.round(note.height)) : 350
  color: win.themePalette.background
  visible: true

  // Hyprland owns placement. Mirror where the note actually is so it reopens
  // there; the list is empty until the shell's Hyprland IPC is connected.
  // Only a shell window whose title ends in this note's suffix: the tag is
  // visible in the title bar, so a terminal or browser showing it, or another
  // note titled with it, must not lend the note its workspace or geometry.
  readonly property var hlTop: {
    var v = Hyprland.toplevels.values
    for (var i = 0; i < v.length; i++) {
      var info = v[i].lastIpcObject
      if (win.titleMatches(v[i].title) && info && info["class"] === "org.quickshell") return v[i]
    }
    return null
  }
  function titleMatches(t) {
    if (windows) return windows.titleMatches(t, noteId)
    var s = " — Onote " + win.tag; t = String(t || "")
    return t.length >= s.length && t.slice(t.length - s.length) === s
  }
  readonly property var hlWs: hlTop ? hlTop.workspace : null
  readonly property int liveWs: hlWs ? hlWs.id : 0
  readonly property string liveWsName: hlWs ? hlWs.name : ""
  onLiveWsChanged: win.rememberWorkspace()
  onLiveWsNameChanged: win.rememberWorkspace()

  // False when the workspace rule could not be registered (hyprctl failed
  // twice): the window opened where the focus was, not where the note
  // lives, and that placement is not remembered, nor is the pin it lost,
  // until the user places the note on purpose: moves it to another
  // workspace, or pins it (an unpin after that is a choice, and is kept).
  property bool placedByRule: true
  property int _fallbackWs: 0
  property bool _placedSince: false
  function _fallbackHolds() {
    if (win.placedByRule || win._placedSince) return false
    if (!win._fallbackWs) { win._fallbackWs = win.liveWs; return true }
    if (win.liveWs === win._fallbackWs) return true
    win._placedSince = true
    return false
  }

  // Pin state and floating geometry come from the same `hyprctl clients`
  // record. A pinned window's workspace follows the user, so workspace memory
  // pauses while pinned; a slow tick catches drags, which send no event.
  readonly property var hlInfo: hlTop ? hlTop.lastIpcObject : null
  readonly property bool livePinned: hlInfo ? hlInfo.pinned === true : false
  onHlInfoChanged: win.rememberGeometry()
  Timer { interval: 3000; repeat: true; running: win.livePinned; onTriggered: Hyprland.refreshToplevels() }

  function rememberGeometry() {
    if (!win.hlInfo || win.closing || !win.store) return
    var cur = win.store.noteById(win.noteId)
    if (!cur) return
    var patch = ({}), changed = false
    var pinned = win.hlInfo.pinned === true
    if (pinned) win._placedSince = true
    var lostPin = cur.pinned === true && !pinned && !win.placedByRule && !win._placedSince   // opened unpinned for want of its rule
    if ((cur.pinned === true) !== pinned && !lostPin) { patch.pinned = pinned; changed = true }
    var at = win.hlInfo.at, size = win.hlInfo.size
    if (pinned && at && size && at.length === 2 && size.length === 2) {
      // `at` is compositor-global; the position is kept relative to the
      // window's monitor, which is what the reopening rule's `move` takes
      // (Hyprland adds the monitor's own offset), so a note pinned on a
      // second monitor comes back on the monitor it opens on, not off-screen.
      var mon = win.hlTop ? win.hlTop.monitor : null
      var x = at[0] - (mon ? mon.x : 0), y = at[1] - (mon ? mon.y : 0)
      if (Math.round(cur.positionX) !== x || Math.round(cur.positionY) !== y
          || Math.round(cur.width) !== size[0] || Math.round(cur.height) !== size[1]) {
        patch.positionX = x; patch.positionY = y; patch.width = size[0]; patch.height = size[1]
        changed = true
      }
    }
    if (changed) win.store.updateNote(win.noteId, patch)
    if (!pinned) win.rememberWorkspace()
  }

  // A tiled note is half a screen; a pinned sticky gets the default note size.
  // A note that already floats keeps whatever size the user gave it.
  function togglePin() {
    if (!win.windows) return
    var floating = win.hlInfo && win.hlInfo.floating === true
    var w = floating ? win.width : Number(win.store ? win.store.getSetting("defaultNoteWidth", 300) : 300)
    var h = floating ? win.height : Number(win.store ? win.store.getSetting("defaultNoteHeight", 350) : 350)
    win.windows.setPinned(win.noteId, !win.livePinned, w, h)
  }
  // Focusing at the instant Hyprland announces the window is too early for a
  // window that opened silently on another workspace; give it a beat.
  onHlTopChanged: if (win.hlTop && win.windows && win.windows.follow[win.noteId]) followTimer.restart()
  Timer {
    id: followTimer
    interval: 200
    onTriggered: {
      if (!win.windows || win.closing) return
      win.windows.focusNote(win.noteId)
      win.windows.didFollow(win.noteId)
    }
  }

  function rememberWorkspace() {
    if (!win.liveWs || win.livePinned || win.closing || !win.store) return
    if (win._fallbackHolds()) return
    var cur = win.store.noteById(win.noteId)
    if (!cur || (cur.workspaceId === win.liveWs && cur.workspaceName === win.liveWsName)) return
    win.store.updateNote(win.noteId, { workspaceId: win.liveWs, workspaceName: win.liveWsName })
  }

  NotePalette {
    id: palette
    themeName: win.themeName
    customThemes: win.store ? win.store.customThemes : []
  }
  // Delegates and text items carry their own Qt `palette`; reach ours by name.
  readonly property var themePalette: palette

  Component.onCompleted: {
    console.log("onote: NoteWindow created for", win.noteId)
    win.note = win.store ? win.store.noteById(win.noteId) : null
    if (win.note) {
      win.themeName = win.note.themeName || "system"
      win.fontSize = win.note.fontSize || Style.font.body
      win.extraTabs = win.store.tabsFor(win.noteId)
      // At shell start, and during a resync (Restore All), windows exist
      // before tabs and settings have arrived; then the saved tab is applied
      // on the store's resync instead.
      var settled = win.store.ready && !win.store.syncing
      var saved = settled ? options.savedTab(win.extraTabs) : 0
      win._tabRestored = settled
      win.activeTab = saved
      editor.tabId = win.tabIdAt(saved)
      editor.load(win.tabContent(saved))
    } else {
      editor.load("[]")
    }
    // Quick capture: start typing the note itself. Up from the first line, or
    // a click, reaches the title.
    Qt.callLater(function() { editor.focusBlock(0, true) })
  }

  function saveAll() {
    options.flushTitle()
    editor.flush()
    if (win.store) win.store.updateNote(win.noteId, { width: win.width, height: win.height })
  }

  // `later`: the compositor closed the window, which is also how Omarchy's
  // shutdown, reboot and logout begin, so the stack write waits (see
  // NotesStore.stackNoteLater) and an interrupted session reopens the note.
  // Otherwise a refused stack (helper restarting, database locked) undoes
  // the close: the note is still open on disk and in the cache, so its
  // window comes back with the reason, instead of staying hidden behind an
  // "open" entry the Library cannot focus. Re-shown later: the refusal can
  // arrive inside the visibility handler itself.
  function closeToStack(later) {
    if (win.closing) return
    win.closing = true
    saveAll()
    if (!win.store) return
    if (later === true) { win.store.stackNoteLater(win.noteId); return }
    win.store.stackNote(win.noteId, function(err) {
      if (!err) return
      win.closing = false
      editor.notice = "Not hidden: " + err
      Qt.callLater(function() { if (!win.closing) win.visible = true })
    })
  }

  onVisibleChanged: if (!visible) closeToStack(true)
  onClosed: closeToStack(true)

  function setFontSize(n) {
    n = Math.max(10, Math.min(40, n))
    if (n === win.fontSize) return
    win.fontSize = n
    if (win.store) win.store.updateNote(win.noteId, { fontSize: n })
  }

  function cycleTheme(delta) {
    var names = Themes.allNames(win.store ? win.store.customThemes : [])
    var i = names.indexOf(win.themeName)
    var next = names[(i + delta + names.length) % names.length]
    win.themeName = next
    if (win.store) win.store.updateNote(win.noteId, { themeName: next })
  }

  // ---- tabs. Tab 1 is the note itself; extra tabs live in store.tabs[noteId].
  property int activeTab: 0
  property var extraTabs: []
  readonly property int tabCount: 1 + extraTabs.length
  property bool confirmClose: false
  property bool renameOpen: false
  property string renameTabId: ""
  function openRename() {
    win.renameTabId = options.tabId
    renameField.text = options.tabLabel(win.renameTabId)
    win.renameOpen = true
    Qt.callLater(function() { renameField.forceActiveFocus(); renameField.selectAll() })
  }
  property bool pickerOpen: false
  property int pickerIndex: 0
  property int pickerTab: 0
  // Nerd Font glyphs (Font Awesome range), the icon set Omarchy's shell draws with.
  readonly property var tabIcons: ["\uf005", "\uf00c", "\uf015", "\uf02d", "\uf073", "\uf0c0", "\uf0e7", "\uf0eb",
                                   "\uf0f3", "\uf121", "\uf188", "\uf024", "\uf004", "\uf07a", "\uf0b1", "\uf0ac",
                                   "\uf0c1", "\uf0e0", "\uf017", "\uf0ad", "\uf06c", "\uf0f4", "\uf0d0", "\uf07b",
                                   "\uf15c", "\uf086", "\uf1c0", "\uf001", "\uf030", "\uf040", "\uf095", "\uf072",
                                   "\uf0d6", "\uf06b", "\uf091", "\uf02b", "\uf03a", "\uf08d", "\uf0e4", "\uf19c"]

  Connections {
    target: win.store
    function onNoteStacked(id) { if (id === win.noteId) { options.flushTitle(); editor.flush() } }
    function onNoteTabsChanged(id) { if (id === win.noteId) win.refreshTabs() }
    function onResynced() { win.refreshTabs(); win.restoreTab() }
  }

  // Once per window: the remembered tab, applied as soon as tabs and settings
  // are both known (a forced switch, so nothing is written back).
  property bool _tabRestored: false
  function restoreTab() {
    if (win._tabRestored) return
    win._tabRestored = true
    var saved = options.savedTab(win.extraTabs)
    if (saved > 0) win.switchTab(saved, true)
  }

  // The editor's tab decides the active index: a tab removed before it shifts
  // the others, and one that is gone yields to the tab before it.
  function refreshTabs() {
    win.extraTabs = win.store ? win.store.tabsFor(win.noteId) : []
    for (var i = 0; i < win.tabCount; i++) {
      if (win.tabIdAt(i) !== editor.tabId) continue
      win.activeTab = i
      return
    }
    // The tab shown is gone: the preceding one is shown. Deleted (here, or
    // elsewhere and resynced), it is remembered too, since the saved id
    // names a tab that no longer exists and would reopen the note on tab 1.
    // Not when the note is being stacked: its tabs leave the cache, not the
    // database, while this window still lives, and the saved tab must stay.
    var repaired = Math.max(0, Math.min(win.activeTab - 1, win.tabCount - 1))
    win.switchTab(repaired, true)
    var cur = win.store ? win.store.noteById(win.noteId) : null
    if (!win.closing && cur && cur.piled !== true) options.rememberTab(win.tabIdAt(repaired))
  }

  // "" for tab 1 (the note itself), the tab row's id for the others.
  function tabIdAt(i) {
    var t = i > 0 ? win.extraTabs[i - 1] : null
    return t ? t.id : ""
  }

  function tabIcon(i) {
    if (i === 0) { var n = win.store ? win.store.noteById(win.noteId) : null; return n ? (n.tabIcon || "") : "" }
    var t = win.extraTabs[i - 1]
    return t ? (t.icon || "") : ""
  }

  function tabContent(i) {
    if (i === 0) { var n = win.store ? win.store.noteById(win.noteId) : null; return n ? n.contentBlocks : "[]" }
    var t = win.extraTabs[i - 1]
    return t ? t.contentBlocks : "[]"
  }

  function switchTabBy(delta) { win.switchTab((win.activeTab + delta + win.tabCount) % win.tabCount) }

  function switchTab(i, force) {
    i = Math.max(0, Math.min(win.tabCount - 1, i))
    if (i === win.activeTab && !force) return
    options.flushTitle()
    editor.flush()
    win.activeTab = i
    if (!force) options.rememberTab(win.tabIdAt(i))   // forced switches restore or repair, they are not a choice
    editor.tabId = win.tabIdAt(i)
    editor.load(win.tabContent(i))
    Qt.callLater(function() { editor.focusBlock(0, true) })
  }

  function newTab() {
    if (!win.store) return
    editor.flush()
    win.store.createTab(win.noteId, function(err, tab) {
      if (err || !tab) return
      win.switchTab(tab.position)
    })
  }

  // Browser rule: closing the last tab closes the note (to the stack).
  function closeTab() {
    if (win.tabCount === 1) { win.closeToStack(); return }
    if (win.activeTab === 0) return            // tab 1 is the note; use Ctrl+W on another tab
    if (editor.isEmpty() && !options.tabHasText(win.extraTabs[win.activeTab - 1].id)) { win.deleteActiveTab(); return }
    win.confirmClose = true
    overlayKeys.forceActiveFocus()
  }

  function deleteActiveTab() {
    win.confirmClose = false
    if (win.activeTab === 0 || !win.store) return
    var doomed = win.extraTabs[win.activeTab - 1]
    // A title still in its 400 ms debounce goes first: written before the
    // helper purges the tab's settings (requests are ordered), so the forced
    // tab switch after the deletion has nothing left to flush and cannot
    // recreate the title as an orphan setting; a refusal keeps the title.
    options.flushTitle()
    // Once the helper has deleted it the store's tab change reaches
    // refreshTabs, which moves the editor off the deleted tab (a flush into
    // it is refused by the store). A refusal leaves the tab, with its edits.
    win.store.deleteTab(doomed.id, function(err) {
      if (err && editor.tabId === doomed.id) editor.notice = "Tab not closed: " + err
    })
  }

  function openPicker(tabIndex) {
    win.pickerTab = tabIndex
    var cur = win.tabIcon(tabIndex)
    var at = win.tabIcons.indexOf(cur)
    win.pickerIndex = at < 0 ? 0 : at
    win.pickerOpen = true
    overlayKeys.forceActiveFocus()
  }

  function setTabIcon(tabIndex, glyph) {
    if (!win.store) return
    if (tabIndex === 0) win.store.updateNote(win.noteId, { tabIcon: glyph })
    else if (win.extraTabs[tabIndex - 1]) win.store.updateTab(win.extraTabs[tabIndex - 1].id, { icon: glyph })
    win.extraTabsChanged()                    // tab 1's icon lives on the note; repaint the bar
  }

  function closeOverlay() {
    win.renameOpen = false
    win.pickerOpen = false
    win.confirmClose = false
    win.focusBody()
  }

  function openLibrary() {
    if (win.service && typeof win.service.toggleLibrary === "function") win.service.toggleLibrary()
  }

  readonly property bool modalOpen: win.renameOpen || win.confirmClose || win.pickerOpen || commandMenu.visible
  function focusBody() { editor.focusBlock(Math.max(0, editor.focusedIndex), true) }
  function focusSection(delta) {
    var controls = [titleField, titleLock, layoutButton, tabBar, editor]
    var current = controls.findIndex(function(c) { return c.activeFocus })
    if (current < 0) current = controls.indexOf(editor)
    var next = controls[(current + delta + controls.length) % controls.length]
    if (next === editor) win.focusBody(); else next.forceActiveFocus()
  }
  function toolbarKey(event) {
    if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) win.focusSection(-1)
    else if (event.key === Qt.Key_Tab) win.focusSection(1)
    else if (event.key === Qt.Key_Escape) win.focusBody()
    else return false
    event.accepted = true; return true
  }
  function switchFromBar(delta) {
    win.switchTabBy(delta)
    Qt.callLater(function() { tabBar.forceActiveFocus() })
  }
  function runCommand(action) {
    win.focusBody()
    switch (action) {
    case "title": titleField.forceActiveFocus(); titleField.selectAll(); break
    case "lock": options.toggleTitleLock(); break
    case "layout": options.cycleColumns(); break
    case "newTab": win.newTab(); break
    case "closeTab": win.closeTab(); break
    case "nextTab": win.switchTabBy(1); break
    case "previousTab": win.switchTabBy(-1); break
    case "rename": win.openRename(); break
    case "icon": win.openPicker(win.activeTab); break
    case "newNote": if (win.service) win.service.newNote(); break
    case "clipboard": if (win.service) win.service.newNoteFromClipboard(); break
    case "hide": win.closeToStack(); break
    case "hideAll": if (win.windows) win.windows.hideAll(); break
    case "pin": win.togglePin(); break
    case "library": win.saveAll(); win.openLibrary(); break
    case "settings": win.saveAll(); if (win.service) win.service.openSettings(); break
    case "save": win.saveAll(); break
    case "copy": win.saveAll(); if (win.store) win.store.settled(win.noteId, function(e) { if (e) editor.notice = "Not copied: " + e; else win.store.copyMarkdown(win.noteId, function(err) { if (err) editor.notice = "Not copied: " + err }) }); break
    case "export": win.saveAll(); if (win.store) win.store.settled(win.noteId, function(e) { if (e) editor.notice = "Not exported: " + e; else win.store.exportNote(win.noteId, function(err) { if (err) editor.notice = "Not exported: " + err }) }); break
    case "theme": win.cycleTheme(1); break
    case "bigger": win.setFontSize(win.fontSize + 1); break
    case "smaller": win.setFontSize(win.fontSize - 1); break
    case "todo": editor.toggleTodo(editor.focusedIndex); break
    case "labelColor": editor.cycleLabelColor(editor.focusedIndex); break
    case "labelName": editor.focusLabel(); break
    case "moveUp": editor.moveBlock(editor.focusedIndex, -1); break
    case "moveDown": editor.moveBlock(editor.focusedIndex, 1); break
    case "first": editor.focusBlock(0, false); break
    case "last": editor.focusBlock(editor.count - 1, true); break
    case "columnLeft": editor.focusColumn(-1); break
    case "columnRight": editor.focusColumn(1); break
    }
  }

  CommandMenu {
    id: commandMenu
    anchors.fill: parent
    palette: win.themePalette; fontFamily: win.fontFamily; fontSize: win.fontSize
    onDismissed: win.focusBody()
    onTriggered: function(action) { win.runCommand(action) }
    commands: [
      {id:"title", label:"Edit title", keys:"Ctrl+L"},
      {id:"lock", label:options.titleLocked ? "Unlock title" : "Lock title"},
      {id:"layout", label:"Cycle 1 / 2 / 3 columns", keys:"Ctrl+J / Ctrl+Shift+J"},
      {id:"rename", label:"Rename tab", keys:"F2"},
      {id:"icon", label:"Choose tab icon", keys:"Ctrl+Shift+I"},
      {id:"newTab", label:"New tab", keys:"Ctrl+T"},
      {id:"closeTab", label:"Close tab", keys:"Ctrl+W"},
      {id:"nextTab", label:"Next tab", keys:"Ctrl+Tab"},
      {id:"previousTab", label:"Previous tab", keys:"Ctrl+Shift+Tab"},
      {id:"newNote", label:"New note", keys:"Ctrl+N"},
      {id:"clipboard", label:"New note from clipboard", keys:"Super+Alt+V"},
      {id:"hide", label:"Hide focused note", keys:"Super+Alt+H"},
      {id:"hideAll", label:"Hide all notes", keys:"Super+Alt+Shift+H"},
      {id:"pin", label:"Pin / unpin note", keys:"Ctrl+Shift+P"},
      {id:"library", label:"Open notes library / delete notes", keys:"Ctrl+Shift+F"},
      {id:"settings", label:"Settings", keys:"Ctrl+,"},
      {id:"save", label:"Save note", keys:"Ctrl+S"},
      {id:"copy", label:"Copy note as Markdown"},
      {id:"export", label:"Export note as Markdown"},
      {id:"theme", label:"Next theme", keys:"Ctrl+Shift+T"},
      {id:"bigger", label:"Larger text", keys:"Ctrl++"},
      {id:"smaller", label:"Smaller text", keys:"Ctrl+-"},
      {id:"todo", label:"Toggle to-do block", keys:"Ctrl+Enter"},
      {id:"labelColor", label:"Next label color", keys:"Ctrl+Shift+L"},
      {id:"labelName", label:"Edit label badge name", keys:"Shift+Tab from value"},
      {id:"moveUp", label:"Move block up", keys:"Alt+Up"},
      {id:"moveDown", label:"Move block down", keys:"Alt+Down"},
      {id:"first", label:"First block", keys:"Ctrl+Home"},
      {id:"last", label:"Last block", keys:"Ctrl+End"},
      {id:"columnLeft", label:"Focus left column", keys:"Alt+Left"},
      {id:"columnRight", label:"Focus right column", keys:"Alt+Right"}
    ]
  }

  FocusScope {
    id: scope
    anchors.fill: parent
    anchors.margins: 2
    focus: true

    // Window shortcuts run before a child text field can consume Tab or arrows.
    // A key listed here never reaches Keys.onPressed below; keep each key in one place.
    Shortcut { sequences: ["Ctrl+K", "F1"]; enabled: !win.modalOpen || commandMenu.visible
               onActivated: commandMenu.visible ? commandMenu.cancel() : commandMenu.open() }
    Shortcut { sequence: "F6"; enabled: !win.modalOpen; onActivated: win.focusSection(1) }
    Shortcut { sequence: "Shift+F6"; enabled: !win.modalOpen; onActivated: win.focusSection(-1) }
    Shortcut { sequence: "Ctrl+L"; enabled: !win.modalOpen; onActivated: win.runCommand("title") }
    Shortcut { sequence: "Ctrl+J"; enabled: !win.modalOpen; onActivated: options.cycleColumns(1) }
    Shortcut { sequence: "Ctrl+Shift+J"; enabled: !win.modalOpen; onActivated: options.cycleColumns(-1) }
    Shortcut { sequences: ["Ctrl+Tab", "Ctrl+PgDown"]; enabled: !win.modalOpen; onActivated: win.switchTabBy(1) }
    Shortcut { sequences: ["Ctrl+Shift+Tab", "Ctrl+PgUp"]; enabled: !win.modalOpen; onActivated: win.switchTabBy(-1) }
    Shortcut { sequence: "Ctrl+W"; enabled: !win.modalOpen; autoRepeat: false; onActivated: win.closeTab() }
    Shortcut { sequence: "Ctrl+T"; enabled: !win.modalOpen; autoRepeat: false; onActivated: win.newTab() }
    Shortcut { sequence: "Ctrl+Shift+I"; enabled: !win.modalOpen; onActivated: win.openPicker(win.activeTab) }
    Shortcut { sequence: "F2"; enabled: !win.modalOpen; onActivated: win.openRename() }
    Shortcut { sequence: "Alt+Up"; enabled: !win.modalOpen && editor.activeFocus; onActivated: editor.moveBlock(editor.focusedIndex, -1) }
    Shortcut { sequence: "Alt+Down"; enabled: !win.modalOpen && editor.activeFocus; onActivated: editor.moveBlock(editor.focusedIndex, 1) }
    Shortcut { sequence: "Alt+Left"; enabled: !win.modalOpen && editor.activeFocus; onActivated: editor.focusColumn(-1) }
    Shortcut { sequence: "Alt+Right"; enabled: !win.modalOpen && editor.activeFocus; onActivated: editor.focusColumn(1) }
    Shortcut { sequences: ["Ctrl+Return", "Ctrl+Enter"]; enabled: !win.modalOpen && editor.activeFocus; onActivated: editor.toggleTodo(editor.focusedIndex) }

    Keys.onPressed: function(event) {
      var ctrl = event.modifiers & Qt.ControlModifier
      var shift = event.modifiers & Qt.ShiftModifier
      if (ctrl && !shift && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) { win.switchTab(event.key - Qt.Key_1); event.accepted = true; return }
      if (ctrl && event.key === Qt.Key_Comma) { win.saveAll(); if (win.service) win.service.openSettings(); event.accepted = true; return }
      if (ctrl && !shift && event.key === Qt.Key_S) { win.saveAll(); event.accepted = true; return }
      if (ctrl && !shift && event.key === Qt.Key_N) { if (win.store) win.store.createNote(); event.accepted = true; return }
      if (ctrl && shift && event.key === Qt.Key_F) { win.saveAll(); win.openLibrary(); event.accepted = true; return }
      if (ctrl && shift && event.key === Qt.Key_T) { win.cycleTheme(1); event.accepted = true; return }
      if (ctrl && shift && event.key === Qt.Key_P) { win.togglePin(); event.accepted = true; return }
      if (ctrl && shift && event.key === Qt.Key_L) { editor.cycleLabelColor(editor.focusedIndex); event.accepted = true; return }
      if (ctrl && (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal)) { win.setFontSize(win.fontSize + 1); event.accepted = true; return }
      if (ctrl && (event.key === Qt.Key_Minus || event.key === Qt.Key_Underscore)) { win.setFontSize(win.fontSize - 1); event.accepted = true; return }
    }

    Column {
      anchors.fill: parent
      anchors.margins: Math.round(win.fontSize * 0.8)
      spacing: Math.round(win.fontSize * 0.5)

      Row {
        id: titleBar
        width: parent.width
        height: Math.round(win.fontSize * 1.8)
        spacing: 8
        // Full-label widths, measured whichever labels are showing.
        TextMetrics { id: lockFull; font: lockLabel.font; text: options.titleLocked ? "\uf023 Locked" : "\uf09c Lock" }
        TextMetrics { id: columnsFull; font: layoutLabel.font; text: options.columns + (options.columns === 1 ? " column" : " columns") }
        readonly property bool compact: NoteLayout.toolbarCompact(width, lockFull.advanceWidth + 16, columnsFull.advanceWidth + 16, spacing, 40)
        TextInput {
          id: titleField
          width: Math.max(40, parent.width - titleLock.width - layoutButton.width - parent.spacing * 2)
          height: parent.height
          verticalAlignment: TextInput.AlignVCenter
          readOnly: options.titleLocked
          text: win.localTitle
          font.family: win.fontFamily
          font.pixelSize: Math.round(win.fontSize * 1.2)
          font.bold: true
          color: win.themePalette.accentPrimary
          selectionColor: win.themePalette.selection
          selectedTextColor: win.themePalette.foreground
          selectByMouse: true
          clip: true
          activeFocusOnTab: false
          // The title becomes the window title and the mirror file name.
          maximumLength: 200

          Text {
            textFormat: Text.PlainText
            anchors.fill: parent
            visible: !titleField.text.length && !titleField.activeFocus
            text: "Untitled"
            font: titleField.font
            color: win.themePalette.comment
          }

          onTextEdited: options.editTitle(text)
          Keys.onPressed: function(event) {
            if (win.toolbarKey(event)) return
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Down) {
              editor.focusBlock(0, event.key === Qt.Key_Down ? false : true)
              event.accepted = true
            }
          }
        }
        Rectangle {
          id: titleLock
          border.width: activeFocus ? 2 : 0; border.color: win.themePalette.foreground
          Keys.onPressed: function(event) {
            if (win.toolbarKey(event)) return
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { options.toggleTitleLock(); event.accepted = true }
          }
          width: lockLabel.implicitWidth + 16; height: parent.height
          color: options.titleLocked ? win.themePalette.accentPrimary : win.themePalette.currentLine
          Text {
            id: lockLabel; anchors.centerIn: parent
            text: titleBar.compact ? (options.titleLocked ? "\uf023" : "\uf09c") : lockFull.text
            font.family: win.fontFamily; font.pixelSize: Math.round(win.fontSize * 0.85)
            color: options.titleLocked ? win.themePalette.background : win.themePalette.foreground
          }
          MouseArea { anchors.fill: parent; onClicked: options.toggleTitleLock() }
        }
        Rectangle {
          id: layoutButton
          border.width: activeFocus ? 2 : 0; border.color: win.themePalette.accentPrimary
          Keys.onPressed: function(event) {
            if (win.toolbarKey(event)) return
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { options.cycleColumns(); event.accepted = true }
          }
          width: layoutLabel.implicitWidth + 16; height: parent.height
          color: win.themePalette.currentLine
          Text {
            id: layoutLabel; anchors.centerIn: parent
            text: titleBar.compact ? "\uf0db " + options.columns : columnsFull.text
            font.family: win.fontFamily; font.pixelSize: Math.round(win.fontSize * 0.85)
            color: win.themePalette.foreground
          }
          MouseArea { anchors.fill: parent; onClicked: options.cycleColumns() }
        }
      }

      // Tab bar: "1  2  +". Every box is the same size, the label is body-sized
      // whether it is a number or a glyph; the active box is filled with the
      // accent, the others are plain text, and "+" sits in a muted box.
      Row {
        id: tabBar
        Keys.onPressed: function(event) {
          if (win.toolbarKey(event)) return
          if (event.key === Qt.Key_Left) win.switchFromBar(-1)
          else if (event.key === Qt.Key_Right) win.switchFromBar(1)
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Down) win.focusBody()
          else return
          event.accepted = true
        }
        width: parent.width
        height: Math.round(win.fontSize * 1.6)
        spacing: Math.round(win.fontSize * 0.4)
        readonly property int boxWidth: Math.round(win.fontSize * 5)

        Repeater {
          model: win.tabCount
          delegate: Rectangle {
            required property int index
            readonly property bool active: index === win.activeTab
            readonly property string glyph: win.tabIcon(index)
            width: Math.max(35, Math.min(win.fontSize * 14, (tabBar.width - tabBar.boxWidth - tabBar.spacing * win.tabCount) / win.tabCount))
            height: tabBar.height
            radius: 0
            border.width: tabBar.activeFocus && active ? 2 : 0
            border.color: win.themePalette.foreground
            color: active ? win.themePalette.accentPrimary : (tabHover.containsMouse ? win.themePalette.currentLine : "transparent")
            Text {
              textFormat: Text.PlainText
              id: tabLabel
              anchors.centerIn: parent
              width: parent.width - 12
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: (parent.glyph.length ? parent.glyph + " " : "") + (options.tabLabel(win.tabIdAt(parent.index)) || String(parent.index + 1))
              font.family: win.fontFamily
              font.pixelSize: win.fontSize
              color: parent.active ? win.themePalette.background : win.themePalette.foreground
            }
            MouseArea {
              id: tabHover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onDoubleClicked: function(mouse) {
                if (mouse.button === Qt.LeftButton) { win.switchTab(parent.index); win.openRename() }
              }
              onClicked: function(mouse) {
                if (mouse.button === Qt.RightButton) { win.switchTab(parent.index); win.openPicker(parent.index) }
                else win.switchTab(parent.index)
              }
            }
          }
        }
        Rectangle {
          width: tabBar.boxWidth
          height: tabBar.height
          radius: 0
          color: win.themePalette.currentLine
          opacity: plusHover.containsMouse ? 1 : 0.7
          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "+"
            font.family: win.fontFamily
            font.pixelSize: win.fontSize
            color: win.themePalette.foreground
          }
          MouseArea { id: plusHover; anchors.fill: parent; hoverEnabled: true; onClicked: win.newTab() }
        }
      }

      Rectangle { width: parent.width; height: 1; color: win.themePalette.currentLine }

      BlockEditor {
        id: editor
        width: parent.width
        onLeaveTop: { titleField.forceActiveFocus(); titleField.cursorPosition = titleField.text.length }
        height: NoteLayout.editorHeight(parent.height, titleBar.height + tabBar.height + 1, keyboardHint.implicitHeight, keyboardHint.visible, parent.spacing)
        columns: options.columns
        store: win.store
        noteId: win.noteId
        palette: win.themePalette
        fontSize: win.fontSize
        fontFamily: win.fontFamily
        saveInterval: win.store ? parseInt(win.store.getSetting("autoSaveInterval", "500")) || 500 : 500
      }
      Text {
        id: keyboardHint
        width: parent.width
        visible: NoteLayout.hintShown(parent.height, titleBar.height + tabBar.height + 1, implicitHeight, parent.spacing, win.fontSize, editor.notice.length > 0)
        // A save the editor had to refuse takes the hint's place until it is fixed.
        text: editor.notice.length ? editor.notice : "Ctrl+K commands · F6 controls · Ctrl+Tab tabs · F2 rename"
        elide: Text.ElideRight
        font.family: win.fontFamily; font.pixelSize: Math.round(win.fontSize * 0.85)
        color: editor.notice.length ? Color.urgent : win.themePalette.comment
        MouseArea { anchors.fill: parent; onClicked: commandMenu.open() }
      }
    }
  }

  // Keyboard focus while the close-confirm strip or the icon picker is open.
  Item {
    id: overlayKeys
    anchors.fill: parent
    visible: win.confirmClose || win.pickerOpen || win.renameOpen
    Keys.onPressed: function(event) {
      event.accepted = true
      if (event.key === Qt.Key_Escape) { win.closeOverlay(); return }
      if (win.renameOpen) return
      if (win.confirmClose) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) win.deleteActiveTab()
        else win.closeOverlay()
        return
      }
      var cols = 8, n = win.tabIcons.length
      if (event.key === Qt.Key_Right) win.pickerIndex = (win.pickerIndex + 1) % n
      else if (event.key === Qt.Key_Left) win.pickerIndex = (win.pickerIndex + n - 1) % n
      else if (event.key === Qt.Key_Down) win.pickerIndex = Math.min(n - 1, win.pickerIndex + cols)
      else if (event.key === Qt.Key_Up) win.pickerIndex = Math.max(0, win.pickerIndex - cols)
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { win.setTabIcon(win.pickerTab, win.tabIcons[win.pickerIndex]); win.closeOverlay() }
      else if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) { win.setTabIcon(win.pickerTab, ""); win.closeOverlay() }
    }

    Rectangle {
      visible: win.renameOpen
      anchors.fill: parent
      color: "#66000000"
      MouseArea { anchors.fill: parent; onClicked: win.closeOverlay() }
      Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - 32, win.fontSize * 32)
        height: renameContents.height + 24
        color: win.themePalette.background
        border.color: win.themePalette.accentPrimary; border.width: 1
        MouseArea { anchors.fill: parent }
        Column {
          id: renameContents
          anchors.centerIn: parent
          width: parent.width - 24
          spacing: 12
          Text {
            text: "Rename tab"; color: win.themePalette.accentPrimary
            font.family: win.fontFamily; font.pixelSize: win.fontSize; font.bold: true
          }
          Rectangle {
            width: parent.width; height: win.fontSize * 2.4
            color: win.themePalette.currentLine
            TextInput {
              id: renameField
              anchors.fill: parent; anchors.margins: 6
              font.family: win.fontFamily; font.pixelSize: win.fontSize
              color: win.themePalette.foreground
              selectionColor: win.themePalette.selection
              selectByMouse: true; maximumLength: 80; clip: true
              Keys.onPressed: function(event) {
                event.accepted = false
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  options.renameTab(win.renameTabId, text)
                  win.closeOverlay(); event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  win.closeOverlay(); event.accepted = true
                }
              }
            }
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap
            text: "Enter saves · Esc cancels · Empty restores the number"
            color: win.themePalette.comment
            font.family: win.fontFamily; font.pixelSize: Math.round(win.fontSize * 0.85)
          }
        }
      }
    }

    // "Close tab 2 and its text?" strip over the tab bar.
    Rectangle {
      visible: win.confirmClose
      x: Math.round(win.fontSize * 0.8); y: x + titleField.height + Math.round(win.fontSize * 0.5)
      width: parent.width - x * 2; height: Math.round(win.fontSize * 1.5)
      color: win.themePalette.accentPrimary
      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: "Close tab " + (win.activeTab + 1) + " and its text?   Enter: close   Esc: keep"
        font.family: win.fontFamily; font.pixelSize: Math.round(win.fontSize * 0.9); font.bold: true
        color: win.themePalette.background
        elide: Text.ElideRight; width: parent.width - win.fontSize
        horizontalAlignment: Text.AlignHCenter
      }
    }

    // Icon picker for one tab: arrows to move, Enter to pick, Backspace for the number, Esc.
    Rectangle {
      visible: win.pickerOpen
      anchors.centerIn: parent
      width: Math.min(parent.width - win.fontSize, iconGrid.width + win.fontSize)
      height: iconGrid.height + pickerHint.height + win.fontSize * 1.5
      color: win.themePalette.background
      border.width: 1; border.color: win.themePalette.accentPrimary
      radius: 0
      MouseArea { anchors.fill: parent }           // swallow clicks behind the grid
      Column {
        anchors.centerIn: parent
        spacing: Math.round(win.fontSize * 0.4)
        Grid {
          id: iconGrid
          columns: 8
          spacing: Math.round(win.fontSize * 0.2)
          Repeater {
            model: win.tabIcons
            delegate: Rectangle {
              required property int index
              required property string modelData
              width: Math.round(win.fontSize * 2); height: width
              radius: 0
              color: index === win.pickerIndex ? win.themePalette.accentPrimary : (cellHover.containsMouse ? win.themePalette.currentLine : "transparent")
              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: parent.modelData
                font.family: win.fontFamily; font.pixelSize: Math.round(win.fontSize * 1.1)
                color: parent.index === win.pickerIndex ? win.themePalette.background : win.themePalette.foreground
              }
              MouseArea {
                id: cellHover
                anchors.fill: parent; hoverEnabled: true
                onClicked: { win.setTabIcon(win.pickerTab, parent.modelData); win.closeOverlay() }
              }
            }
          }
        }
        Text {
          textFormat: Text.PlainText
          id: pickerHint
          width: iconGrid.width
          text: "Tab " + (win.pickerTab + 1) + ": Enter picks · Backspace shows the number · Esc"
          font.family: win.fontFamily; font.pixelSize: Math.round(win.fontSize * 0.8)
          color: win.themePalette.comment
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // A newer Onote is published: red square, bottom-right, click to update.
  UpdateBadge {
    anchors { right: parent.right; bottom: parent.bottom; margins: Math.round(win.fontSize * 0.8) }
    size: Math.round(win.fontSize * 0.9)
    available: !!(win.service && win.service.updateAvailable)
    palette: win.themePalette
    fontFamily: win.fontFamily
    fontSize: Math.round(win.fontSize * 0.85)
    onActivated: if (win.service) win.service.launchUpdate()
  }

  // Static accent frame, square corners. Drawn last so it sits above content.
  Rectangle {
    anchors.fill: parent
    color: "transparent"
    radius: 0
    border.width: 2
    border.color: scope.activeFocus ? win.themePalette.accentPrimary : win.themePalette.currentLine
  }
}
