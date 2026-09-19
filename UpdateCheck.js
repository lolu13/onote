// Pure parts of the update check, kept out of UpdateCheck.qml so they run
// under qmltestrunner (Quickshell.Io is compiled into the shell).
.pragma library

// `git rev-list --left-right --count HEAD...refs/onote/check` prints "<behind>\t<ahead>"
// from origin's point of view: commits only we have, then commits only origin
// has. The updater fast-forwards, so only "0 <n>" with n > 0 is an update; a
// checkout that is ahead or diverged counts as current. Anything else printed
// is not trusted: "unknown".
function verdict(out) {
  var m = /^\s*(\d{1,9})\s+(\d{1,9})\s*$/.exec(String(out))
  if (!m) return "unknown"
  var ours = Number(m[1]), theirs = Number(m[2])
  return ours === 0 && theirs > 0 ? "update" : "current"
}

// The checkout can be newer than the helper last built and installed from it
// (`omarchy plugin update` run on its own fast-forwards the plugin files and
// leaves the helper): `head` is `git rev-parse HEAD`, `installJson` the text
// of install.py's state file. True only when both name a commit and differ;
// a copy that is not a checkout (no commit recorded) has nothing to compare.
function installedBehind(head, installJson) {
  var h = String(head === undefined || head === null ? "" : head).trim()
  if (!/^[0-9a-f]{40}$/.test(h)) return false
  var installed = ""
  try {
    var o = JSON.parse(String(installJson === undefined || installJson === null ? "" : installJson))
    installed = o && typeof o.installed === "string" ? o.installed : ""
  } catch (e) { return false }
  return /^[0-9a-f]{40}$/.test(installed) && installed !== h
}

// `git rev-parse --git-dir` run inside the plugin directory answers ".git"
// only when that directory is the repository itself; an enclosing repository
// (a git-managed ~/.config around a copied install) answers with a path.
function ownCheckout(out) { return String(out).trim() === ".git" }

// Bounded, single-line summary for `onote checkUpdate` and `status`.
function describe(status, checkedAt) {
  var when = checkedAt ? " (checked " + checkedAt + ")" : ""
  switch (status) {
  case "update": return "update available" + when
  case "current": return "up to date" + when
  case "checking": return "checking"
  case "unsupported": return "not a git checkout: install with `omarchy plugin add` to get update checks"
  case "error": return "check failed" + when
  default: return "not checked yet"
  }
}
