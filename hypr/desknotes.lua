-- DeskNotes Omarchy (shell plugin edition). Sourced from ~/.config/hypr/bindings.lua.
-- Note windows are created by omarchy-shell (class org.quickshell), so rules
-- match on the title suffix " — DeskNotes [dn:<note id>]"; never match the
-- class alone, other shell windows share it. Hyprland regexes are full-match.
o.window({ class = "^org.quickshell$", title = ".* — DeskNotes \\[dn:[0-9a-f]+\\]$" }, { tile = true, rounding = 0 })

o.bind("SUPER + N", "DeskNotes: notes and stack", "omarchy-shell shell toggle lolu13.desknotes")
o.bind("SUPER + ALT + N", "DeskNotes: new note", "omarchy-shell desknotes newNote")
o.bind("SUPER + ALT + H", "DeskNotes: stack all notes", "omarchy-shell desknotes hideAll")
o.bind("SUPER + ALT + P", "DeskNotes: pin note on every workspace", "omarchy-shell desknotes pinNote")
o.bind("SUPER + ALT + V", "DeskNotes: new note from clipboard", "omarchy-shell desknotes newNoteFromClipboard")
