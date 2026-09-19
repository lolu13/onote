// Consecutive blocks flow down each column. A heading stays with the next row.
function arrange(heights, types, columns, gap) {
  var total = 0, positions = [], column = 0, y = 0, maxHeight = 0
  for (var i = 0; i < heights.length; i++) total += heights[i] + gap
  var target = total / columns
  for (var j = 0; j < heights.length; j++) {
    var h = heights[j]
    var groupHeight = h
    if (types[j] === "subtitle" && j + 1 < heights.length) groupHeight += gap + heights[j + 1]
    var previousHeading = j > 0 && types[j - 1] === "subtitle"
    if (column < columns - 1 && y > 0 && y + groupHeight > target && !previousHeading) {
      maxHeight = Math.max(maxHeight, y - gap)
      column++
      y = 0
    }
    positions.push({ column: column, y: y })
    y += h + gap
  }
  return { positions: positions, height: Math.max(maxHeight, y - gap, 0) }
}
