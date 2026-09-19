import QtQuick
import QtTest
import ".."

Item {
  width: 900; height: 600
  QtObject {
    id: mock
    property string saved: ""
    function updateNote(id, patch) { saved = patch.contentBlocks }
  }
  BlockEditor { id: editor; anchors.fill: parent; noteId: "test"; store: mock }
  CommandMenu {
    id: menu; anchors.fill: parent
    commands: [{id:"lock",label:"Lock title"}, {id:"rename",label:"Rename tab",keys:"F2"}, {id:"columns",label:"Cycle columns"}]
  }
  SignalSpy { id: action; target: menu; signalName: "triggered" }
  SignalSpy { id: dismissed; target: menu; signalName: "dismissed" }
  TestCase {
    name: "KeyboardNavigation"
    when: windowShown
    function init() {
      menu.visible = false; action.clear(); dismissed.clear(); mock.saved = ""
      editor.columns = 1
      editor.load(JSON.stringify([{type:"text",content:"First"}, {type:"label",label:"Badge",content:"Value"}, {type:"code",content:"code"}, {type:"divider"}, {type:"text",content:"Last"}]))
      wait(30); editor.focusBlock(0, false); wait(0)
    }
    function test_tab_forward_backward_and_label_badge() {
      keyClick(Qt.Key_Tab); compare(editor.focusedIndex, 1)
      keyClick(Qt.Key_Tab, Qt.ShiftModifier)
      keyClick(Qt.Key_A); editor.flush()
      compare(JSON.parse(mock.saved)[1].label, "Badgea", "Shift+Tab reaches the badge")
      keyClick(Qt.Key_Tab, Qt.ShiftModifier); compare(editor.focusedIndex, 0)
      editor.focusBlock(3, false)
      keyClick(Qt.Key_Tab); compare(editor.focusedIndex, 4)
      keyClick(Qt.Key_Tab, Qt.ShiftModifier); compare(editor.focusedIndex, 3)
    }
    function test_code_indent_and_unindent() {
      editor.focusBlock(2, false)
      keyClick(Qt.Key_Tab); editor.flush()
      compare(JSON.parse(mock.saved)[2].content, "  code")
      keyClick(Qt.Key_Tab, Qt.ShiftModifier); editor.flush()
      compare(JSON.parse(mock.saved)[2].content, "code")
    }
    // A moved block keeps its focus and the editor's focused index follows
    // it, or the next shortcut acts on the neighbour that took its old index.
    function test_a_moved_block_keeps_the_focused_index() {
      editor.load(JSON.stringify([{type:"text",content:"A"}, {type:"text",content:"B"}, {type:"text",content:"C"}]))
      wait(30); editor.focusBlock(1, false); wait(0)
      compare(editor.focusedIndex, 1)
      editor.moveBlock(1, -1); wait(0)
      compare(editor.focusedIndex, 0, "the index moved with the block")
      editor.moveBlock(editor.focusedIndex, -1); editor.flush()
      compare(JSON.parse(mock.saved).map(function(b) { return b.content }).join(""), "BAC", "a second move up is a no-op at the top")
      editor.moveBlock(editor.focusedIndex, 1); wait(0); editor.flush()
      compare(JSON.parse(mock.saved).map(function(b) { return b.content }).join(""), "ABC", "moved back down, the same block")
      compare(editor.focusedIndex, 1)
    }
    // Only text-like blocks become to-dos: an image or a label converted
    // would lose its src or badge, with no undo.
    function test_toggle_todo_leaves_images_and_labels_alone() {
      editor.load(JSON.stringify([{type:"image",src:"data:image/png;base64,AA=="}, {type:"label",label:"Phone",color:"#a58a42",content:"555"}, {type:"bullet",content:"milk"}]))
      wait(30)
      editor.toggleTodo(0); editor.toggleTodo(1); editor.toggleTodo(2); editor.flush()
      var b = JSON.parse(mock.saved)
      compare(b[0].type, "image"); compare(b[0].src, "data:image/png;base64,AA==")
      compare(b[1].type, "label"); compare(b[1].label, "Phone")
      compare(b[2].type, "todo"); compare(b[2].content, "milk")
    }
    function test_ctrl_home_end_jump_between_first_and_last_block() {
      editor.focusBlock(2, false)
      keyClick(Qt.Key_End, Qt.ControlModifier); compare(editor.focusedIndex, 4)
      keyClick(Qt.Key_Home, Qt.ControlModifier); compare(editor.focusedIndex, 0)
      compare(editor.dirty, false)
    }
    function test_columns_focus_without_changing_text() {
      var blocks=[]
      for(var i=0;i<24;i++) blocks.push({type:"text",content:"Row "+i})
      editor.load(JSON.stringify(blocks)); editor.columns=3; wait(30)
      editor.focusBlock(0,false); editor.focusColumn(1)
      compare(editor.blockLayout.positions[editor.focusedIndex].column, 1)
      editor.focusColumn(1)
      compare(editor.blockLayout.positions[editor.focusedIndex].column, 2)
      editor.focusColumn(-1)
      compare(editor.blockLayout.positions[editor.focusedIndex].column, 1)
      compare(editor.dirty,false)
    }
    function test_command_search_enter_and_escape() {
      menu.open(); wait(0)
      keyClick(Qt.Key_F); keyClick(Qt.Key_2)
      compare(menu.matches.length,1)
      keyClick(Qt.Key_Return)
      compare(action.count,1); compare(action.signalArguments[0][0],"rename")
      verify(!menu.visible)
      menu.open(); keyClick(Qt.Key_Escape)
      compare(dismissed.count,1); verify(!menu.visible)
    }
    function test_command_tab_reverse_and_empty_result() {
      menu.open(); wait(0)
      keyClick(Qt.Key_Tab,Qt.ShiftModifier); keyClick(Qt.Key_Return)
      compare(action.signalArguments[0][0],"columns")
      menu.open(); keyClick(Qt.Key_Z); keyClick(Qt.Key_Z)
      compare(menu.matches.length,0)
      keyClick(Qt.Key_Return); compare(action.count,1); verify(menu.visible)
      keyClick(Qt.Key_Escape)
    }
    function test_slash_picker_reverse_tab() {
      editor.load('[{"type":"text","content":""}]'); editor.focusBlock(0,false)
      keyClick(Qt.Key_Slash); compare(editor.pickerSelection,0)
      keyClick(Qt.Key_Tab,Qt.ShiftModifier)
      compare(editor.pickerSelection,editor.pickerItems.length-1)
      keyClick(Qt.Key_Escape); compare(editor.pickerIndex,-1)
    }
  }
}
