// Notes & stack overlay: every note, open or stacked, with search.
// Keyboard: type to filter · Tab cycles All/Open/Stacked · Up/Down · Enter opens
// (restores a stacked note, focuses an open one) · Delete asks, then deletes ·
// Ctrl+N new note · Esc clears the filter, then closes.
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "NotePreview.js" as NotePreview
import "Themes.js" as Themes

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false
  readonly property var store: service ? service.store : null
  readonly property string pluginId: (manifest && manifest.id) || "lolu13.desknotes"

  property string filterText: ""
  property int scope: 0                       // 0 all, 1 open, 2 stacked
  readonly property var scopeNames: ["All", "Open", "Stacked"]
  property int selectedIndex: 0
  property bool confirmOpen: false
  // Keyed by note id, so no prototype: a row whose id is "__proto__" or
  // "constructor" must not resolve to something already on Object.prototype.
  property var textMatches: Object.create(null)   // noteId -> true (full-text hits)
  property var previewCache: Object.create(null)  // imperative memo: noteId -> { note, text }

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  property color muted: Color.muted
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int cardWidth: Math.min(Style.space(820), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(48), Style.font.title + Style.font.caption + Style.spacing.rowPaddingX * 2)

  ListModel { id: rows }

  // ---- host contract
  // Text for host-owned sinks (ConfirmDialog renders with AutoText): no
  // markup characters, no control characters, bounded length.
  function plainLabel(v) {
    var t = String(v === undefined || v === null ? "" : v).replace(/[<>&\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
    if (t.length > 60) t = t.slice(0, 60) + "…"
    return t.length ? t : "Untitled"
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.action === "new") { root.createAndDismiss(); return }
    root.settingsView = payload.action === "settings"
    root.opened = true
    root.confirmOpen = false
    root.rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function close() { root.opened = false; root.confirmOpen = false }
  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  // ---- data
  // SQLite stamps are UTC "YYYY-MM-DD HH:MM:SS"; show them in local time.
  function localTime(stamp) {
    if (!stamp) return ""
    var d = new Date(String(stamp).replace(" ", "T") + "Z")
    if (isNaN(d.getTime())) return String(stamp).slice(0, 16)
    return Qt.formatDateTime(d, "ddd d MMM HH:mm")
  }

  // "stacked", "pinned", "scratchpad", "open on 3", or plain "open" for an unbound note.
  function whereIs(note) {
    if (note.piled === true) return "stacked"
    if (note.pinned === true) return "pinned"
    var name = String(note.workspaceName || "")
    if (name.indexOf("special:") === 0) return name === "special:scratchpad" ? "scratchpad" : name.slice(8)
    if (note.workspaceId) return "open on " + (name.length ? name : note.workspaceId)
    return "open"
  }

  // The helper sends a bounded plain-text `preview` per note; contentBlocks is
  // empty for a stacked note, so only fall back to parsing when it is absent.
  function previewFor(note) {
    var cached = root.previewCache[note.id]
    if (cached && cached.note === note) return cached.text
    var text = typeof note.preview === "string" ? note.preview : NotePreview.text(note.contentBlocks)
    // This cache has no QML bindings; copying it per entry makes rebuilding
    // a large library quadratic. Note identity also catches same-second saves.
    root.previewCache[note.id] = { note: note, text: text }
    return text
  }

  function rebuild() {
    if (!root.store) { rows.clear(); return }
    var list = []
    if (root.scope !== 2) list = list.concat(root.store.openNotes)
    if (root.scope !== 1) list = list.concat(root.store.stackedNotes)
    var q = root.filterText.trim().toLowerCase()
    var prevRow = rows.count > 0 && root.selectedIndex >= 0 && root.selectedIndex < rows.count ? rows.get(root.selectedIndex) : null
    var prevId = prevRow ? prevRow.noteId : ""
    rows.clear()
    for (var i = 0; i < list.length; i++) {
      var n = root.store.noteById(list[i].id) || list[i]
      var title = n.title || ""
      var preview = root.previewFor(n)
      var kind = ""
      if (q.length) {
        if (title.toLowerCase().indexOf(q) !== -1) kind = "title"
        else if (preview.toLowerCase().indexOf(q) !== -1) kind = "text"
        else if (root.textMatches[n.id]) kind = "text"
        else continue
      }
      // An untitled note is listed by the moment it was captured.
      rows.append({
        noteId: n.id,
        title: title.length ? title : (root.localTime(n.createdAt) || "Untitled"),
        untitled: title.length === 0,
        piled: n.piled === true,
        where: root.whereIs(n),
        updated: root.localTime(n.updatedAt),
        preview: preview,
        matchKind: kind
      })
    }
    var idx = 0
    for (var r = 0; r < rows.count; r++) if (rows.get(r).noteId === prevId) { idx = r; break }
    root.selectedIndex = rows.count ? Math.min(idx, rows.count - 1) : 0
  }

  function setFilter(text) {
    root.filterText = text
    root.rebuild()
    if (text.trim().length >= 2) searchTimer.restart()
    else { searchTimer.stop(); root.textMatches = Object.create(null) }
  }

  function runSearch() {
    var q = root.filterText.trim()
    if (!root.store || q.length < 2) return
    root.store.search(q, function(err, hits) {
      if (err || !Array.isArray(hits)) return
      if (root.filterText.trim() !== q) return
      var m = Object.create(null)
      for (var i = 0; i < hits.length; i++) m[hits[i]] = true
      root.textMatches = m
      root.rebuild()
    })
  }

  function select(delta) {
    if (!rows.count) return
    root.selectedIndex = Math.max(0, Math.min(rows.count - 1, root.selectedIndex + delta))
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }
  function selectAbsolute(i) {
    if (!rows.count) return
    root.selectedIndex = Math.max(0, Math.min(rows.count - 1, i))
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function cycleScope() { root.scope = (root.scope + 1) % 3; root.rebuild() }

  function activate(i) {
    if (i < 0 || i >= rows.count || !root.store) return
    var r = rows.get(i)
    root.dismiss()
    if (r.piled) {
      if (root.service) root.service.openNote(r.noteId)
      else root.store.restoreNote(r.noteId)
    } else if (root.service) {
      root.service.focusNote(r.noteId)
    }
  }

  function requestDelete(i) {
    if (i < 0 || i >= rows.count) return
    confirm.selectedIndex = 0            // Cancel is the safe default
    root.confirmOpen = true
  }
  function confirmDelete() {
    var i = root.selectedIndex
    root.confirmOpen = false
    if (i < 0 || i >= rows.count || !root.store) return
    var id = rows.get(i).noteId
    root.store.deleteNote(id, function() { root.rebuild() })
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ---- settings view (Ctrl+,). Values live in app_settings through the store.
  property bool settingsView: false
  property int settingsIndex: 0
  property bool settingsEditing: false
  readonly property var settingsDefs: [
    { key: "defaultNoteWidth",  label: "Default note width",          kind: "number", def: 300, min: 200, max: 4000, step: 20,  unit: "px" },
    { key: "defaultNoteHeight", label: "Default note height",         kind: "number", def: 350, min: 150, max: 4000, step: 20,  unit: "px" },
    { key: "defaultFontSize",   label: "Text size for new notes",     kind: "number", def: 0,   min: 10,  max: 40,   step: 1,   unit: "px", auto: true, hint: "Backspace: same as Omarchy" },
    { key: "autoSaveInterval",  label: "Autosave delay",              kind: "number", def: 500, min: 100, max: 5000, step: 100, unit: "ms" },
    { key: "defaultTheme",      label: "Theme for new notes",         kind: "choice", def: "system" },
    { key: "markdownMirrorDir", label: "Markdown mirror folder",      kind: "text",   def: "", hint: "empty = off · e.g. ~/Notes" }
  ]

  function settingValue(d) {
    var v = root.store ? root.store.getSetting(d.key, "") : ""
    if (d.kind === "number") { var n = parseInt(String(v), 10); return isNaN(n) ? d.def : n }
    return v || d.def
  }
  function settingLabel(d) {
    var v = root.settingValue(d)
    if (d.kind === "number" && d.auto && !v) return "Same as Omarchy · " + Style.font.body + " px"
    if (d.kind === "number") return v + " " + d.unit
    if (d.kind === "choice") return Themes.displayName(v, root.store ? root.store.customThemes : [])
    return v.length ? v : "off"
  }
  function adjustSetting(d, dir) {
    if (!root.store) return
    if (d.kind === "number") {
      var cur = root.settingValue(d)
      if (d.auto && !cur) cur = Style.font.body           // step away from "same as Omarchy"
      var n = Math.max(d.min, Math.min(d.max, cur + dir * d.step))
      root.store.setSetting(d.key, String(n))
    } else if (d.kind === "choice") {
      var names = Themes.allNames(root.store.customThemes)
      var i = names.indexOf(root.settingValue(d))
      root.store.setSetting(d.key, names[(i + dir + names.length) % names.length])
    } else {
      root.beginEdit(d)
    }
  }
  function beginEdit(d) {
    root.settingsEditing = true
    settingEditor.text = root.store ? root.store.getSetting(d.key, "") : ""
    settingEditor.forceActiveFocus()
    settingEditor.cursorPosition = settingEditor.text.length
  }
  function commitEdit(d, value) {
    root.settingsEditing = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (!root.store) return
    if (d.key === "markdownMirrorDir") {
      root.store.setMirrorDir(value, function(err, result) {
        root.showStatus(err ? "Mirror not enabled: " + err
          : (result && result.dir ? "Mirroring " + result.written + " notes to " + String(result.dir).replace(/^\/home\/[^/]+/, "~") : "Mirror off"))
      })
    } else {
      root.store.setSetting(d.key, value)
    }
  }
  function settingsKey(event) {
    var d = root.settingsDefs[root.settingsIndex]
    var n = root.settingsDefs.length
    if (event.key === Qt.Key_Escape) { root.settingsView = false; return true }
    if (event.key === Qt.Key_Up) { root.settingsIndex = (root.settingsIndex + n - 1) % n; return true }
    if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) { root.settingsIndex = (root.settingsIndex + 1) % n; return true }
    if (event.key === Qt.Key_Left || event.key === Qt.Key_Minus) { root.adjustSetting(d, -1); return true }
    if (event.key === Qt.Key_Right || event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) { root.adjustSetting(d, 1); return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { if (d.kind === "text") root.beginEdit(d); else root.adjustSetting(d, 1); return true }
    if ((event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) && d.auto && root.store) { root.store.setSetting(d.key, ""); return true }
    return false
  }

  // ---- export. A short status replaces the footer hints for a few seconds.
  property string status: ""
  Timer { id: statusTimer; interval: 3500; onTriggered: root.status = "" }
  function showStatus(text) { root.status = text; statusTimer.restart() }

  function selectedRow() {
    var i = root.selectedIndex
    return (i >= 0 && i < rows.count) ? rows.get(i) : null
  }

  function copySelected() {
    var r = root.selectedRow()
    if (!r || !root.store) return
    root.store.copyMarkdown(r.noteId, function(err) {
      root.showStatus(err ? "Copy failed: " + err : "Copied “" + r.title + "” as Markdown")
    })
  }

  function exportSelected() {
    var r = root.selectedRow()
    if (!r || !root.store) return
    root.store.exportNote(r.noteId, function(err, path) {
      root.showStatus(err ? "Export failed: " + err : "Saved " + String(path).replace(/^\/home\/[^/]+/, "~"))
    })
  }

  function createAndDismiss() {
    root.dismiss()
    if (root.store) root.store.createNote()
  }

  Connections {
    target: root.store
    function onOpenNotesChanged() { if (root.opened) root.rebuild() }
    function onStackedNotesChanged() { if (root.opened) root.rebuild() }
    function onNoteRemoved(id) { delete root.previewCache[id] }
    function onResynced() { root.previewCache = Object.create(null); if (root.opened) root.rebuild() }
  }

  Timer { id: searchTimer; interval: 250; repeat: false; onTriggered: root.runSearch() }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "desknotes-library"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: 0
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.confirmOpen ? 20 : 0
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.confirmOpen) { if (confirm.handleKey(event)) event.accepted = true; return }
          var ctrl = event.modifiers & Qt.ControlModifier
          if (ctrl && event.key === Qt.Key_Comma) { root.settingsView = !root.settingsView; event.accepted = true; return }
          if (root.settingsView) { if (root.settingsKey(event)) event.accepted = true; return }
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter(""); else root.dismiss()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText)); event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            root.cycleScope(); event.accepted = true
          } else if (ctrl && event.key === Qt.Key_N) {
            root.createAndDismiss(); event.accepted = true
          } else if (ctrl && event.key === Qt.Key_E) {
            if (event.modifiers & Qt.ShiftModifier) root.exportSelected(); else root.copySelected()
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            root.requestDelete(root.selectedIndex); event.accepted = true
          } else if (event.key === Qt.Key_Up) { root.select(-1); event.accepted = true }
          else if (event.key === Qt.Key_Down) { root.select(1); event.accepted = true }
          else if (event.key === Qt.Key_PageUp) { root.select(-6); event.accepted = true }
          else if (event.key === Qt.Key_PageDown) { root.select(6); event.accepted = true }
          else if (event.key === Qt.Key_Home) { root.selectAbsolute(0); event.accepted = true }
          else if (event.key === Qt.Key_End) { root.selectAbsolute(rows.count - 1); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right) {
            root.activate(root.selectedIndex); event.accepted = true
          } else if (!ctrl && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text); event.accepted = true
          }
        }

        ConfirmDialog {
          id: confirm
          anchors.fill: parent
          opened: root.confirmOpen
          z: 10
          message: {
            var r = rows.count && root.selectedIndex >= 0 && root.selectedIndex < rows.count ? rows.get(root.selectedIndex) : null
            return r ? "Delete “" + root.plainLabel(r.title) + "”? This cannot be undone." : "Delete this note?"
          }
          confirmText: "Delete"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: 0
          onCanceled: { root.confirmOpen = false; Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
          onConfirmed: root.confirmDelete()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // header: search text + scope chips
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            anchors.left: parent.left
            anchors.right: chips.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.settingsView ? "Settings" : (root.filterText || "Search notes…")
            color: root.foreground
            opacity: root.filterText || root.settingsView ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Row {
            id: chips
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            visible: !root.settingsView
            Repeater {
              model: root.scopeNames
              delegate: Rectangle {
                required property int index
                required property string modelData
                width: chipText.implicitWidth + Style.space(16)
                height: Style.font.body + Style.space(10)
                radius: 0
                color: index === root.scope ? root.accent : "transparent"
                border.width: 1
                border.color: index === root.scope ? root.accent : Util.alpha(root.foreground, 0.35)
                Text {
                  textFormat: Text.PlainText
                  id: chipText
                  anchors.centerIn: parent
                  text: modelData
                  color: index === root.scope ? root.background : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: index === root.scope
                }
                MouseArea { anchors.fill: parent; onClicked: { root.scope = index; root.rebuild() } }
              }
            }
          }
        }

        // body: list + preview, or the settings rows
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - footer.height - Style.spacing.md * 2

          Column {
            anchors.fill: parent
            visible: root.settingsView
            spacing: 0
            Repeater {
              model: root.settingsDefs
              delegate: Rectangle {
                id: srow
                required property int index
                required property var modelData
                readonly property bool selected: index === root.settingsIndex
                readonly property bool editing: selected && root.settingsEditing && modelData.kind === "text"
                width: parent.width
                height: root.rowHeight
                radius: 0
                color: selected ? root.selectedBackground : "transparent"

                Rectangle { width: 3; height: parent.height; color: srow.selected ? root.accent : "transparent" }

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width * 0.45
                  textFormat: Text.PlainText
                  text: srow.modelData.label
                  color: srow.selected ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: srow.selected
                  elide: Text.ElideRight
                }

                // value: "‹ 300 px ›" for numbers and choices, the path for text
                Row {
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)
                  visible: !srow.editing
                  Text {
                    textFormat: Text.PlainText
                    text: "‹"
                    visible: srow.modelData.kind !== "text"
                    color: srow.selected ? root.selectedText : root.foreground
                    opacity: 0.6
                    font.family: root.fontFamily; font.pixelSize: Style.font.title
                    MouseArea { anchors.fill: parent; anchors.margins: -Style.space(6); onClicked: { root.settingsIndex = srow.index; root.adjustSetting(srow.modelData, -1) } }
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.settingLabel(srow.modelData)
                    color: srow.selected ? root.selectedText : root.foreground
                    opacity: srow.modelData.kind === "text" && !root.settingValue(srow.modelData).length ? 0.6 : 1
                    font.family: root.fontFamily; font.pixelSize: Style.font.title
                    elide: Text.ElideMiddle
                    width: Math.min(implicitWidth, srow.width * 0.42)
                    horizontalAlignment: Text.AlignRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "›"
                    visible: srow.modelData.kind !== "text"
                    color: srow.selected ? root.selectedText : root.foreground
                    opacity: 0.6
                    font.family: root.fontFamily; font.pixelSize: Style.font.title
                    MouseArea { anchors.fill: parent; anchors.margins: -Style.space(6); onClicked: { root.settingsIndex = srow.index; root.adjustSetting(srow.modelData, 1) } }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(4)
                  visible: srow.selected && !srow.editing && !!srow.modelData.hint
                  text: srow.modelData.hint || ""
                  color: srow.selected ? root.selectedText : root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily; font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  z: -1
                  onClicked: { root.settingsIndex = srow.index; if (srow.modelData.kind === "text") root.beginEdit(srow.modelData) }
                  onDoubleClicked: if (srow.modelData.kind !== "text") root.adjustSetting(srow.modelData, 1)
                }
              }
            }
          }

          // Inline editor for the text setting, placed over the selected row.
          Rectangle {
            visible: root.settingsEditing
            y: root.settingsIndex * root.rowHeight
            width: parent.width; height: root.rowHeight
            color: root.selectedBackground
            Rectangle { width: 3; height: parent.height; color: root.accent }
            TextInput {
              id: settingEditor
              anchors.left: parent.left; anchors.leftMargin: parent.width * 0.45 + Style.space(12)
              anchors.right: parent.right; anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              color: root.selectedText
              selectionColor: root.accent
              selectedTextColor: root.background
              font.family: root.fontFamily; font.pixelSize: Style.font.title
              clip: true
              maximumLength: 512
              Keys.onPressed: function(event) {
                var d = root.settingsDefs[root.settingsIndex]
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.commitEdit(d, text.trim()); event.accepted = true }
                else if (event.key === Qt.Key_Escape) { root.settingsEditing = false; Qt.callLater(function() { keyCatcher.forceActiveFocus() }); event.accepted = true }
              }
            }
          }

          Row {
            anchors.fill: parent
            visible: !root.settingsView

            Item {
              width: parent.width * 0.55
              height: parent.height
              clip: true

              ListView {
                id: list
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: rows
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  id: row
                  required property int index
                  required property string noteId
                  required property string title
                  required property bool untitled
                  required property bool piled
                  required property string where
                  required property string updated
                  required property string preview
                  required property string matchKind
                  readonly property bool selected: index === root.selectedIndex
                  width: ListView.view.width
                  height: root.rowHeight
                  radius: 0
                  color: selected ? root.selectedBackground : "transparent"

                  Rectangle { width: 3; height: parent.height; color: row.piled ? Util.alpha(root.muted, 0.6) : root.accent }

                  Column {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(10)
                    anchors.topMargin: Style.space(6)
                    anchors.bottomMargin: Style.space(6)
                    spacing: Style.space(2)
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: row.title
                      color: row.selected ? root.selectedText : root.foreground
                      opacity: row.untitled ? 0.6 : 1
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      font.bold: row.selected
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: row.where + "  ·  " + row.updated + (row.matchKind === "text" ? "  ·  match in text" : "")
                      color: row.selected ? root.selectedText : root.foreground
                      opacity: 0.6
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: if (root.selectedIndex !== row.index) root.selectedIndex = row.index
                    onClicked: root.activate(row.index)
                  }
                }
              }
            }

            Item {
              width: parent.width * 0.45
              height: parent.height
              clip: true
              readonly property var active: rows.count > 0 && root.selectedIndex < rows.count ? rows.get(root.selectedIndex) : null

              Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Util.alpha(root.border, 0.4) }

              Text {
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                textFormat: Text.PlainText
                text: parent.active ? (parent.active.preview.length ? parent.active.preview : "Empty note") : ""
                color: root.foreground
                opacity: parent.active && parent.active.preview.length ? 0.9 : 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.Wrap
                elide: Text.ElideRight
                maximumLineCount: 14
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: rows.count === 0
            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "󰎞"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
            }
            Text {
              textFormat: Text.PlainText
              text: root.filterText ? "No notes match “" + root.filterText + "”" : (root.scope === 1 ? "No open notes" : root.scope === 2 ? "The stack is empty" : "No notes yet · Ctrl+N creates one")
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }

        Text {
          id: footer
          width: parent.width
          textFormat: Text.PlainText
          text: root.status.length ? root.status
              : root.settingsView ? "↑↓ select  ·  ←→ change  ·  Enter edit  ·  Ctrl+, notes  ·  Esc back"
              : "Enter open  ·  Del delete  ·  Tab filter  ·  Ctrl+N new  ·  Ctrl+E copy  ·  Ctrl+Shift+E save .md  ·  Ctrl+, settings  ·  Esc"
          color: root.status.length ? root.accent : root.foreground
          opacity: root.status.length ? 1 : 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
