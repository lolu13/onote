# Onote design notes

How Onote is built and why. The README covers installing and using it; this file is for whoever
changes the code.

Onote is an Omarchy **shell plugin**: notes are drawn by `omarchy-shell` (Quickshell) itself.
There is no browser engine and no separate app process, only a small Rust helper that owns the
notes database.

## What you get

- Each open note is an ordinary window that Hyprland tiles, floats, moves and resizes.
- Closing a note (Super+W or Ctrl+W) saves it to the **stack**; nothing is deleted by closing.
- **Notes & Stack** (Super+N): every note, open or stacked, with title and full-text search,
  keyboard selection, restore, and confirmed delete.
- Bar button: left click opens Notes & Stack, middle click creates a note, right click stacks all.
- Blocks: text, heading, bullet, to-do, label, code, divider, and images (Ctrl+V pastes a clipboard image).
- Skins: **System** follows the Omarchy theme live; the seven built-in palettes and your saved
  custom skins still work (Ctrl+Shift+T cycles).
- Square corners everywhere, a static accent frame, no glow, no animations, no polling.

Not in this edition (yet): opacity, zoom, icon packs, pile mode, the theme editor
window, the theme editor, the Ctrl+Space app menu. Notes created with those features keep their
data in the database; the Omarchy edition simply does not edit them.

## How it is built

```
helper/    onote-helper (Rust). One process, one SQLite connection, JSON lines on stdio.
           helper/src/db.rs: schema, migrations, 5 MB cap, FTS5 index.
*.qml      Service.qml (helper client, notes cache, note windows, "onote" IPC target),
           Library.qml (overlay), BarWidget.qml, NoteWindow.qml, BlockEditor.qml, blocks/*.
hypr/      Window rule + Super bindings.
scripts/   install.py, uninstall.py, update.py, test-qml.py, test-workspace-rules.py.
```

Note windows have class `org.quickshell` (Quickshell cannot set a per-window app id), so the
Hyprland rule matches the title suffix ` — Onote [dn:<first 12 hex chars of the note id>]`.
Never write a rule on the class alone; other shell windows share it. Hyprland regexes are
full-match, and in Lua mode dispatchers must use the `hl.dsp.*` table syntax, not the classic
`focuswindow title:...` strings.

Notes remember their workspace. Hyprland is the source of truth: each window mirrors its own
`Hyprland.toplevels` entry into `workspace_id` / `workspace_name` (`NoteWindow.qml`), so moving
a note with Super+Shift+number is saved. Before a remembered note is opened, `WorkspaceRules.qml`
registers a named rule `dn-<tag>` via `hyprctl eval` (`workspace = "N silent"`,
`no_initial_focus`), and `NoteWindows.qml` only creates the window once that rule exists, so the
note maps straight onto its workspace with no hop. Opening a note from the library focuses it
with `hl.dsp.focus`, which switches to its workspace. Rules are never removed: re-registering a
name updates it, and a workspace rule only matters while a window opens.

