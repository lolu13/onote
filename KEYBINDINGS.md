# Onote keyboard cheat sheet

Last checked: 2026-09-19, version 1.1.0. If shortcuts change, update this file too.

On first launch a pinned "Welcome to Onote" note lists the keys below; `omarchy-shell onote welcome` brings it back. **Super** means the Windows/logo key. A **stack** is where closed notes wait until you reopen
them; closing a note never deletes it.

## Learn these four first

| What you want to do | Keys |
| --- | --- |
| Open your notes from anywhere | **Super+N** |
| Create a note | **Super+Alt+N** (anywhere) or **Ctrl+N** (in a note or the library) |
| Put the current note away in the stack | **Super+W** (or Ctrl+W on its last tab) |
| Close the library | **Esc** |

## From anywhere on the desktop

Handled by Omarchy/Hyprland.

| Action | Keys |
| --- | --- |
| Open Notes & Stack | Super+N |
| Create a new note | Super+Alt+N |
| Create a note from the clipboard text (one line per block) | Super+Alt+V |
| Hide the focused note to the stack | Super+Alt+H |
| Hide all open notes to the stack | Super+Alt+Shift+H |
| Close the focused window; a note goes to the stack | Super+W |
| Focus the window left/right/above/below | Super+Left / Right / Up / Down |
| Toggle the focused window between tiled and floating | Super+T |
| Move the focused note to another workspace; it reopens there next time | Super+Shift+1…9 |
| Send the focused note to the scratchpad, Omarchy's drawer over every workspace; it stays there | Super+Alt+S |
| Show or hide the scratchpad with every note you sent there | Super+S |
| Pin the focused note: it floats above everything on every workspace, and comes back that way | Super+Alt+P (or Ctrl+Shift+P inside the note) |
| Create a note inside the scratchpad | Super+S, then Super+Alt+N |

## Inside a note

| Action | Keys |
| --- | --- |
| Commands: type to search, arrows/Tab select, Enter run, Esc cancel | Ctrl+K or F1 |
| Cycle focus: title, lock, columns, tab bar, editor | F6 / Shift+F6 (Esc returns to editing) |
| Focus and select the title | Ctrl+L |
| Cycle the tab's column layout (1, 2, 3 columns) forward / backward | Ctrl+J / Ctrl+Shift+J |
| Focus the adjacent column / the first or last block | Alt+Left / Alt+Right / Ctrl+Home / Ctrl+End |
| Save to the stack and close | Ctrl+W |
| Save now | Ctrl+S |
| New note | Ctrl+N |
| Open Notes & Stack | Ctrl+Shift+F |
| Next / previous block | Down / Up (from the last / first line of a block) |
| New block below | Enter |
| New line inside a text block | Shift+Enter |
| Remove an empty block, or turn a list item back into text | Backspace on an empty block |
| Move the current block up / down | Alt+Up / Alt+Down |
| Tick or untick a to-do | Ctrl+Enter, or click the box |
| Bold / italic / underline the selection | Ctrl+B / Ctrl+I / Ctrl+U |
| Undo / redo inside a block | Ctrl+Z / Ctrl+Shift+Z |
| Change the label colour | Ctrl+Shift+L (on a label block) |
| Next skin | Ctrl+Shift+T |
| Bigger / smaller text | Ctrl+= / Ctrl+- |
| From the title, go to the first block | Enter or Down |
| From the first line, go up to the title (new notes open in the body; the title is optional) | Up |
| Pin or unpin this note on every workspace | Ctrl+Shift+P |
| Paste: an image on the clipboard becomes an image block (up to 2 MB, 20 per note); text pastes as text | Ctrl+V |
| New tab in this note | Ctrl+T |
| Close this tab; on the last tab, put the note in the stack | Ctrl+W |
| Next / previous tab | Ctrl+Tab / Ctrl+Shift+Tab (or Ctrl+PageDown / PageUp) |
| Jump to tab 1…9 | Ctrl+1 … Ctrl+9 |
| Rename this tab (an empty name restores its number) | F2, or double-click the tab |
| Give this tab an icon instead of its number (Backspace in the picker restores the number) | Ctrl+Shift+I, or right-click the tab |

### Block types

Type these at the start of an empty text block:

| Type | Shortcut |
| --- | --- |
| Heading | `# ` |
| Bullet | `- ` |
| To-do | `[] ` |
| Divider | `---` then Enter |
| Code | ``` then Enter |
| Any type from a list | `/` then start typing its name, Up/Down, Enter (Esc keeps the text) |

In a code block Enter inserts a new line and Tab inserts two spaces; press Enter twice on an
empty last line to leave the block. In a label block, Tab moves from the name to the value.
Images and dividers are selected with Up/Down and removed with Backspace or Delete.

## Notes & Stack (the library)

| Action | Keys |
| --- | --- |
| Search titles and note text | Start typing |
| Open Settings (default note size, text size, autosave delay, theme, Markdown mirror folder). Note text follows the Omarchy font size unless you change it | Ctrl+, in the library or in a note |
| Copy the selected note as Markdown | Ctrl+E |
| Save the selected note as `~/Documents/Onote/<title>.md` | Ctrl+Shift+E |
| Clear the search | Ctrl+U, or Backspace |
| Show All / Open / Stacked notes | Tab |
| Choose a note | Up / Down, Page Up / Page Down, Home / End |
| Open the chosen note (restores it if stacked) | Enter or Right |
| Delete the chosen note | Delete, then Right, then Enter (Cancel is the default) |
| Delete the chosen note, Delete preselected | Shift+Delete, then Enter (the dialog still asks) |
| Create a note | Ctrl+N |
| Clear the search, then close | Esc |

The search matches titles immediately; text inside notes is searched after a short pause and
those rows say "match in text".
