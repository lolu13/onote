.pragma library
// The note window's vertical budget, kept free of Quickshell so the test
// suite can run it. The keyboard hint gives its line back to the editor when
// the window (320x240 at its smallest, text up to 32px) would otherwise leave
// the editor less than two lines; a save error in that line always shows.

// Room left for the editor once the fixed rows and the gaps between the
// visible ones are taken; never negative.
function editorHeight(available, fixedRows, hintHeight, hintShown, spacing) {
  var gaps = hintShown ? 4 : 3
  return Math.max(0, available - fixedRows - (hintShown ? hintHeight : 0) - spacing * gaps)
}

function hintShown(available, fixedRows, hintHeight, spacing, fontSize, notice) {
  if (notice) return true
  return editorHeight(available, fixedRows, hintHeight, true, spacing) >= fontSize * 3
}
