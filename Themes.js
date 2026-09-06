// Built-in note palettes, ported from src/App.tsx (THEMES). Keep in sync.
// "system" is not listed here: it binds live to Omarchy's own colours (see NotePalette.qml).
.pragma library

var BUILTIN = {
  "dracula": {
    background: "#282a36", currentLine: "#44475a", foreground: "#f8f8f2",
    comment: "#6272a4", accentPrimary: "#ff79c6", accentSecondary: "#bd93f9",
    labelColors: ["#50fa7b", "#8be9fd", "#ff79c6", "#bd93f9", "#f1fa8c", "#ffb86c"]
  },
  "nord": {
    background: "#2e3440", currentLine: "#3b4252", foreground: "#eceff4",
    comment: "#4c566a", accentPrimary: "#5e81ac", accentSecondary: "#88c0d0",
    labelColors: ["#a3be8c", "#88c0d0", "#b48ead", "#81a1c1", "#ebcb8b", "#bf616a"]
  },
  "monokai": {
    background: "#272822", currentLine: "#3e3d32", foreground: "#f8f8f2",
    comment: "#75715e", accentPrimary: "#f92672", accentSecondary: "#fd971f",
    labelColors: ["#a6e22e", "#66d9ef", "#f92672", "#ae81ff", "#e6db74", "#fd971f"]
  },
  "solarized-dark": {
    background: "#002b36", currentLine: "#073642", foreground: "#839496",
    comment: "#586e75", accentPrimary: "#268bd2", accentSecondary: "#2aa198",
    labelColors: ["#859900", "#2aa198", "#d33682", "#6c71c4", "#b58900", "#cb4b16"]
  },
  "rose-pine": {
    background: "#191724", currentLine: "#26233a", foreground: "#e0def4",
    comment: "#6e6a86", accentPrimary: "#eb6f92", accentSecondary: "#c4a7e7",
    labelColors: ["#9ccfd8", "#c4a7e7", "#eb6f92", "#f6c177", "#31748f", "#ebbcba"]
  },
  "gruvbox": {
    background: "#282828", currentLine: "#3c3836", foreground: "#ebdbb2",
    comment: "#928374", accentPrimary: "#fe8019", accentSecondary: "#fabd2f",
    labelColors: ["#b8bb26", "#83a598", "#d3869b", "#fabd2f", "#8ec07c", "#fe8019"]
  },
  "tokyo-night": {
    background: "#1a1b26", currentLine: "#292e42", foreground: "#c0caf5",
    comment: "#565f89", accentPrimary: "#7aa2f7", accentSecondary: "#bb9af7",
    labelColors: ["#9ece6a", "#7dcfff", "#f7768e", "#bb9af7", "#e0af68", "#ff9e64"]
  }
}

var BUILTIN_NAMES = ["dracula", "nord", "monokai", "solarized-dark", "rose-pine", "gruvbox", "tokyo-night"]
var HEX = /^#[0-9a-fA-F]{6}$/

function isHex(v) { return typeof v === "string" && HEX.test(v) }

// Returns a palette object for a built-in or custom theme name, or null for
// "system" / unknown names (callers then use Omarchy's colours).
function resolve(name, customThemes) {
  if (!name || name === "system") return null
  if (BUILTIN[name]) return BUILTIN[name]
  if (name.indexOf("custom-") === 0 && customThemes) {
    var id = name.slice(7)
    for (var i = 0; i < customThemes.length; i++) {
      var t = customThemes[i]
      if (!t || t.id !== id) continue
      var data = null
      try { data = JSON.parse(t.themeData || "{}") } catch (e) { data = null }
      if (!data) return null
      var base = BUILTIN.dracula
      var out = {}
      var keys = ["background", "currentLine", "foreground", "comment", "accentPrimary", "accentSecondary"]
      for (var k = 0; k < keys.length; k++) out[keys[k]] = isHex(data[keys[k]]) ? data[keys[k]] : base[keys[k]]
      out.labelColors = Array.isArray(data.labelColors) && data.labelColors.length
        ? data.labelColors.filter(isHex) : base.labelColors
      if (!out.labelColors.length) out.labelColors = base.labelColors
      return out
    }
  }
  return null
}

// Ordered list for cycling: system, built-ins, then customs.
function allNames(customThemes) {
  var names = ["system"].concat(BUILTIN_NAMES)
  if (customThemes) for (var i = 0; i < customThemes.length; i++)
    if (customThemes[i] && customThemes[i].id) names.push("custom-" + customThemes[i].id)
  return names
}

function displayName(name, customThemes) {
  if (name === "system") return "System"
  if (BUILTIN[name]) return name.replace(/-/g, " ").replace(/\b\w/g, function(c) { return c.toUpperCase() })
  if (name.indexOf("custom-") === 0 && customThemes) {
    var id = name.slice(7)
    for (var i = 0; i < customThemes.length; i++)
      if (customThemes[i] && customThemes[i].id === id) return customThemes[i].name || "Custom"
  }
  return name
}
