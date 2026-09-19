// Is a newer Onote published? `git fetch` in the plugin's own checkout, then
// count the commits each side has that the other lacks: the same question
// `omarchy plugin update` answers before it fast-forwards, minus the merge.
// The fetch lands in a private ref (refs/onote/check) and never touches
// FETCH_HEAD, which the updater diffs and then merges while the user reads:
// a background fetch there could swap the commit under a confirmed diff.
// Nothing is downloaded but git objects, nothing is executed from them, and a
// directory that is not a git checkout (a copy made by install.py --sync)
// reports "unsupported".
//
// git runs by absolute path, without hooks or fsmonitor (the checkout is
// user-writable), with an empty environment plus HOME and a fixed PATH, no
// terminal prompts, and a deadline with TERM then KILL. Its output is read in
// chunks and capped; anything past the cap marks the run as unknown.
//
// "unsupported" is only the latest answer: the probe runs again on the next
// tick or `checkUpdate`, so a transient git failure never turns the check off.
import QtQuick
import Quickshell
import Quickshell.Io
import "UpdateCheck.js" as Logic

Item {
  id: check

  property string pluginDir: ""
  // "idle" | "unsupported" | "checking" | "current" | "update" | "error"
  property string status: "idle"
  readonly property bool updateAvailable: status === "update"
  property string checkedAt: ""
  readonly property string summary: Logic.describe(status, checkedAt)

  // Once at start (after the shell has settled), then every six hours.
  readonly property int firstDelayMs: 30000
  readonly property int intervalMs: 6 * 3600 * 1000

  // The git commands, in order. Step 0 asks whether this directory is a
  // checkout of its own (".git", not an enclosing repository's path); it runs
  // every time, since a .git can disappear under a running shell.
  // Step 3 reads HEAD and step 4 (not git) install.py's state file: a
  // checkout fast-forwarded by `omarchy plugin update` alone is newer than
  // the helper built from it, which is an update to finish, not "up to date".
  readonly property var steps: [
    ["rev-parse", "--git-dir"],
    ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "origin", "+HEAD:refs/onote/check"],
    ["rev-list", "--left-right", "--count", "HEAD...refs/onote/check"],
    ["rev-parse", "HEAD"]
  ]
  property int _step: -1
  property string _verdict: ""
  property string _head: ""
  // The verdict before this run: a fetch that fails (offline) does not
  // forget an update already seen, which the fetched ref still holds.
  property string _prev: ""
  readonly property string installStatePath: {
    var s = Quickshell.env("XDG_STATE_HOME"), home = Quickshell.env("HOME")
    return (s ? String(s) : String(home || "") + "/.local/state") + "/onote/install.json"
  }

  function refresh() {
    if (!check.pluginDir || proc.running) return
    check._prev = check.status
    check.status = "checking"
    check._step = -1
    check._verdict = ""; check._head = ""
    check._next()
  }

  function _next() {
    if (++check._step < check.steps.length) check._run(check.steps[check._step])
    else check._runCat()
  }

  function _runCat() {
    check._out = ""; check._outBytes = 0; check._err = ""
    proc.command = ["/usr/bin/cat", "--", check.installStatePath]
    proc.running = true
    deadline.restart()
  }

  property string _out: ""
  property int _outBytes: 0
  property string _err: ""
  readonly property int maxBytes: 4096

  function _run(args) {
    check._out = ""; check._outBytes = 0; check._err = ""
    proc.command = ["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=",
                    "-C", check.pluginDir].concat(args)
    proc.running = true
    deadline.restart()
  }

  readonly property var gitEnv: {
    var e = ({})
    var home = Quickshell.env("HOME")
    if (home) e["HOME"] = String(home)
    e["PATH"] = "/usr/bin"
    e["GIT_TERMINAL_PROMPT"] = "0"
    e["GIT_SSH_COMMAND"] = "/usr/bin/ssh -oBatchMode=yes"
    return e
  }

  Process {
    id: proc
    clearEnvironment: true
    environment: check.gitEnv
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        check._outBytes += chunk.length
        if (check._outBytes <= check.maxBytes) check._out += chunk
        else if (proc.running) { proc.signal(15); killTimer.start() }
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      // Only the head of stderr is kept, for one warning line.
      onRead: function(chunk) { if (check._err.length < 200) check._err += chunk }
    }
    onExited: function(code) { check._finish(code) }
  }

  function _finish(code) {
    deadline.stop(); killTimer.stop()
    var ok = code === 0 && check._outBytes <= check.maxBytes
    switch (check._step) {
    case 0:
      // Not a checkout of its own (or git could not say): nothing to update from.
      if (!ok || !Logic.ownCheckout(check._out)) { check.status = "unsupported"; return }
      check._next()
      return
    case 1:
      if (!ok) { check._fail("fetch exited " + code); return }
      check._next()
      return
    case 2:
      check._verdict = ok ? Logic.verdict(check._out) : "unknown"
      if (check._verdict === "unknown") { check._fail("rev-list exited " + code); return }
      check._next()
      return
    case 3:
      check._head = ok ? check._out : ""
      check._next()
      return
    default:
      // No state file (never installed by install.py): nothing to compare.
      var behind = ok && Logic.installedBehind(check._head, check._out)
      check._done(check._verdict === "update" || behind ? "update" : "current")
    }
  }

  function _done(status) {
    check.checkedAt = Qt.formatDateTime(new Date(), "hh:mm")
    check.status = status
  }

  function _fail(why) {
    console.warn("onote: update check:", why, check._err.trim().slice(0, 200))
    check._done(check._prev === "update" ? "update" : "error")
  }

  Timer {
    id: deadline
    interval: 60000
    onTriggered: { if (proc.running) { console.warn("onote: update check timed out"); proc.signal(15); killTimer.start() } }
  }
  Timer {
    id: killTimer
    interval: 2000
    onTriggered: if (proc.running) proc.signal(9)
  }
  Timer {
    id: ticker
    interval: check.firstDelayMs
    running: check.pluginDir.length > 0
    repeat: true
    onTriggered: { ticker.interval = check.intervalMs; check.refresh() }
  }

  Component.onDestruction: if (proc.running) proc.signal(15)
}
