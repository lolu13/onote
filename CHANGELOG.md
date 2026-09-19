# Changelog

What changed for someone who uses Onote, newest first. One entry per released version.

## 1.1.0

Your notes and the database stay where they are; nothing needs migrating.

### New

- **Notes reopen at login.** Notes that were open when you shut down, rebooted or logged out come
  back on their workspaces. Before, Omarchy's shutdown closed every window a moment early and
  each note landed in the stack. A note you close yourself still goes to the stack; one closed
  less than ten seconds before a shell restart comes back open.
- **Command menu** (Ctrl+K or F1): type to search every note, tab and block action, then Enter.
- **A title and a name for each tab.** Each tab keeps its own title; **Lock** beside the title
  keeps one title across all tabs. Double-click a tab or press F2 to name it.
- **Columns** (Ctrl+J, or the columns button): lay a tab out in one, two or three columns.
  Headings stay with the block under them.
- **Keyboard navigation.** F6 and Shift+F6 walk through title, lock, columns, tab bar and editor
  with a visible focus outline; Alt+Left and Alt+Right move between columns; Ctrl+L selects the title.
- **Notes follow the Omarchy font size.** New notes use the shell's text size, so
  `omarchy font size` changes them too. Settings can still fix a size of your own.
- **Update square.** When a newer Onote is published, a small red square shows in a note's
  bottom-right corner. Click it, or run `omarchy-shell onote update`, and a terminal shows
  Omarchy's own diff and asks before anything changes. This check is the plugin's only network
  access: a `git fetch` of its own repository, 30 seconds after start and then every six hours.
- **Each note remembers its last tab.**

### Fixed

- The installer now stops when the plugin fails validation, instead of installing a broken copy
  over a working one.
- A note whose workspace rule could not be set no longer opens on the wrong workspace and
  forgets the right one.
- Very large notes (over 5 MB) are refused once with a clear error, not retried forever, and a
  large collection can no longer make the notes list fail to load.
- A refused delete keeps the note and its unsaved edits.
- Moving a block up or down (Alt+Up, Alt+Down) no longer leaves blocks drawn over each other.
- A note closed a moment ago opens again when you pick it in Notes & Stack.
- Hide All during a reopen no longer makes a later Restore All jump to that note's workspace.
- The Markdown mirror never overwrites or deletes a file it did not write, handles a folder
  given by two spellings, and forgets its old files when you turn it off.
- Copy as Markdown (Ctrl+E) reports a failed copy instead of claiming success.
- A failed load of themes or settings is shown as an error; it no longer leaves notes on the
  wrong skin or overwrites a saved theme name.

## 1.0.0

First release on the Omarchy plugin marketplace.
