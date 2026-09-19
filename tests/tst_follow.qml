// NoteWindows.openAndFollow's decisions (Follow.js) against the real store:
// a note closed moments ago is reopened, not focused, and a reopen that ends
// without a window releases its own follow marker and nobody else's.
import QtQuick
import QtTest
import ".."
import "../Follow.js" as Follow

Item {
  QtObject {
    id: client
    property bool ready: true
    signal becameReady()
    signal died(string reason)
    property var pending: []
    function request(op, args, cb) { pending.push({ op: op, cb: cb }) }
    function answer(op, err, result) {
      for (var i = 0; i < pending.length; i++) if (!pending[i].done && pending[i].op === op) { pending[i].done = true; pending[i].cb(err, result); return }
      throw new Error("no pending " + op)
    }
  }
  NotesStore { id: store; client: client; stackDelayMs: 60000 }

  TestCase {
    name: "Follow"
    property var follow: Object.create(null)
    property int seq: 0
    // openAndFollow, minus the Hyprland focus: returns "focus" or "reopen".
    function openAndFollow(id) {
      if (Follow.hasWindow(store, store.noteById(id))) return "focus"
      var token = ++seq
      follow = Follow.withMark(follow, id, token)
      store.restoreNote(id, function(err, note) { if (Follow.ended(follow, id, token, err, note)) follow = Follow.without(follow, id) })
      return "reopen"
    }
    function init() {
      client.pending = []; follow = Object.create(null)
      store._pendingStack = Object.create(null); store._restoring = Object.create(null); store._life = Object.create(null)
      store._landedOpen = Object.create(null)
      store.notes = { n: { id: "n", piled: false, contentBlocks: "[]", title: "" } }
      store._rebuild()
    }
    function test_an_open_note_is_focused() {
      compare(openAndFollow("n"), "focus"); verify(!follow.n)
    }
    function test_a_note_closed_moments_ago_is_reopened_not_focused() {
      store.stackNoteLater("n")
      compare(store.noteById("n").piled, false, "the row still reads open")
      compare(openAndFollow("n"), "reopen")
      verify(follow.n, "followed until its window maps")
      client.answer("unstackNote", null, { id: "n", piled: false, contentBlocks: "[]", title: "" })
      verify(follow.n, "a reopen that succeeded keeps the marker for the window")
    }
    function test_a_cancelled_reopen_releases_its_marker() {
      store.notes = { n: { id: "n", piled: true, contentBlocks: "", title: "" } }; store._rebuild()
      compare(openAndFollow("n"), "reopen")
      store.stackAll()                       // Hide All supersedes the reopen
      client.answer("tabsFor", null, [])     // the reopen ends: cancelled, no error
      verify(!follow.n, "no window will map, so nothing may consume the marker later")
    }
    function test_a_failed_reopen_releases_its_marker() {
      store.notes = { n: { id: "n", piled: true, contentBlocks: "", title: "" } }; store._rebuild()
      openAndFollow("n"); client.answer("tabsFor", "helper gone", null)
      verify(!follow.n)
    }
    function test_an_ended_reopen_never_releases_a_newer_ones_marker() {
      var f = Follow.withMark(Object.create(null), "n", 2)
      verify(!Follow.ended(f, "n", 1, null, null), "token 1 ended, token 2 owns the marker")
      verify(Follow.ended(f, "n", 2, "boom", null))
      verify(!Follow.ended(f, "n", 2, null, { id: "n" }), "success keeps it")
      verify(Follow.without(f, "__proto__").n === 2)
      verify(!("toString" in Follow.withMark(Object.create(null), "x", 1)), "no prototype")
    }
  }
}
