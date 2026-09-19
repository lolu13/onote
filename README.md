# Onote for Omarchy

Onote (formerly the Omarchy edition of DeskNotes): sticky notes as ordinary Hyprland windows, drawn by `omarchy-shell` itself. No browser engine,
no app process: the shell renders every note, and a small Rust helper owns the SQLite database.

- Each open note is a normal window that Hyprland tiles, floats, moves and resizes.
- Closing a note (Super+W) puts it in the **stack**; nothing is deleted by closing.
- Notes left open reopen on their own workspaces after a reboot, shutdown or logout, so you pick up where you left off.
- **Notes & Stack** (Super+N): every note with full-text search, restore, and confirmed delete.
- Blocks: text, heading, bullet, to-do, label, code, divider, and pasted images.
- Tabs inside a note, pinned notes that follow you across workspaces, a bar button.
- Skins: **System** follows the Omarchy theme live; seven built-in palettes and saved custom ones.
- An optional one-way Markdown mirror of every note into a folder of your choice (an Obsidian vault, say).

Idle cost measured on a 383 MB shell: about 4 MB with the plugin loaded, about 5 MB per open note,
no CPU while idle.

## Requirements

- Omarchy with `omarchy-shell` (Quickshell 0.3 or newer).
- A Rust toolchain (`rustup`, or `mise exec rust@stable -- cargo ...`) to build the helper once.
- `wl-clipboard` (`wl-paste`, `wl-copy`) for clipboard capture and copy; it ships with Omarchy.

## Install

```sh
omarchy plugin add https://github.com/lolu13/onote.git
cd ~/.config/omarchy/plugins/io.github.lolu13.onote
cargo build --release --manifest-path helper/Cargo.toml
python3 scripts/install.py
```

`omarchy plugin add` copies this repository verbatim. The install script then:

1. checks that Super+N, Super+Alt+N, Super+Alt+V, Super+Alt+H, Super+Alt+Shift+H and Super+Alt+P are free (pass
   `--no-shortcuts` to keep your own bindings),
2. writes `~/.config/hypr/onote.lua` (one window rule, six bindings) and one `dofile` line at the end of
   `~/.config/hypr/bindings.lua`, validated with `hyprctl configerrors` and rolled back on any error,
3. copies the built helper to `~/.local/bin/onote-helper`, a launcher entry to
   `~/.local/share/applications/onote.desktop` and an icon to `~/.local/share/icons/hicolor/128x128/apps/`,
4. enables the plugin and restarts the shell.

Every file it replaces is backed up first under `~/.local/state/onote/install-backups/`.
If you had the earlier Tauri-based DeskNotes installed, its binary and launcher entry are retired the same way;
the notes database is shared and never touched.

The helper is built from the source in `helper/` on your machine; no binary is shipped or downloaded
(`cargo` fetches the crates pinned in `Cargo.lock` from crates.io for the build). `onote-helper` must
stay in `~/.local/bin` because the shell watches the plugin directory (a binary written there would
reload the plugin) and `omarchy plugin remove` deletes it.

## Use

