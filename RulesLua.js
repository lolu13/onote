// Lua for `hyprctl eval`, built from stored note rows. Pure functions, kept
// out of WorkspaceRules.qml so the grammar can be tested without Quickshell.
.pragma library

// Everything interpolated into Lua below comes from stored rows, so each
// value is forced into a closed grammar first: ids are 12 lowercase hex
// chars (anything else yields "" and the note gets no rule), numbers are
// finite integers in a fixed range, workspace names are a small character
// set. Nothing can close a Lua string or add a statement.
// 12 hex chars of the UUID: safe inside a regex and in a window title.
function shortId(noteId) {
  var s = String(noteId === undefined || noteId === null ? "" : noteId).replace(/-/g, "").slice(0, 12)
  return /^[0-9a-f]{12}$/.test(s) ? s : ""
}
function tag(noteId) { return "[dn:" + shortId(noteId) + "]" }
// Lua source for the title regex: the Lua string "\\[" is the regex "\[".
function titlePattern(noteId) { return ".*\\\\[dn:" + shortId(noteId) + "\\\\].*" }
function windowSelector(noteId) { return "title:" + titlePattern(noteId) }

// A finite integer clamped into [lo, hi], else the fallback.
function int(v, lo, hi, fallback) {
  var n = Number(v)
  if (!isFinite(n)) return fallback
  return Math.max(lo, Math.min(hi, Math.round(n)))
}

// Workspace selector for a rule: numeric ids, "special:x", or a named workspace.
function workspaceSelector(note) {
  var name = String(note.workspaceName || "")
  if (name.length > 64 || name === "special:" || !/^[A-Za-z0-9 _.:+-]*$/.test(name)) name = ""
  if (/^-?\d{1,9}$/.test(name) || name.indexOf("special:") === 0) return name
  if (name.length) return "name:" + name
  return String(int(note.workspaceId, -999999, 999999, 0))
}

function _rule(name, noteId) {
  return 'hl.window_rule({ name = "' + name + '-' + shortId(noteId) + '", '
    + 'match = { class = "^org.quickshell$", title = "' + titlePattern(noteId) + '" }'
}

// Lua for one note: enable the rule for its mode, disable the other.
function ruleLua(note) {
  var ws = _rule("dn", note.id), pin = _rule("dnp", note.id)
  if (note.pinned === true) {
    var w = int(note.width, 200, 16384, 300), h = int(note.height, 150, 16384, 350)
    var x = int(note.positionX, -65536, 65536, 0), y = int(note.positionY, -65536, 65536, 0)
    return ws + ' }):set_enabled(false)\n' + pin
      + ', float = true, pin = true, size = { ' + w + ', ' + h + ' }, move = { ' + x + ', ' + y + ' }, no_initial_focus = true })'
  }
  return pin + ' }):set_enabled(false)\n' + ws
    + ', workspace = "' + workspaceSelector(note) + ' silent", no_initial_focus = true })'
}

// Dispatchers that pin (float at the note's own size, pin, raise) or unpin
// (tile again) one live window. Several dispatchers need one `hyprctl eval`.
//
// The caller passes the selector, not a note id: a title selector would act on
// any window whose own title carries the tag, so dispatchers address the one
// toplevel the caller resolved (title tag AND class org.quickshell) by its
// Hyprland address. Anything but "address:0x<hex>" yields "" and no dispatch.
function pinScript(selector, on, width, height) {
  if (!/^address:0x[0-9a-f]+$/.test(String(selector))) return ""
  var sel = '"' + selector + '"'
  if (on) return 'hl.dispatch(hl.dsp.window.float({ action = "enable", window = ' + sel + ' }))\n'
    + 'hl.dispatch(hl.dsp.window.resize({ window = ' + sel + ', x = ' + int(width, 200, 16384, 300) + ', y = ' + int(height, 150, 16384, 350) + ' }))\n'
    + 'hl.dispatch(hl.dsp.window.pin({ action = "enable", window = ' + sel + ' }))\n'
    + 'hl.dispatch(hl.dsp.window.alter_zorder({ window = ' + sel + ', mode = "top" }))'
  return 'hl.dispatch(hl.dsp.window.pin({ action = "disable", window = ' + sel + ' }))\n'
    + 'hl.dispatch(hl.dsp.window.float({ action = "disable", window = ' + sel + ' }))'
}
