// Long-lived part of the plugin: owns the helper process, the notes cache,
// the note windows and the "desknotes" IPC target used by keybindings:
//   omarchy-shell desknotes newNote | newNoteFromClipboard | toggleLibrary | hideAll | restoreAll |
//   pinNote | mirror | mirrorStatus | settings | welcome | status
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Item {
  id: service

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginId: (manifest && manifest.id) || "lolu13.desknotes"
  readonly property alias store: store
  readonly property alias client: client

  HelperClient { id: client }
  NotesStore { id: store; client: client }
  NoteWindows { id: windows; store: store; service: service }

  function newNote() {
    store.createNote(function(err, note) {
      if (err) console.warn("desknotes: newNote failed:", err)
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
        if (err) { console.warn("desknotes: welcome note failed:", err); return }
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
      if (err) console.warn("desknotes: newNoteFromClipboard failed:", err)
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
      error: store.helperError || client.lastError || ""
    })
  }

  IpcHandler {
    target: "desknotes"

    function newNote(): string { service.newNote(); return "ok" }
    function toggleLibrary(): string { service.toggleLibrary(); return "ok" }
    function settings(): string { service.openSettings(); return "ok" }
    function welcome(): string { service.createWelcome(true); return "ok" }
    function hideAll(): string { store.stackAll(); return "ok" }
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
  }
}
