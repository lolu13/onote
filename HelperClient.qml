// Owns the onote-helper process and the request/response bookkeeping.
// One JSON object per line each way; every request carries an id that the
// helper echoes back, so replies can be matched to callbacks.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: client

  property string helperPath: Quickshell.env("HOME") + "/.local/bin/onote-helper"
  property bool ready: false
  property string lastError: ""
  property int restarts: 0
  readonly property int maxRestarts: 5

  signal becameReady()
  signal died(string reason)

  property int _nextId: 1
  property var _pending: ({})

  // request(op, args, callback) -> callback(error, result). Either error or result is null.
  function request(op, args, cb) {
    if (!proc.running) {
      if (cb) cb("helper not running", null)
      return
    }
    var id = client._nextId++
    var msg = { id: id, op: op }
    for (var k in (args || {})) msg[k] = args[k]
    if (cb) client._pending[id] = cb
    proc.write(JSON.stringify(msg) + "\n")
  }

  function _onLine(line) {
    if (!line || !line.length) return
    var resp
    try { resp = JSON.parse(line) } catch (e) {
      console.warn("onote: unparsable helper line:", line.slice(0, 200))
      return
    }
    var cb = client._pending[resp.id]
    if (!cb) return
    delete client._pending[resp.id]
    if (resp.ok) cb(null, resp.result)
    else cb(resp.error || "unknown error", null)
  }

  function _failAll(reason) {
    var pending = client._pending
    client._pending = ({})
    for (var id in pending) {
      try { pending[id](reason, null) } catch (e) { console.warn("onote: callback threw:", e) }
    }
  }

  function start() {
    client.ready = false
    proc.running = true
  }

  // One reply line may carry every open note (each at most 5 MB) plus the
  // stacked notes' metadata. A line past this budget is a protocol failure:
  // the helper is restarted instead of the shell growing without bound.
  readonly property int maxLineBytes: 64 * 1024 * 1024
  property string _buf: ""

  function _onChunk(chunk) {
    client._buf += chunk
    if (client._buf.length > client.maxLineBytes) {
      client._buf = ""
      client.lastError = "helper reply exceeded " + client.maxLineBytes + " bytes"
      console.warn("onote:", client.lastError)
      proc.signal(9)
      return
    }
    var at
    while ((at = client._buf.indexOf("\n")) !== -1) {
      var line = client._buf.slice(0, at)
      client._buf = client._buf.slice(at + 1)
      client._onLine(line)
    }
  }

  Process {
    id: proc
    command: [client.helperPath]
    stdinEnabled: true
    running: true
    // The helper finds its database and the Wayland socket through these;
    // nothing else of the shell's environment is inherited.
    clearEnvironment: true
    environment: ({
      HOME: Quickshell.env("HOME"),
      XDG_DATA_HOME: Quickshell.env("XDG_DATA_HOME") || "",
      XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR") || "",
      WAYLAND_DISPLAY: Quickshell.env("WAYLAND_DISPLAY") || "",
      PATH: "/usr/bin"
    })

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { client._onChunk(chunk) }
    }
    stderr: SplitParser {
      onRead: function(line) {
        if (!line.length) return
        if (line.length > 4096) line = line.slice(0, 4096) + "…"
        console.log("onote-helper:", line)
        if (!client.ready && line.indexOf("ready on") !== -1) {
          client.ready = true
          client.restarts = 0
          client.becameReady()
        }
      }
    }

    onExited: function(exitCode, exitStatus) {
      var wasReady = client.ready
      client.ready = false
      client._buf = ""
      var reason = "helper exited (code " + exitCode + ")"
      client._failAll(reason)
      client.died(reason)
      if (client.restarts >= client.maxRestarts) {
        client.lastError = reason + "; giving up after " + client.restarts + " restarts"
        console.warn("onote:", client.lastError)
        return
      }
      restartTimer.interval = 1000 * Math.pow(2, client.restarts)
      client.restarts += 1
      restartTimer.start()
    }
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: client.start()
  }

  Component.onDestruction: {
    // Closing stdin lets the helper exit cleanly on its own.
    if (proc.running) proc.running = false
  }
}
