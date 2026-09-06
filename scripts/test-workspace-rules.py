#!/usr/bin/env python3
"""Live check of omarchy-plugin/plugin/WorkspaceRules.qml against the running Hyprland.

Loads the component in a standalone Quickshell instance, registers rules for
three fake notes in two overlapping batches, and verifies both `placed` signals
arrive. The test rules match nothing real and are disabled afterwards; a config
reload removes them entirely. No note windows are opened.

    python3 scripts/test-workspace-rules.py
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAKE = ["aaaaaaaaaaaa", "bbbbbbbbbbbb", "cccccccccccc"]

HARNESS = """import QtQuick
import Quickshell
import "." as Plugin

ShellRoot {
  Plugin.WorkspaceRules {
    id: rules
    property int batches: 0
    onPlaced: function(ids) {
      console.log("RULES placed:", JSON.stringify(ids))
      if (++batches === 2) Qt.quit()
    }
    Component.onCompleted: {
      console.log("RULES selector:", windowSelector("0123456789abcdef"))
      console.log("RULES ws:", workspaceSelector({ workspaceId: 3, workspaceName: "3" }),
                  workspaceSelector({ workspaceId: -98, workspaceName: "special:notes" }),
                  workspaceSelector({ workspaceId: -1, workspaceName: "mail" }),
                  workspaceSelector({ workspaceId: 5, workspaceName: "" }))
      console.log("RULES pinned lua:", ruleLua({ id: "0123456789abcdef", pinned: true, width: 320.4, height: 240, positionX: 800, positionY: 200 }))
      console.log("RULES pin script:", pinScript("0123456789abcdef", true, 320, 240).split("\\n").length, "lines")
      ensure([{ id: "aaaaaaaaaaaa-test", workspaceId: 3, workspaceName: "3" }])
      ensure([{ id: "bbbbbbbbbbbb-test", workspaceId: -98, workspaceName: "special:notes" },
              { id: "cccccccccccc-test", pinned: true, width: 300, height: 350, positionX: 10, positionY: 40 }])
    }
  }
  Timer { interval: 8000; running: true; onTriggered: { console.log("RULES timeout"); Qt.quit() } }
}
"""


def disable_rules():
    for tag in FAKE:
        for name in ("dn", "dnp"):
            lua = (f'hl.window_rule({{ name = "{name}-{tag}", match = {{ class = "^org.quickshell$", '
                   f'title = ".*\\\\[dn:{tag}\\\\].*" }} }}):set_enabled(false)')
            subprocess.run(["hyprctl", "eval", lua], capture_output=True)


def main():
    if not shutil.which("quickshell") or not shutil.which("hyprctl"):
        raise SystemExit("quickshell and hyprctl are required (run inside the Omarchy session).")
    with tempfile.TemporaryDirectory(prefix="dn-rules-") as tmp:
        d = Path(tmp)
        shutil.copy(ROOT / "omarchy-plugin/plugin/WorkspaceRules.qml", d)
        (d / "harness.qml").write_text(HARNESS)
        try:
            r = subprocess.run(["quickshell", "-p", str(d / "harness.qml")], capture_output=True,
                               text=True, timeout=20)
            out = r.stdout + r.stderr
        finally:
            disable_rules()
    lines = [l for l in out.splitlines() if "RULES" in l or "ERROR" in l]
    print("\n".join(lines))
    placed = [l for l in lines if "RULES placed" in l]
    ok = (len(placed) == 2
          and '"aaaaaaaaaaaa-test"' in placed[0]
          and '"bbbbbbbbbbbb-test","cccccccccccc-test"' in placed[1]
          and "RULES ws: 3 special:notes name:mail 5" in out
          and 'name = "dnp-0123456789ab"' in out and "size = { 320, 240 }, move = { 800, 200 }" in out
          and 'name = "dn-0123456789ab", match' in out and '}):set_enabled(false)' in out
          and "RULES pin script: 4 lines" in out
          and "RULES timeout" not in out)
    print("workspace rules: PASS" if ok else "workspace rules: FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
