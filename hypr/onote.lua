-- Onote (Omarchy shell plugin). Sourced from ~/.config/hypr/bindings.lua.
-- Note windows are created by omarchy-shell (class org.quickshell), so rules
-- match on the title suffix " — Onote [dn:<note id>]"; never match the
-- class alone, other shell windows share it. Hyprland regexes are full-match.
o.window({ class = "^org.quickshell$", title = ".* — Onote \\[dn:[0-9a-f]+\\]$" }, { tile = true, rounding = 0 })

o.bind("SUPER + N", "Onote: notes and stack", "omarchy-shell shell toggle io.github.lolu13.onote")
o.bind("SUPER + ALT + N", "Onote: new note", "omarchy-shell onote newNote")
o.bind("SUPER + ALT + H", "Onote: stack all notes", "omarchy-shell onote hideAll")
o.bind("SUPER + ALT + P", "Onote: pin note on every workspace", "omarchy-shell onote pinNote")
o.bind("SUPER + ALT + V", "Onote: new note from clipboard", "omarchy-shell onote newNoteFromClipboard")
