.pragma library
// The reopen bookkeeping of NoteWindows, kept free of Quickshell so the test
// suite can run it. `follow` maps a note id to the token of the reopen that
// wants its window focused once Hyprland maps it. The maps carry no
// Object.prototype: an id like "__proto__" must not read back as followed.

function withMark(follow, id, token) {
  var f = Object.create(null)
  for (var k in follow) f[k] = follow[k]
  f[id] = token
  return f
}

function without(follow, id) {
  var f = Object.create(null)
  for (var k in follow) if (k !== id) f[k] = follow[k]
  return f
}

// A note has a window to focus only while the store does not show it stacked:
// one closed moments ago (stackNoteLater) still reads piled === false, has no
// window, and must be reopened instead.
function hasWindow(store, note) { return !!note && !store.isStacked(note) }

// restoreNote has answered. No window will map after an error, or after a
// reopen that a newer stack, hide or delete cancelled (no note in the reply):
// this reopen's marker goes, never one a newer reopen of the note set since.
function ended(follow, id, token, err, note) { return (!!err || !note) && follow[id] === token }
