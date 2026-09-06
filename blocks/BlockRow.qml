// One row of the block editor. Picks a delegate by block type and exposes the
// row's model data plus the editor callbacks to that delegate.
import QtQuick

FocusScope {
  id: blockRow

  property var editor: null
  readonly property int rowIndex: index
  readonly property string type: model.type
  readonly property string content: model.content
  readonly property bool checked: model.checked
  readonly property string label: model.label
  readonly property string color: model.color
  readonly property string src: model.src
  readonly property int imageWidth: model.imageWidth

  readonly property var palette: editor ? editor.palette : null
  readonly property int fontSize: editor ? editor.fontSize : 15
  readonly property string fontFamily: editor ? editor.fontFamily : ""

  readonly property bool pickerActive: editor ? editor.pickerIndex === rowIndex : false

  width: parent ? parent.width : 0
  height: (loader.item ? loader.item.height : 0) + (picker.visible ? picker.height + 4 : 0)

  onActiveFocusChanged: if (activeFocus && editor) editor.focusedIndex = rowIndex

  function focusEditor(atEnd) { if (loader.item) loader.item.focusEditor(atEnd) }

  // callbacks used by delegates
  function setContent(t) { editor.setContent(rowIndex, t) }
  function setChecked(b) { editor.setChecked(rowIndex, b) }
  function setLabel(t) { editor.setLabel(rowIndex, t) }
  function enter() { editor.onEnter(rowIndex) }
  function backspaceOnEmpty() { editor.onBackspaceOnEmpty(rowIndex) }
  function moveFocus(delta) { editor.focusBlock(rowIndex + delta, delta < 0) }
  function remove() { editor.removeBlock(rowIndex) }

  Loader {
    id: loader
    width: parent.width
    onLoaded: if (item) item.row = blockRow
    sourceComponent: {
      switch (blockRow.type) {
        case "code": return codeComp
        case "label": return labelComp
        case "divider": return dividerComp
        case "image": return imageComp
        default: return textComp
      }
    }
  }

  // Hidden pickers still instantiate their Repeaters. Only the active row
  // should allocate a menu or react to its filter/selection changes.
  Loader {
    id: picker
    y: (loader.item ? loader.item.height : 0) + 4
    width: Math.min(blockRow.width, blockRow.fontSize * 18)
    active: blockRow.pickerActive
    visible: active && item !== null && item.items.length > 0
    sourceComponent: Component {
      SlashPicker {
        editor: blockRow.editor
        pal: blockRow.palette
        size: blockRow.fontSize
      }
    }
  }

  Component { id: textComp;    TextBlock    { row: blockRow } }
  Component { id: codeComp;    CodeBlock    { row: blockRow } }
  Component { id: labelComp;   LabelBlock   { row: blockRow } }
  Component { id: dividerComp; DividerBlock { row: blockRow } }
  Component { id: imageComp;   ImageBlock   { row: blockRow } }
}