Open notes reopen at login. The shell starts the plugin with the session, and every note the
database still has open maps onto its workspace through the rules above. What kept them from
coming back was Omarchy itself: `omarchy-system-shutdown`, `-reboot` and `-logout` run
`omarchy-hyprland-window-close-all` about 2 s before the session ends, and a close request used
to stack the note at once. A window the compositor closes (that, or Super+W) now goes through
`NotesStore.stackNoteLater`: the note leaves the screen and joins the stack in the UI at once
(`_pendingStack`, read by `isStacked`), but `stackNote` reaches the helper only once no
window has closed for `stackDelayMs` (10 s). A session that ends first leaves it open on disk;
the teardown flush sends content only, never a waiting stack. The cached row keeps `piled = false` meanwhile, so content
saves (the helper's `updateNote` writes `piled`) cannot stack it early. Reopening the note, stack
all, restore all and delete cancel the wait; a late `stackNote` reply for a reopened note is
ignored. Explicit hides (Super+Alt+H, the menu's Hide, closing the last tab, hide all) stack
immediately. Cost: a note closed less than 10 s before a shell restart comes back.

Omarchy's scratchpad (`special:scratchpad`, Super+S / Super+Alt+S) is the notes drawer: a note sent
there is remembered as `workspace_name = special:scratchpad`, the rule reopens it there without
showing the scratchpad, focusing it from the library opens the scratchpad, and a note created
while the scratchpad is open lands in it. The library labels notes `scratchpad` / `open on N`.

Pinned notes reuse the DeskNotes desktop edition's columns `pinned`, `position_x/y`, `width/height`. Ctrl+Shift+P or
`onote pinNote` (Super+Alt+P) floats the window at the note's own size, pins and raises it;
Omarchy's Super+O works too. `NoteWindow.qml` mirrors `pinned`, `at` and `size` from its
`lastIpcObject` (refreshed on pin/float/workspace events and a 3 s tick while pinned, since drags
send no event) and pauses workspace memory while pinned. On open the rule `dnp-<tag>` restores
`float`, `pin`, `size`, `move`. Re-registering a named rule merges keys, so `dn-` and `dnp-` are
separate names and the inactive one is disabled. Positions are global pixels: single monitor.

Edits are batched: typing only updates an in-memory model; the note JSON is built once on the
500 ms save timer (`autoSaveInterval` setting), on focus loss, on close and on Ctrl+S. The helper
writes through the same `update_note` path as the DeskNotes desktop edition. Positions are never persisted
(the compositor owns them); width and height are saved on close, the workspace whenever it changes.

After editing plugin QML, run `python3 scripts/install.py --sync`. The shell's hot reload
does not refresh already-loaded QML, so a shell restart is required. See the
[README](../README.md) for the protocol and [CONTRIBUTING.md](CONTRIBUTING.md) for the tests.

## Tabs

A note can have several pages. Tab 1 is the note itself (`notes.content_blocks`, `notes.tab_icon`),
so previews, the DeskNotes desktop edition and old notes are untouched; extra tabs are rows in `note_tabs`
(schema v11, deleted with the note, positions kept contiguous) with their own FTS index that
`searchNoteIds` merges after the note hits. The shell caches all tabs at startup (`listTabs`)
and writes through `createTab` / `updateTab` / `deleteTab`. One `BlockEditor` per window shows
the active tab; `BlockEditor.tabId` decides whether a flush goes to the note or a tab. Keys are
browser-like (Ctrl+T, Ctrl+W, Ctrl+Tab, Ctrl+1…9); Ctrl+W on the last tab stacks the note. Tab
icons are Nerd Font glyphs, the set the shell draws with; Ctrl+Shift+I or right-click opens the
picker. Markdown export writes each extra tab after a `---` with an `<!-- tab N -->` marker.

## First launch

With no notes in the database the service asks the helper for `ensureWelcomeNote`, which creates
"Welcome to Onote": pinned (so it floats on every workspace), near the top-right of the
focused monitor, listing the most-used keys as label blocks plus a "try it" checklist
(`helper/src/welcome.rs`, keep in step with `KEYBINDINGS.md`). It happens once (`welcomeCreated`
setting); `onote welcome` recreates it on demand.

## Settings

Ctrl+, in the library or a note (or `onote settings`) shows the Settings view inside the
library overlay: default note width/height, text size for new notes (`onote.defaultFontSize`, a key of its own because the desktop edition stores its own 15 px default under `defaultFontSize` in the shared database; unset means a note follows `Style.font.body`, the shell's `[font] base-size`, so notes track `omarchy font size`), autosave delay, theme for new notes and the Markdown mirror folder.
Arrows change values (`app_settings` written through `setSetting`), Enter edits the folder and
enables the mirror through `setMirrorDir`. Esc returns to the notes list.

## Markdown mirror and export

The mirror folder is set in Settings (Ctrl+, → Markdown mirror folder); the IPC method takes no
path, because a parameterised path would let anything on the session make the plugin write every
note into a folder of its choosing. `omarchy-shell onote mirror` just opens that view, and
`onote mirrorStatus` reports the state. Once set, every note is written as `<title>.md`
(front matter `id`, `created`, `updated`; body from `note_with_tabs_to_markdown`) into that folder
and kept current on every save, tab change, rename (old file removed, tracked in `mirror_files`,
schema v12) and delete. Two notes with one title get the id appended to the second. The mirror
is one-way: files are never read back and edits made in them are overwritten. Clearing the folder
in Settings stops writing and leaves the files. Writes are best effort and logged; enabling fails
loudly if the folder cannot be written. Deleting a note from the DeskNotes desktop edition does not remove
its mirror file.

In the library, Ctrl+E copies the selected note as Markdown (`wl-copy`) and Ctrl+Shift+E saves
it to `~/Documents/Onote/<title>.md`. Super+Alt+V creates a note from the clipboard text
(`wl-paste -t text`, one text block per line).

## Data

The database is `~/.local/share/com.desknotes.omarchy/desknotes.db`, unchanged from the DeskNotes desktop
edition. Stacked notes are rows with `piled = 1`. Both editions can read the same file, but only
one should run at a time; the installer stops the DeskNotes desktop app before installing.

## Validation

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full list of checks.

## Resource use

Measured on the development machine, PSS (shared memory apportioned, so figures are additive).
Baseline is `omarchy-shell` with this plugin disabled; the shell runs anyway.

| State | Shell PSS | Plugin cost | Helper |
| --- | --- | --- | --- |
| Shell alone, plugin disabled | 383 MB | — | not running |
| Plugin loaded, no notes open | 387 MB | 4 MB | 1.6 MB |
| Six notes open | 418 MB | 35 MB | 1.7 MB |

About 5 MB per open note, and 0.0% CPU on both processes while notes sit open and idle.
For comparison, the DeskNotes desktop edition cost 395 MB of its own (143 MB host plus 252 MB WebKit)
for five notes, on top of the same shell.

## Update check and update

`UpdateCheck.qml` (Service-owned) runs `/usr/bin/git` in the plugin's own directory (`Qt.resolvedUrl(".")`):
`rev-parse --git-dir` on every run (anything but `.git`, a failure or an enclosing repository's path, means
"not a checkout of its own" for this run; nothing is cached, so a transient failure never latches and a
`.git` removed later is noticed),
then `fetch --no-tags --no-write-fetch-head origin +HEAD:refs/onote/check` (a private ref: the check must never
move the `FETCH_HEAD` that `omarchy plugin update` diffs and then merges while the user reads the diff) and
`rev-list --left-right --count HEAD...refs/onote/check`: only
"0 <n>" with n > 0, a strict fast-forward, counts as an update. Hooks and fsmonitor are disabled, the environment is
`HOME`, `PATH=/usr/bin`, `GIT_TERMINAL_PROMPT=0`, batch-mode ssh; 60 s deadline, TERM then KILL, 4 KiB
output cap. The pure parts (`UpdateCheck.js`: id grammar, verdict, status text) are covered by
`tests/tst_update_check.qml`. Timer: 30 s after start, then every 6 h. `Service.updateAvailable` drives an
`UpdateBadge` (red square, bottom-right, hover hint, `tests/tst_update_badge.qml`) in every `NoteWindow`;
a click or `omarchy-shell onote update` opens a floating Omarchy terminal (`uwsm-app -- xdg-terminal-exec
--app-id=org.omarchy.terminal -e python3 -I <dir>/scripts/update.py`), where `update.py` (which refuses to run
anywhere but the installed plugin directory) runs `omarchy plugin update` (Omarchy's own diff-and-confirm),
`cargo build --release --locked --target-dir ~/.cache/onote/cargo-target` (the shell's plugin watcher
reloads on every file written inside the plugin directory) and `scripts/install.py --helper <that binary>`
in place; without `--helper`, `install.py` takes the newest build of the tree being installed (the cache-dir build
counts only when that tree is the installed plugin itself, the only tree `update.py` builds), so a later
flagless run neither reinstalls a stale binary nor pairs another checkout's helper with this QML. `install.py` no longer copies the tree over itself when run from the
installed checkout (that dropped `.git`); a copy from elsewhere keeps only the destination's build output
(`PLUGIN_KEEP`) and deliberately not its `.git`, so a dev `--sync` from a development checkout turns the installed
plugin back into a plain copy with no update check (git over foreign files would offer updates the
updater cannot apply); the
`--no-shortcuts` choice and the installed commit are recorded in `~/.local/state/onote/install.json`;
flagless re-installs reuse the choice, and `update.py` compares HEAD with the installed commit (not with
HEAD before the merge), so a merge whose build or install failed is finished on the next run. `omarchy-shell onote checkUpdate` forces a check; `status` carries
`update`.

Tabs: the active tab is remembered per note as the setting `note.<id>.activeTab` (the tab id, `main` for
tab 1, like the other per-tab keys) by `NoteOptions.rememberTab`/`savedTab`, written on every user switch
and applied once per window: directly, with a single editor load, when the store is already `ready`, else on
the store's `resynced` (at shell start windows exist before tabs and settings have arrived); a tab that is
gone means tab 1. Text size: new notes read `onote.defaultFontSize`
(unset = the shell's `Style.font.body`), not the desktop edition's `defaultFontSize`.
