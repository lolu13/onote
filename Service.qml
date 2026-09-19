// Long-lived part of the plugin: owns the helper process, the notes cache,
// the note windows and the "onote" IPC target used by keybindings:
//   omarchy-shell onote newNote | newNoteFromClipboard | toggleLibrary | hideAll | restoreAll |
//   pinNote | mirror | mirrorStatus | settings | welcome | status | update | checkUpdate
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Item {
  id: service

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginId: (manifest && manifest.id) || "io.github.lolu13.onote"
  readonly property alias store: store
  readonly property alias client: client

  HelperClient { id: client }
  NotesStore { id: store; client: client }
  NoteWindows { id: windows; store: store; service: service }

  // The plugin's own directory, for the update check and the update script.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") !== 0) return ""
    try { return decodeURIComponent(u.slice(7)).replace(/\/$/, "") } catch (e) { return "" }
  }
  UpdateCheck { id: updates; pluginDir: service.pluginDir }
  // Every open note shows a small red square (UpdateBadge) while this is true.
  readonly property bool updateAvailable: updates.updateAvailable

  // The update itself runs where the user can see it: a floating terminal with
  // scripts/update.py, where Omarchy's own updater shows the diff and asks.
  function launchUpdate() {
    if (!service.pluginDir) return "plugin directory unknown"
    Quickshell.execDetached(["/usr/bin/uwsm-app", "--", "/usr/bin/xdg-terminal-exec",
      "--app-id=org.omarchy.terminal", "--title=Onote update", "-e",
      "/usr/bin/python3", "-I", service.pluginDir + "/scripts/update.py"])
    return "ok"
  }

  function newNote() {
    store.createNote(function(err, note) {
      if (err) console.warn("onote: newNote failed:", err)
    })
  }

  // First launch (no notes yet): a pinned welcome note near the top-right corner.
  function createWelcome(force) {
    var mon = Hyprland.focusedMonitor
    var w = 380, h = 560
    var mw = mon ? Math.round(mon.width / (mon.scale || 1)) : 1280
    var mh = mon ? Math.round(mon.height / (mon.scale || 1)) : 800
    h = Math.min(h, mh - 100)
    store._call("ensureWelcomeNote", { force: force === true, x: Math.max(0, mw - w - 24), y: 56, width: w, height: h },
      function(err, note) {
        if (err) { console.warn("onote: welcome note failed:", err); return }
        if (note) store._put(note)
      })
  }

  Connections {
    target: store
    function onResynced() {
      if (store.openNotes.length === 0 && store.stackedNotes.length === 0) service.createWelcome(false)
    }
  }

  function newNoteFromClipboard() {
    store.createNoteFromClipboard(function(err, note) {
      if (err) console.warn("onote: newNoteFromClipboard failed:", err)
    })
  }

  property string mirrorResult: ""
  function setMirror(dir) {
    service.mirrorResult = ""
    store.setMirrorDir(dir, function(err, result) {
      service.mirrorResult = err ? ("error: " + err)
        : (result && result.dir ? ("mirroring " + result.written + " notes to " + result.dir) : "mirror off")
    })
  }

  // Reopen a stacked note on its remembered workspace and go there.
  function openNote(id) { windows.openAndFollow(id) }
  function focusNote(id) { windows.focusNote(id) }

  function openSettings() {
    if (service.shell && typeof service.shell.toggle === "function")
      service.shell.toggle(service.pluginId, JSON.stringify({ action: "settings" }))
  }

  function toggleLibrary() {
    if (service.shell && typeof service.shell.toggle === "function")
      service.shell.toggle(service.pluginId, "{}")
  }

  function status() {
    return JSON.stringify({
      ready: store.ready,
      open: store.openNotes.length,
      stacked: store.stackedNotes.length,
      unsaved: store.unsavedCount,
      update: updates.summary,
      error: store.helperError || client.lastError || ""
    })
  }

  IpcHandler {
    target: "onote"

    function newNote(): string { service.newNote(); return "ok" }
    function toggleLibrary(): string { service.toggleLibrary(); return "ok" }
    function settings(): string { service.openSettings(); return "ok" }
    function welcome(): string { service.createWelcome(true); return "ok" }
    function hideNote(): string { return windows.hideFocused() }
    function hideAll(): string { windows.hideAll(); return "ok" }
    function restoreAll(): string { store.restoreAll(); return "ok" }
    function pinNote(): string { return windows.togglePinFocused() }
    function newNoteFromClipboard(): string { service.newNoteFromClipboard(); return "ok" }
    // No path parameter: an IPC method that reaches a filesystem sink would let
    // anything on this session write every note into a directory of its choosing.
    // The folder is picked by the user in Settings; this only opens that view.
    function mirror(): string { service.openSettings(); return "set the mirror folder in Settings" }
    function mirrorStatus(): string {
      var dir = store.getSetting("markdownMirrorDir", "")
      return (service.mirrorResult.length ? service.mirrorResult + " · " : "") + (dir ? "mirror dir: " + dir : "mirror off")
    }
    function status(): string { return service.status() }
    function reload(): string { store.reload(); return "ok" }
    function update(): string { return service.launchUpdate() }
    function checkUpdate(): string { updates.refresh(); return updates.summary }
  }
}
