#!/usr/bin/env python3
"""Remove the Onote shell plugin, helper, launcher entry and Hyprland bindings.

The notes database (~/.local/share/com.desknotes.omarchy/desknotes.db) is kept.
"""
import os
from pathlib import Path
import shutil
import subprocess

PLUGIN_ID = "io.github.lolu13.onote"
SOURCE_LINE = 'dofile((os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/hypr/onote.lua")'


def run(*args):
    return subprocess.run(args, text=True, capture_output=True)


def main():
    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share"))

    run("omarchy", "plugin", "disable", PLUGIN_ID)
    plugin = config / "omarchy/plugins" / PLUGIN_ID
    if plugin.is_dir() and not plugin.is_symlink():
        shutil.rmtree(plugin)
        print(f"Removed {plugin}")
    run("omarchy-shell", "shell", "rescanPlugins")

    for path in (home / ".local/bin/onote-helper", data / "applications/onote.desktop",
                 data / "icons/hicolor/128x128/apps/onote.png"):
        if path.exists() or path.is_symlink():
            path.unlink()
            print(f"Removed {path}")

    lua = config / "hypr/onote.lua"
    if lua.exists():
        lua.unlink()
        print(f"Removed {lua}")
    bindings = config / "hypr/bindings.lua"
    if bindings.exists():
        text = bindings.read_text()
        cleaned = text.replace("\n-- Onote\n" + SOURCE_LINE + "\n", "\n").replace(SOURCE_LINE + "\n", "")
        if cleaned != text:
            # Only the marked line goes; the edit is validated by Hyprland and
            # rolled back to the exact prior bytes if it produced an error.
            before = bindings.read_bytes()
            bindings.write_text(cleaned)
            run("hyprctl", "reload")
            errors = run("hyprctl", "configerrors").stdout.strip()
            if errors:
                bindings.write_bytes(before)
                run("hyprctl", "reload")
                print(f"Left {bindings} unchanged: Hyprland reported {errors}")
            else:
                print(f"Removed Onote line from {bindings}")
    run("hyprctl", "reload")
    run("omarchy-restart-shell")
    print("Onote plugin removed. Kept: the notes database at", data / "com.desknotes.omarchy/desknotes.db",
          "\n      install backups under ~/.local/state/onote, Markdown mirror files and exports,",
          "\n      and the bar entry in ~/.config/omarchy/shell.json (remove it from the bar settings).")


if __name__ == "__main__":
    main()
