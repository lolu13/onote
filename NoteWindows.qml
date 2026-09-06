// One NoteWindow per open note. The model is the list of open note IDS (plain
// strings) so content edits never recreate windows; only opening or stacking
// a note changes the list.
//
// A note that remembers a workspace is held back until its Hyprland rule
// exists (WorkspaceRules), so the window maps directly onto that workspace.
import QtQuick
import Quickshell
import Quickshell.Hyprland

Item {
  id: root
  property var store: null
  property var service: null

  // Both are keyed by note id, so neither carries Object.prototype: an id like
  // "__proto__" must not read back as ready or followed when it was never set.
  property var follow: Object.create(null)    // noteId -> true: focus the window once Hyprland maps it
  property var _ready: Object.create(null)    // noteId -> true once its workspace rule exists (or none is needed)

  WorkspaceRules {
    id: rules
    onPlaced: function(ids) {
      var open = root._openIds()
      var ready = Object.create(null)
      for (var k in root._ready) ready[k] = true
      for (var i = 0; i < ids.length; i++) if (open.indexOf(ids[i]) !== -1) ready[ids[i]] = true
      root._ready = ready
    }
  }

  Variants {
    id: variants
    onModelChanged: console.log("desknotes: window model =", JSON.stringify(model))
    model: {
      var ids = root._openIds()
      var shown = []
      for (var i = 0; i < ids.length; i++) if (root._ready[ids[i]]) shown.push(ids[i])
      return shown
    }
    delegate: Component {
      NoteWindow {
        required property var modelData
        noteId: modelData
        store: root.store
        service: root.service
        windows: root
      }
    }
  }

  Connections {
    target: root.store
    function onOpenNotesChanged() { root._sync() }
  }

  // Quickshell learns about moved, pinned or floated windows only when asked.
  Connections {
    target: Hyprland
    function onRawEvent(e) {
      switch (e.name) {
      case "movewindowv2": case "movewindow": case "openwindow":
      case "pin": case "changefloatingmode": case "workspacev2":
        Hyprland.refreshToplevels()
      }
    }
  }

  function _openIds() {
    var open = root.store ? root.store.openNotes : []
    var ids = []
    for (var i = 0; i < open.length; i++) ids.push(open[i].id)
    return ids
  }

  // Rebuild the ready set from the open list so a note that was stacked and
  // reopened gets its rule registered again with the latest workspace.
  function _sync() {
    var open = root.store ? root.store.openNotes : []
    var ready = Object.create(null)
    var need = []
    for (var i = 0; i < open.length; i++) {
      var n = open[i]
      if (root._ready[n.id]) { ready[n.id] = true; continue }
      if (!n.workspaceId && n.pinned !== true) ready[n.id] = true   // new note: open where focus is
      else need.push(n)
    }
    root._ready = ready
    if (need.length) rules.ensure(need)
  }

  function tag(noteId) { return rules.tag(noteId) }

  // Reopen a stacked note and take the user to it, wherever it lives.
  function openAndFollow(noteId) {
    var f = Object.create(null)
    for (var k in root.follow) f[k] = true
    f[noteId] = true
    root.follow = f
    if (root.store) root.store.restoreNote(noteId)
  }

  // The tag in a window title is not proof of ownership: any window can put
  // "[dn:<id>]" in its own title. A dispatcher therefore acts on the toplevel
  // that carries the tag AND our class, addressed by its Hyprland address.
  function _toplevel(noteId) {
    if (!rules.shortId(noteId)) return null
    var tag = rules.tag(noteId)
    var v = Hyprland.toplevels.values
    for (var i = 0; i < v.length; i++) {
      var info = v[i].lastIpcObject
      if (v[i].title.indexOf(tag) !== -1 && info && info["class"] === "org.quickshell") return v[i]
    }
    return null
  }

  // "" when the window is not (yet) mapped or its address is not plain hex.
  function _selector(noteId) {
    var t = root._toplevel(noteId)
    if (!t) return ""
    var hex = String(t.address || "").replace(/^0x/, "")
    if (!/^[0-9a-f]{1,16}$/.test(hex)) return ""
    return "address:0x" + hex
  }

  function focusNote(noteId) {
    var sel = root._selector(noteId)
    if (!sel) { console.warn("desknotes: no window of ours for note", rules.shortId(noteId)); return }
    Quickshell.execDetached(["/usr/bin/hyprctl", "dispatch",
      'hl.dsp.focus({ window = "' + sel + '" })'])
  }

  function setPinned(noteId, on, width, height) {
    var sel = root._selector(noteId)
    if (!sel) { console.warn("desknotes: no window of ours for note", rules.shortId(noteId)); return }
    var script = rules.pinScript(sel, on, width, height)
    if (!script.length) return
    Quickshell.execDetached(["/usr/bin/hyprctl", "eval", script])
  }

  // Pin or unpin the focused window if it is one of our notes.
  function togglePinFocused() {
    var t = Hyprland.activeToplevel
    if (!t) return "no focused window"
    // Title tag plus our own class: a foreign window that copies the tag into
    // its title must not make the plugin pin it.
    var info = t.lastIpcObject
    if (!info || info["class"] !== "org.quickshell") return "focused window is not a note"
    var inst = variants.instances
    for (var i = 0; i < inst.length; i++)
      if (t.title.indexOf(inst[i].tag) !== -1) { inst[i].togglePin(); return "ok" }
    return "focused window is not a note"
  }

  function didFollow(noteId) {
    var f = Object.create(null)
    for (var k in root.follow) if (k !== noteId) f[k] = true
    root.follow = f
  }
}
