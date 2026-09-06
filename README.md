# Onote for Omarchy

Onote (formerly the Omarchy edition of DeskNotes): sticky notes as ordinary Hyprland windows, drawn by `omarchy-shell` itself. No browser engine,
no app process: the shell renders every note, and a small Rust helper owns the SQLite database.

- Each open note is a normal window that Hyprland tiles, floats, moves and resizes.
- Closing a note (Super+W) puts it in the **stack**; nothing is deleted by closing.
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

1. checks that Super+N, Super+Alt+N and Super+Alt+H are free (pass `--no-shortcuts` to keep your own bindings),
2. writes `~/.config/hypr/onote.lua` (one window rule, five bindings) and one `dofile` line at the end of
   `~/.config/hypr/bindings.lua`, validated with `hyprctl configerrors` and rolled back on any error,
3. copies the built helper to `~/.local/bin/onote-helper`, a launcher entry to
   `~/.local/share/applications/onote.desktop` and an icon to `~/.local/share/icons/hicolor/128x128/apps/`,
4. enables the plugin and restarts the shell.

Every file it replaces is backed up first under `~/.local/state/onote/install-backups/`.
If you had the earlier Tauri-based DeskNotes installed, its binary and launcher entry are retired the same way;
the notes database is shared and never touched.

The helper is built from the source in `helper/` on your machine; nothing is downloaded and no binary
is shipped. `onote-helper` must stay in `~/.local/bin` because `omarchy plugin update` replaces the
plugin directory.

## Use

| Action | Keys |
| --- | --- |
| Notes & Stack | Super+N |
| New note | Super+Alt+N, or Ctrl+N inside a note |
| New note from the clipboard text | Super+Alt+V |
| Stack all open notes | Super+Alt+H |
| Pin the focused note on every workspace | Super+Alt+P, or Ctrl+Shift+P inside it |
| Save and close to the stack | Super+W or Ctrl+W |
| Settings (sizes, text size, autosave, skin, mirror folder) | Ctrl+, in a note or the library |
| Tabs | Ctrl+T new, Ctrl+Tab next, Ctrl+1…9 jump, Ctrl+Shift+I icon |
| Paste an image (PNG, JPEG or GIF, up to 2 MB, 20 per note) | Ctrl+V |
| Copy the selected note as Markdown / save it to `~/Documents/Onote/` | Ctrl+E / Ctrl+Shift+E in the library |

Bar button: left click opens Notes & Stack, middle click creates a note, right click stacks all.
The first launch with an empty database creates a pinned "Welcome to Onote" note with these keys;
`omarchy-shell onote welcome` brings it back.

Command line: `omarchy-shell onote newNote | hideAll | restoreAll | pinNote | newNoteFromClipboard
| settings | welcome | mirror | mirrorStatus | status | reload` and `omarchy-shell shell toggle io.github.lolu13.onote`.
None of them take arguments; the mirror folder is set in Settings.

## What it touches on your system

Everything runs as your user; there is no network access, no privileged step, no daemon beyond the helper
that the shell starts and stops.

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

**Not read**: no file outside the ones above, no environment beyond `HOME`, `XDG_*`, `WAYLAND_DISPLAY` and
`HYPRLAND_INSTANCE_SIGNATURE`, which are the only variables the helper and `hyprctl` are given.

Rendering: every text element is pinned to plain text, so note content is never interpreted as markup.
Image blocks accept only `data:image/png|jpeg|gif;base64,…` sources. Titles are capped at 200 characters,
blocks at 2000 per note, note content at 5 MB.

Timers: none while idle. A pinned note polls Hyprland every 3 seconds for its position while it is pinned,
because drags of pinned windows send no event.

## Removing

```sh
python3 ~/.config/omarchy/plugins/io.github.lolu13.onote/scripts/uninstall.py
omarchy plugin remove io.github.lolu13.onote
```

The uninstall script disables the plugin, removes `~/.local/bin/onote-helper`, the launcher entry, the
icon, `~/.config/hypr/onote.lua` and the one `dofile` line in `bindings.lua` (validated with
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
scripts/test-qml.py                    QML regression suite (qmltestrunner, offscreen)
tests/, helper/tests/smoke.py          the tests
```

`helper/src/shared/db.rs` is the database layer shared with the Tauri edition of DeskNotes; it is copied
from that project on release and not edited here.

## Developing

- After editing QML, run `python3 scripts/install.py --sync`: it copies the files and restarts the shell.
  The shell's hot reload keeps a stale component cache, so a restart is required.
- Shell errors: `journalctl --user -t omarchy-shell -o cat | grep WARN`.
- `omarchy-shell onote status` returns `{ready, open, stacked, unsaved, error}`.
- Tests: `cargo test --release --manifest-path helper/Cargo.toml`, `python3 helper/tests/smoke.py`
  (a throwaway database; set `ONOTE_DB=/abs/path` to use a copy), `python3 scripts/test-qml.py`.

## Protocol

One JSON object per line between the shell and the helper. `{"id":1,"op":"listNotes"}` →
`{"id":1,"ok":true,"result":[...]}`; errors `{"id":1,"ok":false,"error":"..."}`.
Ops: ping, listNotes, getNote, createNote, createNoteFromClipboard, clipboardImage, ensureWelcomeNote,
updateNote, deleteNote, stackNote, unstackNote, stackAll, restoreAll, search, searchNoteIds, getSetting,
setSetting, listSettings, listThemes, saveTheme, deleteTheme, listTabs, createTab, updateTab, deleteTab,
setMirrorDir, copyMarkdown, exportNote, renderMarkdown.
`listNotes` sends stacked notes without their body (a bounded `preview` instead); the helper exits when
stdin closes.

## License

MIT, see [LICENSE](LICENSE).
