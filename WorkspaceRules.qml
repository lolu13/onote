// Registers named Hyprland window rules per note so a note maps straight
// onto its remembered place: "dn-<tag>" puts it on its workspace, silently;
// "dnp-<tag>" floats and pins it at its saved position and size. Rules go
// through `hyprctl eval` because a shell plugin cannot ship Hyprland config.
//
// Re-registering a name MERGES keys into the existing rule (a pin key never
// goes away by itself), so the two modes use two names and the inactive one
// is disabled on every switch. A rule only acts while a window opens, so
// nothing is ever removed.
//
// Hyprland regexes are full-match: every pattern here is wrapped in `.*`.
// A window is identified by a tag in its title because every Quickshell
// window shares the class `org.quickshell`.
import QtQuick
import Quickshell
import Quickshell.Io
import "RulesLua.js" as RulesLua

Item {
  id: rules

  signal placed(var ids)

  property var _queue: []      // [{ id, ws }] waiting for the next hyprctl run
  property var _inflight: []   // note ids covered by the running hyprctl
  property bool _busy: false   // Process.running turns true asynchronously; gate on this

  // The Lua builders live in RulesLua.js (testable without Quickshell); these
  // wrappers keep the API NoteWindows uses.
  function shortId(noteId) { return RulesLua.shortId(noteId) }
  function tag(noteId) { return RulesLua.tag(noteId) }
  function windowSelector(noteId) { return RulesLua.windowSelector(noteId) }
  function workspaceSelector(note) { return RulesLua.workspaceSelector(note) }
  function ruleLua(note) { return RulesLua.ruleLua(note) }
  function pinScript(selector, on, width, height) { return RulesLua.pinScript(selector, on, width, height) }

  function ensure(notes) {
    var q = rules._queue
    for (var i = 0; i < notes.length; i++) q.push(notes[i])
    rules._queue = q
    rules._pump()
  }

  function _pump() {
    if (rules._busy || !rules._queue.length) return
    rules._busy = true
    var batch = rules._queue
    rules._queue = []
    var lua = []
    for (var i = 0; i < batch.length; i++) if (rules.shortId(batch[i].id)) lua.push(rules.ruleLua(batch[i]))
    rules._inflight = batch.map(function(n) { return n.id })
    if (!lua.length) { rules._finish(0); return }
    rules._err = ""
    rules._errBytes = 0
    proc.command = ["/usr/bin/hyprctl", "eval", lua.join("\n")]
    proc.running = true
    deadline.restart()
  }

  // hyprctl's stderr is kept only up to a small cap; anything past it is
  // dropped, never buffered. The run has a deadline with TERM then KILL.
  readonly property int maxErrBytes: 4096
  property string _err: ""
  property int _errBytes: 0

  // hyprctl inherits nothing: only the socket it must find, the runtime dir
  // that socket lives in, a HOME for its config lookups, and a fixed PATH.
  readonly property var hyprctlEnv: {
    var e = ({})
    var sig = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    if (sig) e["HYPRLAND_INSTANCE_SIGNATURE"] = String(sig)
    var run = Quickshell.env("XDG_RUNTIME_DIR")
    if (run) e["XDG_RUNTIME_DIR"] = String(run)
    var home = Quickshell.env("HOME")
    if (home) e["HOME"] = String(home)
    e["PATH"] = "/usr/bin"
    return e
  }

  Process {
    id: proc
    clearEnvironment: true
    environment: rules.hyprctlEnv
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        rules._errBytes += chunk.length
        if (rules._errBytes <= rules.maxErrBytes) rules._err += chunk
      }
    }
    onExited: function(code) { rules._finish(code) }
  }

  function _finish(code) {
    deadline.stop(); killTimer.stop()
    var ids = rules._inflight
    rules._inflight = []
    rules._busy = false
    var err = rules._err.trim()
    if (rules._errBytes > rules.maxErrBytes) err += " …(" + rules._errBytes + " bytes)"
    if (err.length) console.warn("onote: workspace rule:", err)
    rules._err = ""
    if (code !== 0) console.warn("onote: hyprctl eval exited", code, "- notes open on the current workspace")
    rules.placed(ids)
    rules._pump()
  }

  Timer {
    id: deadline
    interval: 10000
    onTriggered: { if (proc.running) { console.warn("onote: hyprctl eval timed out"); proc.signal(15); killTimer.start() } }
  }
  Timer {
    id: killTimer
    interval: 2000
    onTriggered: if (proc.running) proc.signal(9)
  }

  Component.onDestruction: if (proc.running) proc.signal(15)
}
