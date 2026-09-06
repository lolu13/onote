// Save bookkeeping of NotesStore against a scripted helper client: failed
// writes stay pending, an older acknowledgement never overwrites newer
// content, and reloads keep unsaved local edits.
import QtQuick
import QtTest
import ".."

Item {
  QtObject {
    id: client
    property bool ready: true
    signal becameReady()
    signal died(string reason)
    property var pending: []
    function request(op, args, cb) { pending.push({ op: op, args: JSON.parse(JSON.stringify(args)), cb: cb }) }
    function next(op) {
      for (var i = 0; i < pending.length; i++) if (!pending[i].done && pending[i].op === op) return pending[i]
      return null
    }
    function answer(op, err, result) { var r = next(op); if (!r) throw new Error("no pending " + op); r.done = true; r.cb(err, result); return r }
    function count(op) { var n = 0; for (var i = 0; i < pending.length; i++) if (pending[i].op === op) n++; return n }
  }
  NotesStore { id: store; client: client }

  TestCase {
    name: "NotesStoreSaves"
    function init() {
      client.pending = []
      store.notes = { n: { id: "n", contentBlocks: "original", title: "", piled: false, updatedAt: "1" } }
      store.tabs = ({}); store._tabNote = ({})
      store._dirty = ({}); store._sent = ({}); store._rev = ({}); store.saveErrors = ({})
      store._dirtyTabs = ({}); store._tabRev = ({}); store._tabSent = ({})
      store._recount()
      store._rebuild()
    }

    function test_failed_save_stays_pending_and_survives_stacking() {
      store.updateNote("n", { contentBlocks: "unsaved" })
      compare(store.unsavedCount, 1)
      store.flush()
      compare(store.unsavedCount, 1, "in flight still counts")
      client.answer("updateNote", "disk full", null)
      verify(store._dirty.n === true, "failed write is dirty again")
      compare(store.saveErrors.n, "disk full")
      compare(store.unsavedCount, 1)
      // Closing the note: the stack reply must not replace the unsaved body.
      store.stackNote("n")
      compare(client.count("updateNote"), 2, "flush before stacking resends the content")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "2" })
      compare(store.noteById("n").contentBlocks, "unsaved")
      compare(store.noteById("n").piled, true, "server-owned fields are taken")
      client.answer("updateNote", null, { id: "n", title: "", contentBlocks: "unsaved", piled: true, updatedAt: "3" })
      compare(store.unsavedCount, 0)
      compare(store.saveErrors.n, undefined)
      compare(store.noteById("n").updatedAt, "3")
    }

    function test_old_ack_never_overwrites_newer_content() {
      store.updateNote("n", { contentBlocks: "A" }); store.flush()
      store.updateNote("n", { contentBlocks: "B" }); store.flush()
      var a = client.answer("updateNote", null, client.next("updateNote").args.note)
      compare(a.args.note.contentBlocks, "A")
      compare(store.noteById("n").contentBlocks, "B", "A's ack is ignored")
      store.updateNote("n", { title: "renamed" }); store.flush()
      var b = client.answer("updateNote", null, client.next("updateNote").args.note)
      compare(b.args.note.contentBlocks, "B")
      var c = client.answer("updateNote", null, client.next("updateNote").args.note)
      compare(c.args.note.contentBlocks, "B", "rename carries the newest body")
      compare(c.args.note.title, "renamed")
      compare(store.noteById("n").contentBlocks, "B")
      compare(store.unsavedCount, 0)
    }

    function test_restore_all_keeps_pending_edits() {
      store.updateNote("n", { contentBlocks: "unsaved" })
      store.restoreAll()
      compare(client.count("updateNote"), 1, "restoreAll flushes first")
      client.answer("restoreAll", null, 1)
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "9" }])
      compare(store.noteById("n").contentBlocks, "unsaved", "reload keeps the in-flight body")
      compare(store.noteById("n").updatedAt, "9")
      client.answer("listTabs", null, [])
      client.answer("updateNote", null, { id: "n", title: "", contentBlocks: "unsaved", piled: false, updatedAt: "10" })
      compare(store.noteById("n").contentBlocks, "unsaved")
      compare(store.unsavedCount, 0)
    }

    function test_reload_after_helper_restart_resends_dirty_tabs_and_notes() {
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "old tab" }] }
      store._tabNote = { t: "n" }
      store.updateTab("t", { contentBlocks: "new tab" })
      store.updateNote("n", { contentBlocks: "new body" })
      store.flush()
      // The helper dies: pending requests fail, nothing is lost.
      client.ready = false
      client.answer("updateTab", "helper exited (code 1)", null)
      client.answer("updateNote", "helper exited (code 1)", null)
      compare(store.unsavedCount, 2)
      client.ready = true
      store.reload()
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "1" }])
      client.answer("listTabs", null, [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "old tab" }])
      compare(store.tabsFor("n")[0].contentBlocks, "new tab", "reload keeps the unsaved tab")
      compare(store.noteById("n").contentBlocks, "new body")
      compare(client.count("updateTab"), 2, "resent after the restart")
      compare(client.count("updateNote"), 2)
      compare(client.next("updateTab").args.tab.contentBlocks, "new tab")
      compare(client.next("updateNote").args.note.contentBlocks, "new body")
    }

    // Stacked rows arrive without a body but with a preview; the body comes
    // back whole when the note is restored.
    function test_stacked_rows_carry_previews_and_restore_whole() {
      store.reload()
      client.answer("listNotes", null, [
        { id: "n", title: "", contentBlocks: "", preview: "hello there", piled: true, updatedAt: "1" },
        { id: "o", title: "", contentBlocks: "[body]", preview: "body", piled: false, updatedAt: "1" }])
      client.answer("listTabs", null, [])
      compare(store.stackedNotes.length, 1)
      compare(store.noteById("n").preview, "hello there")
      compare(store.noteById("o").contentBlocks, "[body]")
      store.restoreNote("n")
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "[full]", piled: false, updatedAt: "2" })
      compare(store.noteById("n").contentBlocks, "[full]")
      compare(store.openNotes.length, 2)
    }

    function test_delete_drops_pending_state() {
      store.updateNote("n", { contentBlocks: "gone" })
      store.deleteNote("n")
      client.answer("deleteNote", null, true)
      compare(store.unsavedCount, 0)
      compare(store.noteById("n"), null)
    }
  }
}
