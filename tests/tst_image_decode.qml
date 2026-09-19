// A pasted image is decoded at most 1024 px wide and never larger than it
// is: with a fit mode Qt would scale a 1×2048 image up to 1024×2097152 in
// memory, so the decode uses Stretch and the aspect ratio is kept at paint.
import QtQuick
import QtTest
import "../blocks"

Item {
  width: 400; height: 400
  QtObject {
    id: fakeRow
    property var palette: null
    property int fontSize: 15
    property int imageWidth: 0
    property string fontFamily: ""
    property string src: ""
  }
  ImageBlock { id: block; row: fakeRow }

  TestCase {
    name: "ImageDecode"
    // Solid-colour PNGs: 1×2048, 2048×1 and 300×200.
    readonly property string tall: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAgACAIAAABoxM4cAAAAJklEQVR42u3DAQkAAAgDsEcwghHeP505hA2W2UZVVVVVVVVVff0A8A8ALnRI+ZsAAAAASUVORK5CYII="
    readonly property string wide: "iVBORw0KGgoAAAANSUhEUgAACAAAAAABCAIAAADFdtmlAAAAI0lEQVR42u3CAQ0AAAgDICM8ghHsn84eH4zJnqqqqqqqWvYBtB8ALvMIvtcAAAAASUVORK5CYII="
    readonly property string small: "iVBORw0KGgoAAAANSUhEUgAAASwAAADICAIAAADdvUsCAAABsklEQVR42u3TQQ0AAAjEsJOABCTgXx0yeNCkCpYs1QMcigRgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIWBCMCFgQjAhYEIwIZhQBTAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQTKgCmBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAgmBEwIJgRMCD8trT3pGrxErP0AAAAASUVORK5CYII="

    function decode(b64) {
      fakeRow.src = ""
      fakeRow.src = "data:image/png;base64," + b64
      tryVerify(function() { return block.decoded || block.failed }, 5000)
      verify(block.decoded, "the image decodes")
    }

    function test_a_tall_narrow_image_is_never_scaled_up() {
      decode(tall)
      compare(block.decodedSize.width, 1)
      compare(block.decodedSize.height, 2048)
    }

    function test_a_tall_narrow_image_is_bounded_in_height() {
      decode(tall)
      compare(block.decodedSize.width, 1)
      compare(block.decodedSize.height, 2048)
      verify(block.height <= block.maxHeight + 4, "painted height is capped: " + block.height)
      verify(block.height > 4, "the image is still drawn")
    }

    function test_a_wide_image_is_shrunk_to_the_width_cap() {
      decode(wide)
      compare(block.decodedSize.width, 1024)
      verify(block.decodedSize.height <= 1)
    }

    function test_a_small_image_keeps_its_size() {
      decode(small)
      compare(block.decodedSize.width, 300)
      compare(block.decodedSize.height, 200)
      compare(block.height, block.decodedSize.height + 4, "the block follows the image")
    }
  }
}
