// The note window's vertical budget (NoteLayout.js): the editor keeps room at
// the smallest window and the largest text, and never gets a negative height.
import QtQuick
import QtTest
import "../NoteLayout.js" as NoteLayout

TestCase {
  name: "NoteLayout"

  // 320x240 at 32px text: margins 26 each side, title 58, tabs 51, divider 1,
  // spacing 16, hint about 33 tall.
  function test_the_hint_gives_way_at_the_smallest_window_and_largest_text() {
    var available = 240 - 52, fixed = 58 + 51 + 1
    compare(NoteLayout.hintShown(available, fixed, 33, 16, 32, false), false)
    verify(NoteLayout.editorHeight(available, fixed, 33, false, 16) > 0, "the editor keeps its room")
  }

  function test_a_save_error_is_shown_even_when_cramped() {
    compare(NoteLayout.hintShown(188, 110, 33, 16, 32, true), true)
    compare(NoteLayout.editorHeight(188, 110, 33, true, 16), 0, "never negative")
  }

  function test_the_hint_shows_at_a_normal_size() {
    // 350 tall at 14px text: margins 11, title 25, tabs 22, spacing 7.
    var available = 350 - 22, fixed = 25 + 22 + 1
    compare(NoteLayout.hintShown(available, fixed, 15, 7, 14, false), true)
    compare(NoteLayout.editorHeight(available, fixed, 15, true, 7), available - fixed - 15 - 28)
  }
}
