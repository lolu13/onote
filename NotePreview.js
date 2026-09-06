.pragma library

// Bound both the text handed to Qt's layout engine and temporary joined strings.
function text(contentBlocks) {
  var limit = 400
  var blocks
  try { blocks = JSON.parse(contentBlocks || "[]") } catch (e) { return "" }
  if (!Array.isArray(blocks)) return ""
  var result = ""
  for (var i = 0; i < blocks.length && result.length < limit; i++) {
    var b = blocks[i] || {}
    var part = ""
    if (b.type === "image") part = "[image]"
    else if (b.type === "divider") part = "—"
    else if (b.type === "label") part = String(b.label || "").slice(0, limit) + ": " + String(b.content || "").slice(0, limit)
    else if (b.content) part = String(b.content).slice(0, limit)
    if (!part) continue
    if (result.length) result += "  ·  "
    result += part.slice(0, Math.max(0, limit - result.length))
    result = result.slice(0, limit)
  }
  // Avoid ending a preview halfway through a UTF-16 surrogate pair.
  var last = result.charCodeAt(result.length - 1)
  if (last >= 0xD800 && last <= 0xDBFF) result = result.slice(0, -1)
  return result
}
