// Everything WorkspaceRules interpolates into `hyprctl eval` comes from stored
// rows. Hostile ids, names and numbers must be refused or clamped so no value
// can close a Lua string or add a statement.
import QtQuick
import QtTest
import "../RulesLua.js" as Rules

Item {

  TestCase {
    name: "WorkspaceRulesGrammar"
    property string hex: "0123456789abcdef-0000-4000-8000-00000000abcd"
    property string addr: "address:0x5642f0a1b2c3"

    function test_short_id_is_twelve_hex_or_nothing() {
      compare(Rules.shortId(hex), "0123456789ab")
      compare(Rules.shortId('x"); os.execute("id'), "")
      compare(Rules.shortId("ABCDEFABCDEF"), "", "uppercase is not a stored id")
      compare(Rules.shortId(null), "")
      compare(Rules.shortId(undefined), "")
      compare(Rules.shortId(12), "")
    }

    function test_workspace_selector_refuses_hostile_names() {
      compare(Rules.workspaceSelector({ workspaceName: "3", workspaceId: 3 }), "3")
      compare(Rules.workspaceSelector({ workspaceName: "special:notes", workspaceId: -98 }), "special:notes")
      compare(Rules.workspaceSelector({ workspaceName: "work 2", workspaceId: 5 }), "name:work 2")
      compare(Rules.workspaceSelector({ workspaceName: 'a" }) os.execute("id") --', workspaceId: 4 }), "4")
      compare(Rules.workspaceSelector({ workspaceName: "line\nbreak", workspaceId: 4 }), "4")
      compare(Rules.workspaceSelector({ workspaceName: "x".repeat(65), workspaceId: 4 }), "4")
      compare(Rules.workspaceSelector({ workspaceName: "special:", workspaceId: 7 }), "7", "bare special: prefix is not a workspace")
      compare(Rules.workspaceSelector({ workspaceName: "", workspaceId: "NaN" }), "0")
      compare(Rules.workspaceSelector({ workspaceName: "", workspaceId: 1e12 }), "999999")
      compare(Rules.workspaceSelector({ workspaceName: "", workspaceId: "9; os.exit()" }), "0")
    }

    function test_numbers_are_finite_clamped_integers() {
      var lua = Rules.ruleLua({ id: hex, pinned: true, width: NaN, height: Infinity, positionX: "1e9", positionY: -1e9 })
      verify(lua.indexOf("size = { 300, 350 }") !== -1, "NaN and Infinity fall back: " + lua)
      verify(lua.indexOf("move = { 65536, -65536 }") !== -1, lua)
      var pin = Rules.pinScript(addr, true, "abc", 12.6)
      verify(pin.indexOf("x = 300, y = 150") !== -1, pin)
    }

    // A dispatcher acts on one live window. Only the address of a toplevel the
    // caller already matched on class and title is accepted as its selector;
    // a title selector would let any window that copies the tag be pinned.
    function test_pin_script_only_accepts_an_address_selector() {
      verify(Rules.pinScript(addr, true, 400, 300).length > 0)
      verify(Rules.pinScript(addr, false, 400, 300).length > 0)
      compare(Rules.pinScript(Rules.windowSelector(hex), true, 400, 300), "", "a title selector is refused")
      compare(Rules.pinScript(hex, true, 400, 300), "", "a bare note id is not a selector")
      compare(Rules.pinScript("address:0xABC", true, 400, 300), "", "uppercase is not a hyprland address")
      compare(Rules.pinScript('address:0xab" }) os.execute("id') , "", "nothing can close the Lua string")
      compare(Rules.pinScript("address:0x", true, 400, 300), "", "an address needs at least one digit")
      compare(Rules.pinScript("", true, 400, 300), "")
      compare(Rules.pinScript(null, true, 400, 300), "")
      compare(Rules.pinScript(undefined, true, 400, 300), "")
    }

    // Each generated line is one call over a closed alphabet: nothing but the
    // fixed template, hex ids, a bounded name and integers.
    function test_generated_lua_has_a_closed_shape() {
      var lines = Rules.ruleLua({ id: hex, pinned: false, workspaceName: "special:notes", workspaceId: -98 }).split("\n")
        .concat(Rules.ruleLua({ id: hex, pinned: true, width: 400, height: 300, positionX: 10, positionY: 20 }).split("\n"))
        .concat(Rules.pinScript(addr, true, 400, 300).split("\n"))
        .concat(Rules.pinScript(addr, false, 400, 300).split("\n"))
      var allowed = /^hl\.(window_rule|dispatch)\([A-Za-z0-9_ .:{}=,()"^$*\\\[\]+-]*\)(:set_enabled\(false\))?$/
      for (var i = 0; i < lines.length; i++) {
        verify(allowed.test(lines[i]), "line " + i + ": " + lines[i])
        compare(lines[i].split('"').length % 2, 1, "quotes are balanced: " + lines[i])
        console.log("LUA:" + lines[i])
      }
    }
  }
}