| Action | Keys |
| --- | --- |
| Notes & Stack | Super+N |
| Update Onote (a red square in a note's bottom-right corner means a newer commit is published) | click the square, or `omarchy-shell onote update` |
| Commands: type to search, arrows/Tab select, Enter run, Esc cancel | Ctrl+K or F1 |
| Cycle focus: title → lock → columns → tab bar → editor | F6 / Shift+F6 |
| Focus and select the title | Ctrl+L |
| Cycle column layout forward / backward | Ctrl+J / Ctrl+Shift+J |
| Focus adjacent column / first or last block | Alt+Left/Right / Ctrl+Home/End |
| New note | Super+Alt+N, or Ctrl+N inside a note |
| New note from the clipboard text | Super+Alt+V |
| Hide the focused note to the stack | Super+Alt+H |
| Hide all open notes to the stack | Super+Alt+Shift+H |
| Pin the focused note on every workspace | Super+Alt+P, or Ctrl+Shift+P inside it |
| Save and close to the stack | Super+W or Ctrl+W |
| Settings (sizes, text size, autosave, skin, mirror folder) | Ctrl+, in a note or the library |
| Tabs | Ctrl+T new, Ctrl+Tab next, Ctrl+1…9 jump, Ctrl+Shift+I icon |
| Paste an image (PNG, JPEG or GIF, up to 2 MB, 20 per note) | Ctrl+V |
| Copy the selected note as Markdown / save it to `~/Documents/Onote/` | Ctrl+E / Ctrl+Shift+E in the library |

Bar button: left click opens Notes & Stack, middle click creates a note, right click stacks all.
Tab labels are independent of titles: double-click a tab or press **F2** to rename it.
Press Enter to save, Escape to cancel, or save an empty name to restore its number.
Each tab remembers its own title while the title is unlocked. Click **Lock** beside the title
to keep the current title fixed across tabs; click **Locked** to return to individual titles.
The **1 column / 2 columns / 3 columns** button cycles the active tab's saved layout.
Blocks flow down each column in order, and headings stay with the following block.
Keyboard navigation follows Omarchy's modifier pattern: Super controls the desktop;
Ctrl controls the note (Ctrl+K commands echoes Super+K keybindings, Ctrl+J columns echoes
Super+J split). F6 visits every header control with a visible focus outline. Use Enter or
Space on the lock/layout buttons, and Left/Right then Enter on the tab bar. Escape returns
to editing. Tab/Shift+Tab moves among text blocks; in a label it also visits the badge name.
Code keeps Tab/Shift+Tab for indent/unindent; F6 always leaves the editor. Alt+Up/Down moves
blocks. In the library, Tab/Shift+Tab cycles filters; settings use Up/Down or Tab/Shift+Tab
to select, Left/Right to change values, Enter to edit, and Escape to return.
The searchable command menu exposes title locking, column layout, tab naming/icons,
note/tab actions, pinning, themes, Markdown copy/export, settings and block actions.
The first launch with an empty database creates a pinned "Welcome to Onote" note with these keys;
`omarchy-shell onote welcome` brings it back.

Command line: `omarchy-shell onote newNote | hideNote | hideAll | restoreAll | pinNote | newNoteFromClipboard
| settings | welcome | mirror | mirrorStatus | status | reload` and `omarchy-shell shell toggle io.github.lolu13.onote`.
None of them take arguments; the mirror folder is set in Settings.

## What it touches on your system

Everything runs as your user; there is no privileged step and no daemon beyond the helper that the shell
starts and stops. The only network access is the update check: a `git fetch` of the plugin's own checkout
(see Updating). Nothing fetched runs until you confirm the update in a terminal.

**Written by the plugin**

- `~/.local/share/com.desknotes.omarchy/desknotes.db` (plus SQLite's `-wal`/`-shm` files): the notes. The path keeps
  its DeskNotes name so the database stays shared with the DeskNotes desktop edition.
  The directory is created 0700 and the files 0600; older modes are repaired on every launch.
- The Markdown mirror folder, only if you set one in Settings: one `<title>.md` per note, kept current on
  every save. Files are written through an exclusive temporary and a rename, never through a symlink;
  a file the plugin did not write is never replaced or deleted (a name clash gets the note id appended).
- `~/Documents/Onote/<title>.md` on Ctrl+Shift+E, never replacing an existing file (` (2)`, ` (3)`, …).
- The `welcomeCreated` setting and the welcome note, once, when the database is empty on load. That is the
  only write that happens without you asking; it goes into the plugin's own database.

**Read by the plugin**

- The clipboard, only when you press Ctrl+V in a note or Super+Alt+V: `wl-paste` is run by absolute path in
  its own process group with a five-second deadline, and its output is capped while reading (5 MB text,
  2 MB image). Images are checked by header (PNG, JPEG, GIF; at most 8192 px a side, 16 megapixels) before
  they reach the shell. `wl-copy` receives the Markdown on Ctrl+E the same way.
- Hyprland, through `hyprctl` by absolute path: one `eval` per batch of notes to register their window rules
  (ids, sizes and workspace names are validated into a fixed grammar first), `dispatch` to focus or pin a
  note's own window by address, and the shell's Hyprland IPC for window positions.
- The plugin's own git checkout, for the update check: `/usr/bin/git fetch --no-tags --no-write-fetch-head
  origin +HEAD:refs/onote/check` (a private ref; `FETCH_HEAD`, which `omarchy plugin update` shows and then
  merges, is never written by the check), then `rev-list --left-right --count HEAD...refs/onote/check` to see
  whether `origin` is strictly ahead (`rev-parse --git-dir` first, every time, which must answer `.git`: the plugin directory's own
  repository, not one enclosing it). git runs with hooks
  and fsmonitor disabled, an empty environment plus `HOME`, `PATH=/usr/bin`, `GIT_TERMINAL_PROMPT=0` and
  batch-mode ssh, a 60-second deadline with TERM then KILL, and its output capped at 4 KiB. Only two
  small integers are read from it; nothing fetched is executed.

**Not read**: no file outside the ones above, no environment beyond `HOME`, `XDG_*`, `WAYLAND_DISPLAY` and
`HYPRLAND_INSTANCE_SIGNATURE`, which are the only variables the helper, `hyprctl` and `git` are given (git
also gets the two fixed `GIT_*` values above).

Rendering: every text element is pinned to plain text, so note content is never interpreted as markup.
Image blocks accept only `data:image/png|jpeg|gif;base64,…` sources. Titles are capped at 200 characters,
blocks at 2000 per note, note content at 5 MB.

Timers: the update check runs 30 seconds after the shell starts and every 6 hours after that (one check
at a time; it reports "unsupported" while the plugin directory is not a git checkout and probes again on the
next tick). A pinned note polls
Hyprland every 3 seconds for its position while it is pinned, because drags of pinned windows send no event.

## Updating

The shell looks at the plugin's own git checkout for a newer commit 30 seconds after it starts and every
6 hours after that: a `git fetch`, then a comparison of commit ids; nothing is merged and nothing fetched
runs. When `origin` is ahead, or the checkout is newer than the helper last installed from it (an
`omarchy plugin update` run without this script's build step), every open note shows a small red square in
its bottom-right corner. Click it, or run `omarchy-shell onote update`, and a floating terminal opens with
`scripts/update.py`, which
runs the install's three commands one after the other where you can watch them:

1. `omarchy plugin update io.github.lolu13.onote`: Omarchy's own updater shows the diff and asks before
   fast-forwarding, validates the tree and rolls back if validation fails;
2. `cargo build --release --locked --manifest-path helper/Cargo.toml`, with the build output under
   `~/.cache/onote/cargo-target` (the shell watches the plugin directory and would reload on every file
   the build wrote there);
3. `python3 scripts/install.py`, which copies the new helper (without `--helper`, the newest build of that
   checkout: in its tree, or in that cache directory), refreshes the Hyprland rule and bindings
   (the `--no-shortcuts` choice of the first install is remembered in `~/.local/state/onote/install.json`)
   and restarts the shell.

`omarchy-shell onote checkUpdate` runs the check now and `omarchy-shell onote status` includes its result.
The check exists only for a git checkout, which is what `omarchy plugin add` creates; a copy made with
`install.py --sync` never shows the square. A checkout that is ahead of or diverged from `origin` counts as
up to date, because the updater only fast-forwards.

## Removing

```sh
python3 ~/.config/omarchy/plugins/io.github.lolu13.onote/scripts/uninstall.py
```

The uninstall script disables the plugin, removes the plugin directory (`omarchy plugin remove` would
then report it as not installed), `~/.local/bin/onote-helper`, the launcher entry, the icon,
`~/.config/hypr/onote.lua` and the one `dofile` line in `bindings.lua` (validated with
`hyprctl configerrors`, rolled back if Hyprland objects), then restarts the shell.

Kept on purpose, delete them yourself if you want them gone:

- `~/.local/share/com.desknotes.omarchy/` (your notes),
- the Markdown mirror folder and `~/Documents/Onote/` exports,
- `~/.local/state/onote/install-backups/`,
- the bar entry in `~/.config/omarchy/shell.json` (remove Onote from the bar in the shell settings).

## Layout

```
manifest.json, *.qml, *.js, blocks/   the plugin, loaded by omarchy-shell
helper/                                Rust: onote-helper, JSON lines over stdin/stdout
hypr/onote.lua                     window rule + bindings, installed as ~/.config/hypr/onote.lua
scripts/install.py, uninstall.py       install / remove (see above)
scripts/update.py                      what the update square runs
scripts/test-qml.py                    QML regression suite (qmltestrunner, offscreen)
scripts/test-workspace-rules.py        live check of the window rules against the running Hyprland
tests/, helper/tests/smoke.py          the tests
KEYBINDINGS.md                         the full keyboard cheat sheet
CHANGELOG.md                           what changed in each version
docs/                                  design notes, lessons learned, how to contribute
```

`helper/src/db.rs` is the database layer. It keeps the schema of the DeskNotes desktop edition, so a
database written by either stays readable by the other.

## Developing

- After editing QML, run `python3 scripts/install.py --sync`: it copies the files and restarts the shell.
  The shell's hot reload keeps a stale component cache, so a restart is required.
- Shell errors: `journalctl --user -t omarchy-shell -o cat | grep WARN`.
- `omarchy-shell onote status` returns `{ready, open, stacked, unsaved, update, error}`.
- Tests: `cargo test --release --manifest-path helper/Cargo.toml`, `python3 helper/tests/smoke.py`
  (a throwaway database; set `ONOTE_DB=/abs/path` to use a copy), `python3 scripts/test-qml.py`.
  The full list is in [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md); how it is built, in [docs/DESIGN.md](docs/DESIGN.md).

## Protocol

One JSON object per line between the shell and the helper. `{"id":1,"op":"listNotes"}` →
`{"id":1,"ok":true,"result":[...]}`; errors `{"id":1,"ok":false,"error":"..."}`.
Ops: ping, listNotes, getNote, createNote, createNoteFromClipboard, clipboardImage, ensureWelcomeNote,
updateNote, deleteNote, stackNote, unstackNote, stackAll, restoreAll, search, searchNoteIds, getSetting,
setSetting, listSettings, listThemes, saveTheme, deleteTheme, listTabs, tabsFor, getTab, createTab, updateTab,
deleteTab, setMirrorDir, copyMarkdown, exportNote, renderMarkdown.
`listNotes` sends stacked notes without their body (a bounded `preview` instead) and `listTabs` only open
notes' tabs (`tabsFor` fetches a note's when it is restored). Either list carries at most 8 MB of bodies;
rows past that come with `bodyPending: true` and are fetched one by one (`getNote`, `getTab`). The helper
exits when stdin closes.

## License

MIT, see [LICENSE](LICENSE).
