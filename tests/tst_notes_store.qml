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
      store._dirtySettings = Object.create(null); store._sentSettings = Object.create(null); store.settings = ({}); store.helperError = ""
      store._tooLarge = Object.create(null)
      store.syncing = false; store.ready = false   // an earlier test may have left a reload unanswered, or finished one
      store._reloading = false; store._reloadAgain = false; store._reloadWaiters = []
      store._pendingStack = Object.create(null); store.stackDelayMs = 40
      store._restoring = Object.create(null); store._life = Object.create(null); store._landedOpen = Object.create(null); store._deleting = Object.create(null)
      store._deletingTabs = Object.create(null); store._goneTabs = Object.create(null)
      store._recount()
      store._rebuild()
    }

    // An explicit hide keeps the window until the helper answers. Keystrokes
    // typed meanwhile live only in the editor: the store asks for them
    // (noteStacked) before it drops the stacked note's tabs, or the editor's
    // own flush would reach a tab the store no longer knows and be ignored.
    function test_keystrokes_typed_while_a_hide_is_in_flight_survive_the_eviction() {
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "old tab" }] }
      store._tabNote = { t: "n" }
      var typed = function(id) { if (id === "n") store.updateTab("t", { contentBlocks: "typed late" }) }
      store.noteStacked.connect(typed)
      store.stackNote("n")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "2" })
      store.noteStacked.disconnect(typed)
      compare(store._tabNote.t, "n", "the unsaved tab is still indexed")
      compare(store.tabsFor("n")[0].contentBlocks, "typed late")
      store.flush()
      compare(client.next("updateTab").args.tab.contentBlocks, "typed late", "and is written")
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
      // The save is acknowledged before the tabs arrive: the list snapshot
      // must not put the old body back afterwards.
      client.answer("updateNote", null, { id: "n", title: "", contentBlocks: "unsaved", piled: false, updatedAt: "10" })
      client.answer("listTabs", null, [])
      compare(store.noteById("n").updatedAt, "10")
      compare(store.noteById("n").contentBlocks, "unsaved")
      compare(store.unsavedCount, 0)
    }

    // The desktop edition's image icon rides in the list rows and is left
    // out past the budget (iconPending): such a row is fetched whole first,
    // so the paste budget sees the icon and a save never carries none.
    function test_icons_left_out_of_the_list_are_fetched_before_install() {
      store.reload()
      client.answer("listNotes", null, [
        { id: "n", title: "", contentBlocks: "[n]", icon: null, iconPending: true, piled: false, updatedAt: "2" },
        { id: "o", title: "", contentBlocks: "[o]", icon: "data:image/png;base64,AA==", piled: false, updatedAt: "2" }])
      compare(store.noteById("o"), null, "nothing installed until the icon is here")
      compare(client.next("getNote").args.noteId, "n")
      client.answer("getNote", null, { id: "n", title: "", contentBlocks: "[n]", icon: "data:image/png;base64,BB==", piled: false, updatedAt: "2" })
      compare(store.noteById("n").icon, "data:image/png;base64,BB==")
      compare(store.noteById("o").icon, "data:image/png;base64,AA==")
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      // A stacked row is never fetched for its icon: that would cache its body.
      store.reload()
      client.answer("listNotes", null, [
        { id: "s", title: "", contentBlocks: "", preview: "", icon: null, iconPending: true, piled: true, updatedAt: "2" }])
      compare(client.count("getNote"), 1, "no fetch for the stacked note")
      compare(store.noteById("s").contentBlocks, "")
    }

    // The helper leaves bodies past its reply budget out (bodyPending); they
    // are fetched one by one and installed together, never as an empty body.
    function test_bodies_left_out_of_the_list_are_fetched_before_install() {
      store.reload()
      client.answer("listNotes", null, [
        { id: "n", title: "", contentBlocks: "", bodyPending: true, preview: "p", piled: false, updatedAt: "2" },
        { id: "o", title: "", contentBlocks: "[o]", piled: false, updatedAt: "2" }])
      compare(store.noteById("o"), null, "nothing installed until every body is here")
      compare(client.next("getNote").args.noteId, "n")
      client.answer("getNote", null, { id: "n", title: "", contentBlocks: "[full n]", piled: false, updatedAt: "2" })
      compare(store.noteById("n").contentBlocks, "[full n]")
      compare(store.noteById("o").contentBlocks, "[o]")
      compare(store.openNotes.length, 2)
      client.answer("listTabs", null, [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "", bodyPending: true }])
      compare(store.tabsFor("n").length, 0, "a tab is not installed without its body either")
      client.answer("getTab", null, { id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[tab]" })
      compare(store.tabsFor("n")[0].contentBlocks, "[tab]")
    }

    function test_a_failed_body_fetch_fails_the_reload() {
      var result = "unset"
      store.reload(function(err) { result = err })
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "", bodyPending: true, piled: false, updatedAt: "2" }])
      client.answer("getNote", "helper exited (code 1)", null)
      compare(result, "helper exited (code 1)")
      compare(store.noteById("n").contentBlocks, "original", "the cache is untouched")
      compare(store.syncing, false)
    }

    // While other bodies are fetched, the list is already a snapshot: a note
    // (or tab) that was unsaved when it arrived keeps its local copy even if
    // its save is acknowledged before the fetches finish.
    function test_the_list_snapshot_never_replaces_content_saved_meanwhile() {
      store.notes = { n: store.noteById("n"),
                      m: { id: "m", title: "", contentBlocks: "[m]", piled: false, updatedAt: "1" },
                      o: { id: "o", title: "", contentBlocks: "[o]", piled: false, updatedAt: "1" } }
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "old tab" },
                         { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "old u" }] }
      store._tabNote = { t: "n", u: "n" }
      store.updateNote("n", { contentBlocks: "typed n" })
      store.updateNote("m", { contentBlocks: "typed m" })
      store.updateTab("t", { contentBlocks: "typed t" })
      store.flush()
      store.reload()
      client.answer("listNotes", null, [
        { id: "n", title: "", contentBlocks: "", bodyPending: true, piled: false, updatedAt: "2" },
        { id: "m", title: "", contentBlocks: "[stale m]", piled: false, updatedAt: "2" },
        { id: "o", title: "", contentBlocks: "", bodyPending: true, piled: false, updatedAt: "2" }])
      compare(client.count("getNote"), 1, "only the saved, pending note is fetched")
      compare(client.next("getNote").args.noteId, "o")
      client.answer("updateNote", null, { id: "n", title: "", contentBlocks: "typed n", piled: false, updatedAt: "3" })
      client.answer("updateNote", null, { id: "m", title: "", contentBlocks: "typed m", piled: false, updatedAt: "3" })
      client.answer("getNote", null, { id: "o", title: "", contentBlocks: "[o2]", piled: false, updatedAt: "2" })
      compare(store.noteById("n").contentBlocks, "typed n", "an empty row never lands in the cache")
      compare(store.noteById("m").contentBlocks, "typed m", "nor a stale one")
      compare(store.noteById("o").contentBlocks, "[o2]")
      client.answer("listTabs", null, [
        { id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "stale t" },
        { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "", bodyPending: true }])
      client.answer("updateTab", null, { id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "typed t" })
      client.answer("getTab", null, { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "[u2]" })
      compare(store.tabsFor("n")[0].contentBlocks, "typed t")
      compare(store.tabsFor("n")[1].contentBlocks, "[u2]")
    }

    function test_a_note_or_tab_created_during_the_body_fetch_is_kept() {
      store.reload()
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "", bodyPending: true, piled: false, updatedAt: "2" }])
      store.createNote()
      client.answer("createNote", null, { id: "new", title: "", contentBlocks: "[]", piled: false, updatedAt: "3" })
      compare(store.openNotes.length, 2)
      client.answer("getNote", null, { id: "n", title: "", contentBlocks: "[n]", piled: false, updatedAt: "2" })
      verify(store.noteById("new"), "created after the list: newer than the snapshot")
      compare(store.openNotes.length, 2)
      client.answer("listTabs", null, [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "", bodyPending: true }])
      store.createTab("new")
      client.answer("createTab", null, { id: "fresh", noteId: "new", position: 1, icon: "", contentBlocks: "[]" })
      client.answer("getTab", null, { id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[t]" })
      compare(store.tabsFor("new").length, 1, "created after the tab list: kept")
      compare(store.tabsFor("n")[0].contentBlocks, "[t]")
      compare(store._tabNote.fresh, "new")
    }

    // At startup the cache holds no tabs yet; a tab created while listed
    // bodies are fetched joins the listed ones instead of replacing them.
    function test_a_tab_created_during_the_first_tab_fetch_joins_the_listed_ones() {
      store.reload()
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "[n]", piled: false, updatedAt: "2" }])
      client.answer("listTabs", null, [
        { id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[t]" },
        { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "", bodyPending: true }])
      store.createTab("n")
      client.answer("createTab", null, { id: "v", noteId: "n", position: 3, icon: "", contentBlocks: "[]" })
      client.answer("getTab", null, { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "[u2]" })
      var ids = store.tabsFor("n").map(function(t) { return t.id })
      compare(ids, ["t", "u", "v"])
      compare(store.tabsFor("n")[1].contentBlocks, "[u2]")
      compare(store._tabNote.v, "n")
    }

    function test_a_stack_acknowledged_during_the_body_fetch_stays_stacked() {
      store.notes = { n: store.noteById("n"), o: { id: "o", title: "", contentBlocks: "[o]", piled: false, updatedAt: "1" } }
      store.reload()
      client.answer("listNotes", null, [
        { id: "n", title: "", contentBlocks: "[n]", piled: false, updatedAt: "2" },
        { id: "o", title: "", contentBlocks: "", bodyPending: true, piled: false, updatedAt: "2" }])
      store.stackNote("n")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "[n]", piled: true, updatedAt: "3" })
      client.answer("getNote", null, { id: "o", title: "", contentBlocks: "[o]", piled: false, updatedAt: "2" })
      compare(store.noteById("n").piled, true, "stacked after the list: not reopened by it")
      compare(store.stackedNotes.length, 1)
      compare(store.openNotes.length, 1)
    }

    function test_a_note_or_tab_deleted_during_the_body_fetch_stays_gone() {
      store.notes = { n: store.noteById("n"), o: { id: "o", title: "", contentBlocks: "[o]", piled: false, updatedAt: "1" } }
      store.tabs = { o: [{ id: "t", noteId: "o", position: 1, icon: "", contentBlocks: "[t]" },
                         { id: "u", noteId: "o", position: 2, icon: "", contentBlocks: "[u]" }] }
      store._tabNote = { t: "o", u: "o" }
      store.reload()
      client.answer("listNotes", null, [
        { id: "n", title: "", contentBlocks: "", bodyPending: true, piled: false, updatedAt: "2" },
        { id: "o", title: "", contentBlocks: "[o]", piled: false, updatedAt: "2" }])
      store.deleteNote("n")
      client.answer("deleteNote", null, true)
      client.answer("getNote", null, { id: "n", title: "", contentBlocks: "[n]", piled: false, updatedAt: "2" })
      compare(store.noteById("n"), null, "deleted after the list: not brought back")
      compare(store.openNotes.length, 1)
      client.answer("listTabs", null, [
        { id: "t", noteId: "o", position: 1, icon: "", contentBlocks: "[t]" },
        { id: "u", noteId: "o", position: 2, icon: "", contentBlocks: "", bodyPending: true }])
      store.deleteTab("t")
      client.answer("deleteTab", null, true)
      client.answer("getTab", null, { id: "u", noteId: "o", position: 2, icon: "", contentBlocks: "[u2]" })
      compare(store.tabsFor("o").length, 1, "the deleted tab stays gone")
      compare(store.tabsFor("o")[0].id, "u")
    }

    // Windows created mid-reload wait for resynced() before restoring their
    // remembered tab, since a restored note's tabs arrive after the note.
    function test_reload_is_marked_until_tabs_and_settings_arrived() {
      compare(store.syncing, false)
      store.reload()
      compare(store.syncing, true)
      client.answer("listNotes", null, [])
      client.answer("listTabs", null, [])
      client.answer("listSettings", null, {})
      compare(store.syncing, true)
      client.answer("listThemes", null, [])
      compare(store.syncing, false)
      store.reload()
      client.answer("listNotes", "helper not running", null)
      compare(store.syncing, false, "a failed reload is over too")
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
      // The stacked note's tabs were not listed; they arrive, bodies and all,
      // before the note opens, so no window ever shows an empty tab.
      client.answer("tabsFor", null, [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[tab body]" }])
      compare(store.tabsFor("n")[0].contentBlocks, "[tab body]")
      compare(store._tabNote.t, "n")
      compare(store.openNotes.length, 1, "still stacked until the helper says otherwise")
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "[full]", piled: false, updatedAt: "2" })
      compare(store.noteById("n").contentBlocks, "[full]")
      compare(store.openNotes.length, 2)
    }

    // A stacked note's tabs can exceed the helper's reply budget too: the
    // rows past it arrive one by one before the note opens.
    function test_restore_fetches_tab_bodies_past_the_budget_first() {
      store.notes = { n: { id: "n", contentBlocks: "", title: "", piled: true, updatedAt: "1" } }
      store._rebuild()
      store.restoreNote("n")
      client.answer("tabsFor", null, [
        { id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "", bodyPending: true },
        { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "[u]" }])
      compare(store.tabsFor("n").length, 0, "nothing installed without every body")
      compare(client.count("unstackNote"), 0)
      client.answer("getTab", null, { id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[t body]" })
      compare(store.tabsFor("n")[0].contentBlocks, "[t body]")
      compare(store.tabsFor("n")[1].contentBlocks, "[u]")
      compare(store._tabNote.t, "n")
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "[full]", piled: false, updatedAt: "2" })
      compare(store.openNotes.length, 1)
      // A failed body fetch keeps the note stacked.
      store.notes = { m: { id: "m", contentBlocks: "", title: "", piled: true, updatedAt: "1" } }
      store._rebuild()
      var result = "unset"
      store.restoreNote("m", function(err) { result = err })
      client.answer("tabsFor", null, [{ id: "v", noteId: "m", position: 1, icon: "", contentBlocks: "", bodyPending: true }])
      client.answer("getTab", "helper exited (code 1)", null)
      compare(result, "helper exited (code 1)")
      compare(client.count("unstackNote"), 1, "no second unstack")
      compare(store.stackedNotes.length, 1)
    }

    SignalSpy { id: changedSpy; target: store; signalName: "noteChanged" }

    function test_local_edit_announces_the_note_without_rebuilding_lists() {
      changedSpy.clear()
      store.notes = { n: { id: "n", contentBlocks: "original", preview: "original", title: "", piled: false, updatedAt: "1" } }
      store._rebuild()
      var openBefore = store.openNotes, stackedBefore = store.stackedNotes
      store.updateNote("n", { contentBlocks: "[typed]" })
      compare(changedSpy.count, 1); compare(changedSpy.signalArguments[0][0], "n")
      verify(store.openNotes === openBefore && store.stackedNotes === stackedBefore, "no list rebuild on a content edit")
      compare(store.noteById("n").preview, undefined, "the helper's preview went with the body it described")
      store.updateNote("n", { title: "renamed" })
      compare(changedSpy.count, 2)
      store.flush()
      client.answer("updateNote", null, { id: "n", title: "renamed", contentBlocks: "[typed]", piled: false, updatedAt: "2" })
      compare(changedSpy.count, 3, "the acknowledged row is announced too")
    }

    // A reload asked for while one is fetching bodies runs after it: two at
    // once would share the touched map, and a save acknowledged between the
    // two lists could land as the older list's (or an empty) row.
    function test_a_reload_started_during_another_runs_after_it_and_keeps_a_save_acknowledged_meanwhile() {
      var first = "unset", second = "unset"
      store.reload(function(e) { first = e })
      store.reload(function(e) { second = e })
      compare(client.count("listNotes"), 1, "the second reload waits for the first")
      store.updateNote("n", { contentBlocks: "typed n" })
      store.flush()
      client.answer("listNotes", null, [
        { id: "n", title: "", contentBlocks: "", bodyPending: true, piled: false, updatedAt: "2" },
        { id: "o", title: "", contentBlocks: "", bodyPending: true, piled: false, updatedAt: "2" }])
      compare(client.count("getNote"), 1, "the unsaved note is not fetched")
      client.answer("updateNote", null, { id: "n", title: "", contentBlocks: "typed n", piled: false, updatedAt: "3" })
      client.answer("getNote", null, { id: "o", title: "", contentBlocks: "[o]", piled: false, updatedAt: "2" })
      compare(store.noteById("n").contentBlocks, "typed n", "the acknowledged body wins over the older list")
      compare(store.noteById("o").contentBlocks, "[o]")
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      compare(first, "unset", "callers are answered once the queued reload is done too")
      compare(client.count("listNotes"), 2, "the queued reload starts once the first is done")
      compare(store.syncing, true)
      client.answer("listNotes", null, [
        { id: "n", title: "", contentBlocks: "typed n", piled: false, updatedAt: "3" },
        { id: "o", title: "", contentBlocks: "[o]", piled: false, updatedAt: "2" }])
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      compare(store.noteById("n").contentBlocks, "typed n")
      compare(first, null); compare(second, null)
      compare(store.syncing, false)
      compare(client.count("listNotes"), 2, "no third reload")
      store.updateNote("n", { title: "t" }); store.flush()
      compare(client.next("updateNote").args.note.contentBlocks, "typed n", "a later edit carries the saved body")
    }

    function test_a_failed_theme_list_fails_the_reload() {
      var resyncs = 0
      function count() { resyncs++ }
      store.resynced.connect(count)
      var result = "unset"
      store.reload(function(err) { result = err })
      client.answer("listNotes", null, [])
      client.answer("listTabs", null, [])
      client.answer("listSettings", null, {})
      compare(store.ready, false, "settings without themes do not finish the reload")
      client.answer("listThemes", "helper exited (code 1)", null)
      compare(result, "helper exited (code 1)")
      compare(store.syncing, false)
      compare(store.ready, false)
      compare(resyncs, 0, "windows keep waiting for a resync that has the themes")
      store.resynced.disconnect(count)
    }

    function test_a_failed_tab_list_fails_the_reload() {
      var resyncs = 0
      function count() { resyncs++ }
      store.resynced.connect(count)
      var result = "unset"
      store.reload(function(err) { result = err })
      client.answer("listNotes", null, [])
      client.answer("listSettings", null, {})
      client.answer("listThemes", null, [])
      compare(store.ready, false, "settings alone do not finish the reload")
      client.answer("listTabs", "helper exited (code 1)", null)
      compare(result, "helper exited (code 1)")
      compare(store.syncing, false)
      compare(store.ready, false)
      compare(resyncs, 0, "windows keep waiting for a resync that has the tabs")
      store.resynced.disconnect(count)
    }

    function test_a_failed_settings_list_fails_the_reload() {
      var resyncs = 0
      function count() { resyncs++ }
      store.resynced.connect(count)
      var result = "unset"
      store.reload(function(err) { result = err })
      client.answer("listNotes", null, [])
      client.answer("listTabs", null, [])
      client.answer("listSettings", "helper exited (code 1)", null)
      compare(result, "helper exited (code 1)")
      compare(store.syncing, false)
      compare(store.ready, false)
      compare(client.count("listThemes"), 0)
      compare(resyncs, 0, "windows keep waiting for a resync that has the settings")
      store.resynced.disconnect(count)
    }

    function test_restore_without_tabs_keeps_the_note_stacked() {
      store.notes = { n: { id: "n", contentBlocks: "", title: "", piled: true, updatedAt: "1" } }
      store._rebuild()
      var result = "unset"
      store.restoreNote("n", function(err) { result = err })
      client.answer("tabsFor", "helper not running", null)
      compare(result, "helper not running")
      compare(client.count("unstackNote"), 0, "not restored: its tabs would be missing")
      compare(store.stackedNotes.length, 1)
    }

    function test_reload_keeps_an_unsaved_tab_of_a_stacked_note() {
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "old tab" }] }
      store._tabNote = { t: "n" }
      store.updateTab("t", { contentBlocks: "typed just before closing" })
      store.reload()
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "", preview: "", piled: true, updatedAt: "1" }])
      client.answer("listTabs", null, [])            // stacked: the helper lists none of its tabs
      compare(store.tabsFor("n").length, 1, "the unsaved tab is kept")
      compare(store.tabsFor("n")[0].contentBlocks, "typed just before closing")
      compare(store._tabNote.t, "n")
      compare(client.next("updateTab").args.tab.contentBlocks, "typed just before closing", "and sent")
    }

    function test_failed_tab_delete_keeps_the_tab_and_its_edits() {
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "old tab" }] }
      store._tabNote = { t: "n" }
      store.updateTab("t", { contentBlocks: "unsaved" })
      var result = "unset"
      store.deleteTab("t", function(err) { result = err })
      compare(store.unsavedCount, 1, "nothing is forgotten before the helper answers")
      client.answer("deleteTab", "database is locked", null)
      compare(result, "database is locked")
      compare(store.tabsFor("n").length, 1, "the tab stays")
      verify(store._dirtyTabs.t === true, "so do its edits")
      store.flush()
      compare(client.next("updateTab").args.tab.contentBlocks, "unsaved")
      // The retry succeeds: now everything about the tab goes.
      store.deleteTab("t")
      client.answer("deleteTab", null, true)
      compare(store.tabsFor("n").length, 0)
      compare(store.unsavedCount, 0)
      compare(store._tabNote.t, undefined)
    }

    function test_failed_note_delete_keeps_the_note_and_its_edits() {
      store.updateNote("n", { contentBlocks: "unsaved" })
      var result = "unset"
      store.deleteNote("n", function(err) { result = err })
      compare(store.unsavedCount, 1, "nothing is forgotten before the helper answers")
      client.answer("deleteNote", "database is locked", null)
      compare(result, "database is locked")
      verify(store.noteById("n") !== null, "the note stays")
      verify(store._dirty.n === true, "so do its edits")
      store.flush()
      compare(client.next("updateNote").args.note.contentBlocks, "unsaved")
      store.reload()
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "9" }])
      compare(store.noteById("n").contentBlocks, "unsaved", "a reload answered meanwhile keeps the edit")
    }

    function test_delete_drops_pending_state() {
      store.updateNote("n", { contentBlocks: "gone" })
      store.deleteNote("n")
      client.answer("deleteNote", null, true)
      compare(store.unsavedCount, 0)
      compare(store.noteById("n"), null)
    }

    // The helper purges a deleted note's or tab's `note.<id>.*` settings; the
    // cache forgets them too, so a resync cannot show them again meanwhile.
    function test_deleting_a_note_or_tab_forgets_its_settings() {
      store.notes = { n: { id: "n", contentBlocks: "", title: "", piled: false, updatedAt: "1" },
                      o: { id: "o", contentBlocks: "", title: "", piled: false, updatedAt: "1" } }
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "" }] }
      store._tabNote = { t: "n" }
      store.settings = { "note.n.title.main": "Groceries", "note.n.titleLocked": "true", "note.n.label.t": "Prices",
                         "note.n.columns.t": "2", "note.o.label.t": "not ours", "theme": "keep" }
      store._dirtySettings = { "note.n.label.t": true, "theme": true }
      store.deleteTab("t")
      client.answer("deleteTab", null, true)
      compare(Object.keys(store.settings).sort(), ["note.n.title.main", "note.n.titleLocked", "note.o.label.t", "theme"])
      compare(Object.keys(store._dirtySettings), ["theme"])
      store.deleteNote("n")
      client.answer("deleteNote", null, true)
      compare(Object.keys(store.settings).sort(), ["note.o.label.t", "theme"])
    }

    function test_setting_written_during_a_reload_survives_the_older_list() {
      store.reload()
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "1" }])
      store.setSetting("note.n.title.t", "new title")    // queued behind listSettings
      client.answer("listTabs", null, [])
      client.answer("listSettings", null, { "note.n.title.t": "old title" })
      compare(store.settings["note.n.title.t"], "new title", "the older list does not undo a write in flight")
      client.answer("setSetting", null, true)
      compare(store.settings["note.n.title.t"], "new title")
      compare(store._sentSettings["note.n.title.t"], undefined)
      client.answer("listThemes", null, [])
      compare(store.ready, true)
    }

    function test_failed_setting_write_is_kept_and_resent() {
      store.setSetting("note.n.activeTab", "t2")
      client.answer("setSetting", "helper not running", null)
      verify(store._dirtySettings["note.n.activeTab"] === true)
      store.reload()
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "1" }])
      // The real order: tabs answer first, their flush resends the setting,
      // and the settings reply (still the old value) arrives while it is in flight.
      client.answer("listTabs", null, [])
      var resent = client.next("setSetting")
      verify(resent, "the reload's flush resends it")
      compare(resent.args.value, "t2")
      client.answer("listSettings", null, { "note.n.activeTab": "main", other: "x" })
      compare(store.getSetting("note.n.activeTab", ""), "t2", "the reload keeps the unsaved value")
      compare(store.getSetting("other", ""), "x")
      client.answer("setSetting", "helper not running", null)
      verify(store._dirtySettings["note.n.activeTab"] === true, "a failed retry stays pending")
      store.flush()
      client.answer("setSetting", null, true)
      compare(Object.keys(store._dirtySettings).length, 0)
    }

    function test_content_refused_as_too_large_is_kept_but_not_resent() {
      store.updateNote("n", { contentBlocks: "huge" })
      store.flush()
      client.answer("updateNote", "Note content exceeds 5 MB", null)
      verify(store.isTooLarge("n"))
      compare(store.unsavedCount, 1, "still unsaved")
      compare(store.noteById("n").contentBlocks, "huge", "the draft stays in memory")
      store.flush()
      wait(50)
      compare(client.count("updateNote"), 1, "the same content is never sent again")
      store.updateNote("n", { contentBlocks: "smaller" })
      store.flush()
      compare(client.count("updateNote"), 2, "a new edit is sent")
      client.answer("updateNote", null, { id: "n", title: "", contentBlocks: "smaller", piled: false, updatedAt: "2" })
      compare(store.unsavedCount, 0)
      verify(!store.isTooLarge("n"), "saved again: the refusal is cleared")
    }

    function test_old_setting_failure_does_not_mark_a_newer_value() {
      store.setSetting("k", "a")
      store.setSetting("k", "b")
      client.answer("setSetting", "busy", null)
      compare(store._dirtySettings.k, undefined, "b is still on its way")
      client.answer("setSetting", null, true)
      compare(store.getSetting("k", ""), "b")
    }

    function test_bulk_stack_failure_is_reported() {
      var result = "unset"
      store.stackAll(function(err) { result = err })
      client.answer("stackAll", "database is locked", null)
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "1" }])
      client.answer("listTabs", null, [])
      client.answer("listSettings", null, {})
      client.answer("listThemes", null, [])
      compare(result, "database is locked")
      compare(store.helperError, "stackAll: database is locked", "the reload does not wipe it")
    }
    function test_settled_answers_at_once_when_nothing_is_pending() {
      var got = "unset"
      store.settled("n", function(e) { got = e })
      compare(got, null)
    }

    function test_settled_waits_for_the_acknowledgement_and_reports_a_refusal() {
      store.updateNote("n", { contentBlocks: "typed" })
      var got = "unset"
      store.settled("n", function(e) { got = e })
      compare(client.count("updateNote"), 1, "flushed first")
      compare(got, "unset", "waits for the reply")
      client.answer("updateNote", null, { id: "n", title: "", contentBlocks: "typed", piled: false, updatedAt: "2" })
      compare(got, null)
      store.updateNote("n", { contentBlocks: "typed more" })
      store.settled("n", function(e) { got = e })
      client.answer("updateNote", "database is locked", null)
      compare(got, "not saved: database is locked")
      store.updateNote("n", { contentBlocks: "huge" })
      store.settled("n", function(e) { got = e })
      client.answer("updateNote", "content exceeds 5 MB", null)
      compare(got, "the note exceeds 5 MB and is not saved")
      store.settled("n", function(e) { got = e })
      compare(got, "the note exceeds 5 MB and is not saved", "never resent, reported at once")
    }

    function test_settled_covers_the_tabs() {
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "old" }] }
      store._tabNote = { t: "n" }
      store.updateTab("t", { contentBlocks: "typed tab" })
      var got = "unset"
      store.settled("n", function(e) { got = e })
      compare(client.count("updateTab"), 1)
      compare(got, "unset")
      client.answer("updateTab", "database is locked", null)
      compare(got, "unsaved changes could not be written")
    }

    function test_settings_of_a_note_being_deleted_are_not_written() {
      store.deleteNote("n")
      store.setSetting("note.n.title.t", "late title")
      compare(client.count("setSetting"), 0, "a deletion in flight refuses the write")
      client.answer("deleteNote", null, true)
      store.setSetting("note.n.title.t", "later still")
      compare(client.count("setSetting"), 0, "and so does a note that is gone")
      store.setSetting("onote.defaultFontSize", "18")
      compare(client.count("setSetting"), 1, "other settings still go")
    }

    function test_settings_held_during_a_refused_deletion_are_written_after() {
      store.deleteNote("n")
      store.setSetting("note.n.title.t", "kept title")
      store.setSetting("note.n.title.t", "kept title, edited")
      compare(client.count("setSetting"), 0, "held while the outcome is unknown")
      client.answer("deleteNote", "database is locked", null)
      compare(client.count("setSetting"), 1, "the deletion was refused: the last value goes")
      compare(store.settings["note.n.title.t"], "kept title, edited")
      compare(store.noteById("n") !== null, true)
    }

    function test_a_setting_retry_waits_for_a_deletion_in_flight() {
      store.setSetting("note.n.title.t", "retried title")
      client.answer("setSetting", "database is locked", null)
      store.deleteNote("n")
      store.flush()
      compare(client.count("setSetting"), 1, "the retry is held, not sent behind the delete")
      client.answer("deleteNote", null, true)
      store.flush()
      compare(client.count("setSetting"), 1, "the note is gone: the held retry goes with it")
      compare(store._dirtySettings["note.n.title.t"], undefined)
    }

    function test_a_setting_retry_held_during_a_refused_deletion_is_written_after() {
      store.setSetting("note.n.title.t", "retried title")
      client.answer("setSetting", "database is locked", null)
      store.deleteNote("n")
      store.flush()
      compare(client.count("setSetting"), 1)
      client.answer("deleteNote", "database is locked", null)
      compare(client.count("setSetting"), 2, "the deletion was refused: the retry goes")
      compare(client.pending[client.pending.length - 1].args.value, "retried title")
    }

    function test_a_tab_setting_retry_waits_for_the_tab_deletion() {
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[]" }] }
      store._tabNote = { t: "n" }
      store.setSetting("note.n.title.t", "tab title")
      client.answer("setSetting", "database is locked", null)
      store.deleteTab("t")
      store.flush()
      store.setSetting("note.n.label.t", "late label")
      compare(client.count("setSetting"), 1, "retry and new write are held, not sent behind the delete")
      client.answer("deleteTab", null, true)
      store.flush()
      store.setSetting("note.n.label.t", "later still")
      compare(client.count("setSetting"), 1, "the tab is gone: its settings go with it")
      store.setSetting("note.n.title.main", "main title")
      compare(client.count("setSetting"), 2, "the note's other settings still go")
    }

    function test_tab_settings_held_during_a_refused_tab_deletion_are_written_after() {
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[]" }] }
      store._tabNote = { t: "n" }
      store.deleteTab("t")
      store.setSetting("note.n.title.t", "kept tab title")
      compare(client.count("setSetting"), 0)
      client.answer("deleteTab", "database is locked", null)
      compare(client.count("setSetting"), 1, "the deletion was refused: the write goes")
      compare(store.settings["note.n.title.t"], "kept tab title")
    }

    // The window undoes its close on this error: the cache must still say
    // open, and the error must reach the caller, even when the client fails
    // the request at once (helper down).
    function test_failed_stack_reports_the_error_and_keeps_the_note_open() {
      var got = null
      store.stackNote("n", function(err) { got = err })
      client.answer("stackNote", "database is locked", null)
      compare(got, "database is locked")
      compare(store.noteById("n").piled, false)
      compare(store.openNotes.length, 1, "still open, its window is kept")
      compare(store.helperError, "stackNote: database is locked")
      var down = ({ ready: false, request: function(op, args, cb) { cb("helper not running", null) } })
      var real = store.client; store.client = down
      var sync = null
      store.stackNote("n", function(err) { sync = err })
      compare(sync, "helper not running", "answered before stackNote returned")
      compare(store.openNotes.length, 1)
      store.client = real
    }

    function test_stacking_evicts_the_saved_body_and_tabs() {
      store.notes = { n: { id: "n", title: "T", contentBlocks: "[{\"type\":\"text\",\"content\":\"hello\"}]", piled: false, updatedAt: "1" } }
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[t]" },
                        { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "[u]" }] }
      store._tabNote = { t: "n", u: "n" }
      store._rebuild()
      store.stackNote("n")
      client.answer("stackNote", null, { id: "n", title: "T", contentBlocks: "[{\"type\":\"text\",\"content\":\"hello\"}]", piled: true, updatedAt: "2" })
      compare(store.noteById("n").contentBlocks, "", "the body is not kept for a stacked note")
      compare(store.noteById("n").preview, "hello", "the Library still has its preview")
      compare(store.tabsFor("n").length, 0, "nor its tabs")
      compare(store._tabNote.t, undefined)
      compare(store.stackedNotes.length, 1)
    }

    function test_a_save_acknowledged_mid_restore_does_not_evict_the_fetched_tabs() {
      store.notes = { n: { id: "n", title: "T", contentBlocks: "", preview: "", piled: true, updatedAt: "1" } }
      store.tabs = { n: [{ id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "typed" }] }
      store._tabNote = { u: "n" }
      store._dirtyTabs = { u: true }; store._tabRev = { u: 1 }
      store._recount(); store._rebuild()
      store.flush()                              // the retry of an unsaved tab is in flight
      compare(client.count("updateTab"), 1)
      store.restoreNote("n")
      client.answer("tabsFor", null, [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[t]" }])
      compare(store.tabsFor("n").length, 2, "fetched tab installed next to the unsaved one")
      client.answer("updateTab", null, { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "typed" })
      compare(store.tabsFor("n").length, 2, "the ack while restoring evicts nothing")
      client.answer("unstackNote", null, { id: "n", title: "T", contentBlocks: "[]", piled: false, updatedAt: "2" })
      compare(store.tabsFor("n").length, 2)
      compare(store.openNotes.length, 1)
      compare(store._restoring.n, undefined)
    }

    function test_stacking_keeps_unsaved_edits_until_acknowledged() {
      store.notes = { n: { id: "n", title: "T", contentBlocks: "typed", piled: false, updatedAt: "1" } }
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "typed tab" },
                        { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "[u]" }] }
      store._tabNote = { t: "n", u: "n" }
      store._dirty = { n: true }; store._rev = { n: 1 }
      store._dirtyTabs = { t: true }; store._tabRev = { t: 1 }
      store._recount(); store._rebuild()
      store.stackNote("n")                       // flushes first, then stacks
      compare(client.count("updateNote"), 1); compare(client.count("updateTab"), 1)
      client.answer("stackNote", null, { id: "n", title: "T", contentBlocks: "typed", piled: true, updatedAt: "2" })
      compare(store.noteById("n").contentBlocks, "typed", "in flight: the local body stays")
      compare(store.tabsFor("n").length, 1, "the saved tab went, the in-flight one stays")
      compare(store.tabsFor("n")[0].id, "t")
      client.answer("updateNote", null, { id: "n", title: "T", contentBlocks: "typed", piled: true, updatedAt: "3" })
      compare(store.noteById("n").contentBlocks, "", "acknowledged after the stack: evicted then")
      client.answer("updateTab", null, { id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "typed tab" })
      compare(store.tabsFor("n").length, 0)
      compare(store.unsavedCount, 0)
    }

    // A restore's tabsFor rows are a snapshot: a tab's retry sent behind it
    // is acknowledged before the bodies arrive, and its row would be
    // installed over the acknowledged body and written back on the next edit.
    function test_restore_keeps_a_tab_save_acknowledged_during_its_body_fetch() {
      store.notes = { n: { id: "n", title: "", contentBlocks: "", preview: "", piled: true, updatedAt: "1" } }
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "typed" }] }
      store._tabNote = { t: "n" }
      store._dirtyTabs = { t: true }; store._tabRev = { t: 1 }     // an earlier save failed
      store._recount(); store._rebuild()
      store.restoreNote("n")
      store.flush()                                                 // the retry goes out after tabsFor
      client.answer("tabsFor", null, [
        { id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "OLD" },
        { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "", bodyPending: true }])
      client.answer("updateTab", null, { id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "typed" })
      client.answer("getTab", null, { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "[u]" })
      compare(store.tabsFor("n")[0].contentBlocks, "typed", "the acknowledged body wins over the older tabsFor row")
      compare(store.tabsFor("n").length, 2)
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "[full]", piled: false, updatedAt: "2" })
      compare(store._restoreAcked.n, undefined, "forgotten with the restore")
      store.updateTab("t", { icon: "x" }); store.flush()
      compare(client.next("updateTab").args.tab.contentBlocks, "typed", "and is what the next write carries")
    }

    // A reload's tab list, made while a note was still stacked, lands between
    // the restore's tabsFor and its unstackNote: the tabs just installed for
    // the restore are neither listed nor unsaved, and were dropped.
    function test_a_tab_list_landing_mid_restore_keeps_the_restored_tabs() {
      store.notes = { n: { id: "n", title: "", contentBlocks: "", preview: "", piled: true, updatedAt: "1" } }
      store._rebuild()
      store.reload()
      store.restoreNote("n")
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "", preview: "", piled: true, updatedAt: "1" }])
      client.answer("tabsFor", null, [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[t]" }])
      compare(store.tabsFor("n").length, 1)
      client.answer("listTabs", null, [])
      compare(store.tabsFor("n").length, 1, "the restore's tabs survive the older list")
      compare(store._tabNote.t, "n")
      client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "[n]", piled: false, updatedAt: "2" })
      compare(store.tabsFor("n").length, 1)
      compare(store.openNotes.length, 1)
    }

    // Eviction is per tab: a tab whose save was refused (over 5 MB) is still
    // unsaved, so stacking keeps it with its local body next to nothing, a
    // retry finds it, and a restore keeps that body over the database's row.
    function test_a_refused_tab_survives_stacking_and_restore() {
      store.notes = { n: { id: "n", title: "T", contentBlocks: "[]", piled: false, updatedAt: "1" } }
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "HUGE" },
                        { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "[u]" }] }
      store._tabNote = { t: "n", u: "n" }
      store._dirtyTabs = { t: true }; store._tabRev = { t: 1 }
      store._recount(); store._rebuild()
      store.stackNote("n")
      compare(client.count("updateTab"), 1)
      client.answer("updateTab", "Tab content exceeds 5 MB", null)
      verify(store.isTooLarge("t"))
      client.answer("stackNote", null, { id: "n", title: "T", contentBlocks: "[]", piled: true, updatedAt: "2" })
      compare(store.tabsFor("n").length, 1, "the clean tab went, the refused one stays")
      compare(store.tabsFor("n")[0].contentBlocks, "HUGE", "with its local body")
      compare(store._tabNote.t, "n"); compare(store._tabNote.u, undefined)
      verify(store._dirtyTabs.t === true, "still dirty")
      store.updateTab("t", { contentBlocks: "smaller" })
      store.flush()
      compare(client.count("updateTab"), 2, "the edited tab is sent again")
      client.answer("updateTab", "Tab content exceeds 5 MB", null)
      store.restoreNote("n")
      client.answer("tabsFor", null, [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "OLD-DB" },
                                      { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "[u]" }])
      client.answer("unstackNote", null, { id: "n", title: "T", contentBlocks: "[]", piled: false, updatedAt: "3" })
      compare(store.tabsFor("n").length, 2)
      compare(store.tabsFor("n")[0].contentBlocks, "smaller", "the unsaved local body wins over the database row")
      compare(store.tabsFor("n")[1].contentBlocks, "[u]")
    }

    function test_delayed_stack_evicts_the_saved_body_too() {
      store.notes = { n: { id: "n", title: "T", contentBlocks: "[{\"type\":\"text\",\"content\":\"hi\"}]", piled: false, updatedAt: "1" } }
      store._rebuild()
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", null, { id: "n", title: "T", contentBlocks: "[{\"type\":\"text\",\"content\":\"hi\"}]", piled: true, updatedAt: "2" })
      compare(store.noteById("n").contentBlocks, "")
      compare(store.noteById("n").preview, "hi")
      compare(store.stackedNotes.length, 1)
    }

    function test_compositor_close_stacks_now_and_on_disk_later() {
      store.stackNoteLater("n")
      compare(store.openNotes.length, 0, "the window goes away at once")
      compare(store.stackedNotes.length, 1)
      verify(store.isStacked(store.noteById("n")))
      compare(store.noteById("n").piled, false, "the cached row still matches the disk")
      compare(client.count("stackNote"), 0, "nothing written yet")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "written after the delay")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "2" })
      compare(store.noteById("n").piled, true)
      compare(store._pendingStack.n, undefined)
      compare(store.stackedNotes.length, 1)
    }

    function test_save_while_waiting_keeps_the_note_open_on_disk() {
      store.updateNote("n", { contentBlocks: "last words" })
      store.stackNoteLater("n")
      var sent = client.next("updateNote")
      verify(sent, "closing flushes the content first")
      compare(sent.args.note.piled, false, "a content save never stacks the note early")
    }

    function test_reopen_while_waiting_cancels_the_stack() {
      store.stackNoteLater("n")
      store.restoreNote("n")
      compare(store.openNotes.length, 1, "open again without waiting for the helper")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 0)
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      compare(store.openNotes.length, 1)
    }

    function test_reopen_after_the_stack_was_sent_ignores_its_reply() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1)
      store.restoreNote("n")
      compare(store.openNotes.length, 0, "the stack may have landed: shown stacked until the reopen is done")
      compare(client.count("tabsFor"), 1, "and its tabs are fetched like any stacked note's")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "2" })
      compare(store._pendingStack.n, undefined, "the stack reply is taken as usual")
      compare(store.openNotes.length, 0)
      client.answer("tabsFor", null, [])
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "3" })
      compare(store.openNotes.length, 1)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "nothing stacks it again")
    }

    function test_reload_while_waiting_keeps_it_stacked() {
      store.stackNoteLater("n")
      store.reload()
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "1" }])
      compare(store.openNotes.length, 0, "the disk still says open; the window must not come back")
      compare(store.stackedNotes.length, 1)
    }

    function test_failed_stack_is_retried() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", "helper down", null)
      compare(store.stackedNotes.length, 1, "still stacked in the UI")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 2)
    }

    function test_waiting_stack_is_newest_in_the_stack() {
      store.notes = { n: { id: "n", title: "", piled: false, updatedAt: "1" },
                      old: { id: "old", title: "", piled: true, updatedAt: "9" } }
      store._rebuild()
      store.stackNoteLater("n")
      compare(store.stackedNotes[0].id, "n")
    }

    function test_stack_all_lets_waiting_stacks_go_only_when_it_succeeds() {
      store.stackNoteLater("n")
      store.stackAll()
      client.answer("stackAll", "database is locked", null)
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "1" }])
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])   // the next reload runs after this one
      verify(store._pendingStack.n !== undefined, "still waiting after a failed bulk stack")
      compare(store.stackedNotes.length, 1)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "and still written on its own later")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "2" })
      store.notes = { o: { id: "o", title: "", contentBlocks: "", piled: false, updatedAt: "1" } }
      store.stackNoteLater("o")
      store.stackAll()
      client.answer("stackAll", null, 1)
      compare(store._pendingStack.o, undefined, "the bulk stack covered it")
      client.answer("listNotes", null, [{ id: "o", title: "", contentBlocks: "", piled: true, updatedAt: "3" }])
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "no second write for it")
    }

    function test_a_bulk_stack_counts_as_an_attempt_for_the_notes_it_covers() {
      store.stackNoteLater("n")
      store.stackAll()
      store.restoreNote("n")
      compare(store.openNotes.length, 0, "the bulk write may have landed: not shown open before the disk answers")
      compare(client.count("tabsFor"), 1, "reopened the careful way")
      store.notes = { o: { id: "o", title: "", contentBlocks: "", piled: false, updatedAt: "1" } }
      store._pendingStack = Object.create(null)
      store.stackNoteLater("o")
      store.stackAll()
      store.restoreAll()
      verify(store._pendingStack.o !== undefined && store._pendingStack.o.held !== undefined, "Restore All holds it until the helper confirms")
    }

    // The entry a Hide All covered may be gone by its reply (a reopen's
    // unstack superseded it); the note is stacked on disk all the same.
    function test_hide_all_marks_a_covered_note_stacked_even_when_its_entry_was_superseded() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", "database is locked", null)   // tried, may have landed
      store.restoreNote("n")                                     // the careful way
      client.answer("tabsFor", null, [])                         // unstackNote in flight
      store.stackAll()                                           // covers n
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      client.answer("stackAll", null, 1)
      compare(store.noteById("n").piled, true, "stacked on disk by the bulk write")
      compare(store.openNotes.length, 0, "no window reopens on a stale reopen")
      client.answer("listNotes", "database is locked", null)
      compare(store.openNotes.length, 0, "nor when the reload fails")
    }

    function test_hide_all_confirmed_marks_a_waiting_note_stacked_at_once() {
      store.stackNoteLater("n")
      store.stackAll()
      client.answer("stackAll", null, 1)
      compare(store._pendingStack.n, undefined, "covered")
      compare(store.noteById("n").piled, true, "the cache says stacked before the reload")
      compare(store.openNotes.length, 0, "no window reopens meanwhile")
      client.answer("listNotes", "database is locked", null)
      compare(store.openNotes.length, 0, "nor when the reload fails")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 0)
    }

    function test_refused_delete_after_a_reopen_landed_shows_the_note_open() {
      store.notes = { n: { id: "n", title: "", contentBlocks: "", piled: true, updatedAt: "1" } }   // body evicted, as stacked
      store._rebuild()
      store.restoreNote("n")
      client.answer("tabsFor", null, [])            // unstackNote on its way
      store.deleteNote("n")                         // queued behind it
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "full body", piled: false, updatedAt: "2" })
      compare(store.openNotes.length, 0, "no window for a note being deleted")
      client.answer("deleteNote", "database is locked", null)
      compare(store.openNotes.length, 0, "refused: the disk is read again before anything shows")
      compare(client.count("listNotes"), 1)
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "full body", piled: false, updatedAt: "9" }])
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      compare(store.noteById("n").piled, false, "the cache follows the disk, which the reopen left open")
      compare(store.noteById("n").contentBlocks, "full body", "with the helper's body, never the evicted one")
      compare(store.openNotes.length, 1)
      compare(store._landedOpen.n, undefined)
      // Deleted after all: nothing lingers.
      store.deleteNote("n")
      client.answer("deleteNote", null, true)
      compare(store.noteById("n"), null)
      compare(store._landedOpen.n, undefined)
    }

    function test_a_failed_newer_reopen_shows_what_the_older_one_opened() {
      store.notes = { n: { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "1" } }
      store._rebuild()
      store.restoreNote("n")
      client.answer("tabsFor", null, [])            // unstackNote #1 on its way
      store.restoreNote("n")                        // tabsFor #2, supersedes #1
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      compare(store.openNotes.length, 0, "the newer reopen decides; nothing shown yet")
      client.answer("tabsFor", "database is locked", null)
      compare(client.count("listNotes"), 1, "refused, but the disk is open since #1: read again")
      verify(store._landedOpen.n, "kept until that read succeeds")
      client.answer("listNotes", "database is locked", null)
      verify(store._landedOpen.n, "still kept: the read failed")
      compare(store.openNotes.length, 0)
      store.reload()                                // the next reload (the helper back, say) settles it
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "9" }])
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      compare(store.openNotes.length, 1)
      compare(store._landedOpen.n, undefined)
    }

    function test_a_landed_reopen_voids_the_stack_it_answered_but_not_a_newer_close() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", "database is locked", null)   // retry pending, tried
      store.restoreNote("n")
      client.answer("tabsFor", null, [])                        // unstackNote on its way
      store.deleteNote("n")
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      compare(store._pendingStack.n, undefined, "the stack the reopen answered is void")
      client.answer("deleteNote", "database is locked", null)
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "9" }])
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      compare(store.openNotes.length, 1)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "no retry stacks it again")
      // A close queued after the reopen keeps its own entry: the note stays
      // closed, and its delayed write still goes out.
      store.restoreNote("n")                                    // open on disk already: unsent path is not taken (no entry)
      client.answer("tabsFor", null, [])
      store.stackNoteLater("n")                                 // closed again while the unstack is on its way
      store.deleteNote("n")
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "5" })
      verify(store._pendingStack.n !== undefined, "the newer close keeps its entry")
      client.answer("deleteNote", "database is locked", null)
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "9" }])
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      verify(store._pendingStack.n !== undefined, "the reload keeps it too")
      compare(store.openNotes.length, 0, "still closed")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 2, "its own delayed write goes out")
    }

    function test_hide_all_confirmed_voids_a_landed_reopen() {
      store.notes = { n: { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "1" } }
      store._rebuild()
      store.restoreNote("n")
      client.answer("tabsFor", null, [])                        // unstackNote on its way
      store.stackAll()                                          // supersedes it
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      verify(store._landedOpen.n)
      client.answer("stackAll", null, 1)
      compare(store._landedOpen.n, undefined, "stacked on disk again: the record is void")
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "", piled: true, updatedAt: "3" }])
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      store.deleteNote("n")
      client.answer("deleteNote", "database is locked", null)
      compare(store.openNotes.length, 0, "a refused deletion does not reopen a note stacked on disk")
      compare(client.count("listNotes"), 1, "nothing to settle")
    }

    function test_overlapping_restore_alls_keep_the_newer_hold() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", "helper exited (code 1)", null)   // tried
      store.restoreAll()
      store.restoreAll()
      client.answer("restoreAll", "database is locked", null)      // the older one
      verify(store._pendingStack.n !== undefined && store._pendingStack.n.held, "still held by the newer call")
      client.answer("listNotes", "database is locked", null)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "no retry behind the newer Restore All")
      client.answer("restoreAll", null, 1)
      compare(store._pendingStack.n, undefined)
      compare(store.openNotes.length, 1)
      client.answer("listNotes", "database is locked", null)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1)
    }

    function test_the_landed_open_fallback_keeps_content_saved_since() {
      store.notes = { n: { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "1" } }
      store._rebuild()
      store.restoreNote("n")
      client.answer("tabsFor", null, [])            // unstackNote #1 on its way
      store.updateNote("n", { contentBlocks: "edited meanwhile" }); store.flush()
      store.restoreNote("n")                        // tabsFor #2
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      client.answer("updateNote", null, { id: "n", title: "", contentBlocks: "edited meanwhile", piled: false, updatedAt: "3" })
      client.answer("tabsFor", "database is locked", null)
      compare(client.count("listNotes"), 1, "open on disk since #1: read again")
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "edited meanwhile", piled: false, updatedAt: "9" }])
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      compare(store.noteById("n").piled, false)
      compare(store.noteById("n").contentBlocks, "edited meanwhile", "the disk's current body, never the older reply's")
      compare(store.openNotes.length, 1)
    }

    function test_the_landed_open_record_survives_an_older_reload_and_dies_with_the_note() {
      store.notes = { n: { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "1" } }
      store._rebuild()
      store.restoreNote("n")
      client.answer("tabsFor", null, [])            // unstackNote #1 on its way
      store.reload()                                // listNotes queued behind it
      store.restoreNote("n")                        // tabsFor #2
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "1" }])
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      verify(store._landedOpen.n, "the list was asked for before the unstack landed: the record stays")
      wait(20)
      compare(client.count("listNotes"), 2, "and a list taken after it is asked for")
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "9" }])
      client.answer("listTabs", null, []); client.answer("listSettings", null, {}); client.answer("listThemes", null, [])
      compare(store._landedOpen.n, undefined, "settled")
      compare(store.openNotes.length, 1)
      client.answer("tabsFor", "database is locked", null)
      compare(client.count("listNotes"), 2, "nothing left to settle for the refused reopen")
      store.stackNote("n")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "3" })
      store.restoreNote("n")
      client.answer("tabsFor", null, [])
      store.deleteNote("n")
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "4" })
      verify(store._landedOpen.n)
      client.answer("deleteNote", null, true)
      compare(store.noteById("n"), null)
      compare(store._landedOpen.n, undefined, "nothing kept for a deleted note")
    }

    function test_a_refused_delete_does_not_replay_a_reopen_behind_a_newer_hide_all() {
      store.notes = { n: { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "1" } }
      store._rebuild()
      store.restoreNote("n")
      client.answer("tabsFor", null, [])                        // unstackNote on its way
      store.deleteNote("n")
      store.stackAll()                                          // newer still
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      client.answer("deleteNote", "database is locked", null)
      compare(client.count("tabsFor"), 1, "no reopen replayed behind the Hide All")
      client.answer("stackAll", null, 1)
      compare(store._landedOpen.n, undefined)
      compare(store.openNotes.length, 0, "the Hide All stands")
      client.answer("listNotes", "database is locked", null)
      compare(store.openNotes.length, 0)
    }

    function test_restore_all_cancels_waiting_stacks() {
      store.stackNoteLater("n")
      store.restoreAll()
      compare(store._pendingStack.n, undefined)
      compare(store.openNotes.length, 1, "open again at once")
      client.answer("restoreAll", null, 0)
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "1" }])
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 0)
    }

    function test_waiting_stack_of_a_deleted_note_is_dropped() {
      store.stackNoteLater("n")
      store.reload()
      client.answer("listNotes", null, [])
      compare(store._pendingStack.n, undefined, "gone from the disk: nothing waits")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 0)
      // Or the helper says so when the write is attempted.
      store.notes = { n: { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "1" } }
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", "Note not found", null)
      compare(store._pendingStack.n, undefined)
      compare(store.noteById("n"), null, "the cached row goes too")
      compare(store.openNotes.length, 0, "and no window comes back for it")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "not retried")
    }

    function test_failed_reopen_after_a_sent_stack_stays_stacked() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1)
      store.restoreNote("n")
      compare(store.openNotes.length, 0, "not shown open before the disk is settled")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "2" })
      client.answer("tabsFor", "database is locked", null)
      compare(store.openNotes.length, 0, "cache and disk agree: stacked")
      compare(store.noteById("n").piled, true)
      compare(store._pendingStack.n, undefined)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "and nothing is queued again")
    }

    function test_reopen_after_a_failed_stack_is_not_optimistic() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", "helper not running", null)   // may have landed before the helper went
      verify(store._pendingStack.n !== undefined && store._pendingStack.n.sent === false, "waiting for a retry")
      store.restoreNote("n")
      compare(store.openNotes.length, 0, "shown stacked until the disk is settled")
      compare(client.count("tabsFor"), 1, "reopened the careful way")
      client.answer("tabsFor", null, [])
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "3" })
      compare(store.openNotes.length, 1)
      compare(store._pendingStack.n, undefined)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "the retry is void")
    }

    function test_stack_retry_waits_for_a_reopen_in_flight() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", "database is locked", null)   // retry pending
      store.restoreNote("n")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "no retry while the reopen is in flight")
      client.answer("tabsFor", null, [])
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "3" })
      compare(store.openNotes.length, 1)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "and none after it succeeded")
      // A failed reopen hands the retry back.
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", "database is locked", null)
      store.restoreNote("n")
      client.answer("tabsFor", "database is locked", null)
      compare(store.openNotes.length, 0)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 3, "retried once the reopen failed")
    }

    function test_closed_again_during_a_slow_reopen_is_still_stacked() {
      store.stackNoteLater("n")
      store.restoreNote("n")                     // unstackNote pending, helper slow
      store.stackNoteLater("n")                  // closed again meanwhile
      compare(store.openNotes.length, 0)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 0, "not while the reopen is in flight")
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      compare(store.openNotes.length, 0, "the stale reopen reply changes nothing")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "the waiting stack goes once the reopen settled")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "3" })
      compare(store.noteById("n").piled, true)
      compare(store._pendingStack.n, undefined)
    }

    function test_reopen_after_a_sent_stack_voids_a_late_stack_reply() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      store.restoreNote("n")
      client.answer("tabsFor", null, [])
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "3" })
      compare(store.openNotes.length, 1)
      compare(store._pendingStack.n, undefined, "the waiting entry is void")
      client.answer("stackNote", "database is locked", null)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "a failed late stack is not retried")
      compare(store.openNotes.length, 1)
    }

    function test_hide_during_a_reopen_wins() {
      store.stackNoteLater("n")
      store.restoreNote("n")
      compare(store.openNotes.length, 1, "reopened at once, its unstack on its way")
      store.stackNote("n")                       // the user hides it again meanwhile
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      compare(store.openNotes.length, 1, "the reopen's reply is stale and changes nothing")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "3" })
      compare(store.openNotes.length, 0, "the hide, the newer action, stands")
      compare(store.noteById("n").piled, true)
    }

    function test_delete_during_a_reopen_abandons_it() {
      store.notes = { n: { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "1" } }
      store._rebuild()
      store.restoreNote("n")
      store.deleteNote("n")
      client.answer("deleteNote", null, true)
      client.answer("tabsFor", null, [])
      compare(client.count("unstackNote"), 0)
      compare(store.noteById("n"), null)
    }

    function test_restore_all_abandons_a_reopen_in_flight() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1)
      store.restoreNote("n")                     // tabsFor on its way
      store.restoreAll()
      client.answer("tabsFor", "database is locked", null)
      verify(store._pendingStack.n !== undefined, "the sent stack may have landed: shown stacked until Restore All is confirmed")
      compare(store.openNotes.length, 0)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "the failed reopen does not re-queue a stack after Restore All")
      client.answer("restoreAll", null, 1)
      compare(store._pendingStack.n, undefined, "confirmed: nothing waits")
      compare(store.openNotes.length, 1)
      client.answer("listNotes", "database is locked", null)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "and nothing stacks it again")
    }

    function test_an_older_reopen_ending_keeps_the_newer_reopens_guard() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", "database is locked", null)   // retry pending
      store.restoreNote("n")                     // tabsFor #1
      store.restoreNote("n")                     // tabsFor #2 supersedes it
      compare(client.count("tabsFor"), 2)
      client.answer("tabsFor", null, [])         // #1 ends, superseded
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "the retry stays off while the newer reopen is in flight")
      client.answer("tabsFor", null, [])
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "3" })
      compare(store.openNotes.length, 1)
      compare(store._pendingStack.n, undefined)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "and never after it")
    }

    function test_hide_all_leaves_a_close_queued_after_it_alone() {
      store.notes = { n: { id: "n", title: "", contentBlocks: "", piled: false, updatedAt: "1" }, o: { id: "o", title: "", contentBlocks: "", piled: false, updatedAt: "1" } }
      store._rebuild()
      store.stackNoteLater("o")
      store.stackAll()                           // covers o
      store.restoreAll()                         // o is open on disk after this
      store.stackNoteLater("n")                  // closed again, behind both
      verify(store._pendingStack.o !== undefined && store._pendingStack.o.held !== undefined, "covered by the bulk stack, which may land: held until confirmed")
      client.answer("stackAll", null, 2)
      compare(store._pendingStack.o, undefined, "the bulk stack confirmed it")
      verify(store._pendingStack.n !== undefined, "the bulk stack did not cover a close queued after it")
      compare(store.openNotes.length, 0, "n waiting, o stacked on disk by the bulk write until the Restore All's reload says otherwise")
      client.answer("listNotes", "database is locked", null)
      client.answer("restoreAll", null, 2)
      client.answer("listNotes", "database is locked", null)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 1, "its own delayed write still goes out")
      compare(client.next("stackNote").args.noteId, "n")
    }

    function test_restore_all_keeps_an_attempted_stack_until_confirmed() {
      store.stackNoteLater("n")
      wait(store.stackDelayMs + 60)
      client.answer("stackNote", "helper exited (code 1)", null)   // may have landed
      store.restoreAll()
      verify(store._pendingStack.n !== undefined && store._pendingStack.n.held, "held, shown stacked")
      compare(store.openNotes.length, 0)
      client.answer("restoreAll", "helper not running", null)
      client.answer("listNotes", "helper not running", null)
      verify(store._pendingStack.n !== undefined && store._pendingStack.n.held === false, "handed back to the timer")
      compare(store.openNotes.length, 0, "cache and disk agree: stacked")
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 2, "retried")
      client.answer("stackNote", null, { id: "n", title: "", contentBlocks: "original", piled: true, updatedAt: "2" })
      compare(store._pendingStack.n, undefined)
      store.restoreAll()
      client.answer("restoreAll", null, 1)
      client.answer("listNotes", null, [{ id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "3" }])
      client.answer("listTabs", null, [])
      client.answer("listSettings", null, {})
      client.answer("listThemes", null, [])
      compare(store.openNotes.length, 1)
    }

    function test_failed_reopen_before_the_stack_was_sent_stays_open() {
      store.stackNoteLater("n")
      store.restoreNote("n")
      client.answer("unstackNote", "database is locked", null)
      compare(store.openNotes.length, 1, "nothing reached the disk: still open there too")
      compare(store._pendingStack.n, undefined)
      wait(store.stackDelayMs + 60)
      compare(client.count("stackNote"), 0)
    }

    function test_reopen_while_waiting_keeps_tabs_made_meanwhile() {
      store.tabs = { n: [{ id: "t", noteId: "n", position: 1, icon: "", contentBlocks: "[t]" }] }
      store._tabNote = { t: "n" }
      store.stackNoteLater("n")
      store.restoreNote("n")
      compare(client.count("tabsFor"), 0, "the cache never lost the tabs: nothing to fetch")
      compare(store.tabsFor("n").length, 1)
      store.createTab("n")                       // made in the window that is open again
      client.answer("createTab", null, { id: "u", noteId: "n", position: 2, icon: "", contentBlocks: "[]" })
      client.answer("unstackNote", null, { id: "n", title: "", contentBlocks: "original", piled: false, updatedAt: "2" })
      compare(store.tabsFor("n").length, 2, "the new tab survives the reopen")
      compare(store.openNotes.length, 1)
      compare(store._restoring.n, undefined)
    }

    function test_teardown_never_writes_a_waiting_stack() {
      var other = storeComponent.createObject(null, { client: client, stackDelayMs: 40 })
      other.notes = { m: { id: "m", title: "", piled: false, updatedAt: "1" } }
      other._rebuild()
      other.stackNoteLater("m")
      other.destroy()
      wait(120)
      compare(client.count("stackNote"), 0, "a session that ends first leaves the note open on disk")
    }
  }

  Component { id: storeComponent; NotesStore {} }
}
