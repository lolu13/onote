// One open note = one ordinary toplevel window that Hyprland tiles.
// Closing the window (Super+W or Ctrl+W) saves the note to the stack; it is
// never deleted from here.
import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import "Themes.js" as Themes

FloatingWindow {
  id: win

  required property string noteId
  property var store: null
  property var service: null
  property var windows: null

  property var note: null
  property string localTitle: ""
  property string themeName: "system"
  // Notes follow the Omarchy font size ([font] base-size) unless the note or
  // the "text size for new notes" setting says otherwise.
  property int fontSize: Style.font.body
  property bool closing: false
  readonly property string fontFamily: Style.font.family

  // The tag lets Hyprland rules and dispatchers target this one window; every
  // Quickshell window shares the class org.quickshell.
  readonly property string tag: windows ? windows.tag(noteId) : "[dn:" + noteId.replace(/-/g, "").slice(0, 12) + "]"
  title: (localTitle.length ? localTitle : "Untitled") + " — DeskNotes " + tag
  minimumSize: Qt.size(320, 240)
  implicitWidth: note ? Math.max(320, Math.round(note.width)) : 320
  implicitHeight: note ? Math.max(240, Math.round(note.height)) : 350
  color: win.themePalette.background
  visible: true

  // Hyprland owns placement. Mirror where the note actually is so it reopens
  // there; the list is empty until the shell's Hyprland IPC is connected.
  readonly property var hlTop: {
    var v = Hyprland.toplevels.values
    for (var i = 0; i < v.length; i++) if (v[i].title.indexOf(win.tag) !== -1) return v[i]
    return null
  }
  readonly property var hlWs: hlTop ? hlTop.workspace : null
  readonly property int liveWs: hlWs ? hlWs.id : 0
  readonly property string liveWsName: hlWs ? hlWs.name : ""
  onLiveWsChanged: win.rememberWorkspace()
  onLiveWsNameChanged: win.rememberWorkspace()

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
    if ((cur.pinned === true) !== pinned) { patch.pinned = pinned; changed = true }
    var at = win.hlInfo.at, size = win.hlInfo.size
    if (pinned && at && size && at.length === 2 && size.length === 2) {
      if (Math.round(cur.positionX) !== at[0] || Math.round(cur.positionY) !== at[1]
          || Math.round(cur.width) !== size[0] || Math.round(cur.height) !== size[1]) {
        patch.positionX = at[0]; patch.positionY = at[1]; patch.width = size[0]; patch.height = size[1]
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
    console.log("desknotes: NoteWindow created for", win.noteId)
    win.note = win.store ? win.store.noteById(win.noteId) : null
    if (win.note) {
      win.localTitle = win.note.title || ""
      win.themeName = win.note.themeName || "system"
      win.fontSize = win.note.fontSize || Style.font.body
      editor.load(win.note.contentBlocks)
      win.extraTabs = win.store.tabsFor(win.noteId)
    } else {
      editor.load("[]")
    }
    // Quick capture: start typing the note itself. Up from the first line, or
    // a click, reaches the title.
    Qt.callLater(function() { editor.focusBlock(0, true) })
  }

  function saveAll() {
    editor.flush()
    if (win.store) win.store.updateNote(win.noteId, { width: win.width, height: win.height })
  }

  function closeToStack() {
    if (win.closing) return
    win.closing = true
    saveAll()
    if (win.store) win.store.stackNote(win.noteId)
  }

  onVisibleChanged: if (!visible) closeToStack()
  onClosed: closeToStack()

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
    function onNoteTabsChanged(id) { if (id === win.noteId) win.refreshTabs() }
    function onResynced() { win.refreshTabs() }
  }

  function refreshTabs() {
    win.extraTabs = win.store ? win.store.tabsFor(win.noteId) : []
    if (win.activeTab >= win.tabCount) win.switchTab(win.tabCount - 1, true)
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

  function switchTab(i, force) {
    i = Math.max(0, Math.min(win.tabCount - 1, i))
    if (i === win.activeTab && !force) return
    editor.flush()
    win.activeTab = i
    editor.tabId = i === 0 ? "" : win.extraTabs[i - 1].id
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
    if (editor.isEmpty()) { win.deleteActiveTab(); return }
    win.confirmClose = true
    overlayKeys.forceActiveFocus()
  }

  function deleteActiveTab() {
    win.confirmClose = false
    if (win.activeTab === 0 || !win.store) return
    var doomed = win.extraTabs[win.activeTab - 1]
    editor.dirty = false                      // never flush into a tab being deleted
    var next = win.activeTab - 1
    win.store.deleteTab(doomed.id, function(err) {
      if (err) console.warn("desknotes: deleteTab failed:", err)
      win.switchTab(next, true)
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
    win.pickerOpen = false
    win.confirmClose = false
    editor.focusBlock(0, true)
  }

  function openLibrary() {
    if (win.service && typeof win.service.toggleLibrary === "function") win.service.toggleLibrary()
  }

  FocusScope {
    id: scope
    anchors.fill: parent
    anchors.margins: 2
    focus: true

    Keys.onPressed: function(event) {
      var ctrl = event.modifiers & Qt.ControlModifier
      var shift = event.modifiers & Qt.ShiftModifier
      var alt = event.modifiers & Qt.AltModifier
      if (ctrl && !shift && event.key === Qt.Key_W) { win.closeTab(); event.accepted = true; return }
      if (ctrl && !shift && event.key === Qt.Key_T) { win.newTab(); event.accepted = true; return }
      if (ctrl && (event.key === Qt.Key_Tab || event.key === Qt.Key_PageDown)) { win.switchTab((win.activeTab + 1) % win.tabCount); event.accepted = true; return }
      if (ctrl && (event.key === Qt.Key_Backtab || event.key === Qt.Key_PageUp)) { win.switchTab((win.activeTab + win.tabCount - 1) % win.tabCount); event.accepted = true; return }
      if (ctrl && !shift && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) { win.switchTab(event.key - Qt.Key_1); event.accepted = true; return }
      if (ctrl && shift && event.key === Qt.Key_I) { win.openPicker(win.activeTab); event.accepted = true; return }
      if (ctrl && event.key === Qt.Key_Comma) { win.saveAll(); if (win.service) win.service.openSettings(); event.accepted = true; return }
      if (ctrl && !shift && event.key === Qt.Key_S) { win.saveAll(); event.accepted = true; return }
      if (ctrl && !shift && event.key === Qt.Key_N) { if (win.store) win.store.createNote(); event.accepted = true; return }
      if (ctrl && shift && event.key === Qt.Key_F) { win.saveAll(); win.openLibrary(); event.accepted = true; return }
      if (ctrl && shift && event.key === Qt.Key_T) { win.cycleTheme(1); event.accepted = true; return }
      if (ctrl && shift && event.key === Qt.Key_P) { win.togglePin(); event.accepted = true; return }
      if (ctrl && shift && event.key === Qt.Key_L) { editor.cycleLabelColor(editor.focusedIndex); event.accepted = true; return }
      if (ctrl && (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal)) { win.setFontSize(win.fontSize + 1); event.accepted = true; return }
      if (ctrl && (event.key === Qt.Key_Minus || event.key === Qt.Key_Underscore)) { win.setFontSize(win.fontSize - 1); event.accepted = true; return }
      if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { editor.toggleTodo(editor.focusedIndex); event.accepted = true; return }
      if (alt && event.key === Qt.Key_Up) { editor.moveBlock(editor.focusedIndex, -1); event.accepted = true; return }
      if (alt && event.key === Qt.Key_Down) { editor.moveBlock(editor.focusedIndex, 1); event.accepted = true; return }
    }

    Column {
      anchors.fill: parent
      anchors.margins: Math.round(win.fontSize * 0.8)
      spacing: Math.round(win.fontSize * 0.5)

      TextInput {
        id: titleField
        width: parent.width
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

        onTextEdited: {
          win.localTitle = text
          if (win.store) win.store.updateNote(win.noteId, { title: text })
        }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Down) {
            editor.focusBlock(0, event.key === Qt.Key_Down ? false : true)
            event.accepted = true
          }
        }
      }

      // Tab bar: "1  2  +". Every box is the same size, the label is body-sized
      // whether it is a number or a glyph; the active box is filled with the
      // accent, the others are plain text, and "+" sits in a muted box.
      Row {
        id: tabBar
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
            width: tabBar.boxWidth
            height: tabBar.height
            radius: 0
            color: active ? win.themePalette.accentPrimary : (tabHover.containsMouse ? win.themePalette.currentLine : "transparent")
            Text {
              textFormat: Text.PlainText
              id: tabLabel
              anchors.centerIn: parent
              text: parent.glyph.length ? parent.glyph : String(parent.index + 1)
              font.family: win.fontFamily
              font.pixelSize: win.fontSize
              color: parent.active ? win.themePalette.background : win.themePalette.foreground
            }
            MouseArea {
              id: tabHover
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
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
        height: parent.height - titleField.height - tabBar.height - 1 - parent.spacing * 3
        store: win.store
        noteId: win.noteId
        palette: win.themePalette
        fontSize: win.fontSize
        fontFamily: win.fontFamily
        saveInterval: win.store ? parseInt(win.store.getSetting("autoSaveInterval", "500")) || 500 : 500
      }
    }
  }

  // Keyboard focus while the close-confirm strip or the icon picker is open.
  Item {
    id: overlayKeys
    anchors.fill: parent
    visible: win.confirmClose || win.pickerOpen
    Keys.onPressed: function(event) {
      event.accepted = true
      if (event.key === Qt.Key_Escape) { win.closeOverlay(); return }
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

  // Static accent frame, square corners. Drawn last so it sits above content.
  Rectangle {
    anchors.fill: parent
    color: "transparent"
    radius: 0
    border.width: 2
    border.color: scope.activeFocus ? win.themePalette.accentPrimary : win.themePalette.currentLine
  }
}
