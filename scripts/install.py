#!/usr/bin/env python3
"""Install the DeskNotes Omarchy shell plugin and its database helper.

Replaces the earlier Tauri-based app on this machine: its binary, desktop entry
and icon are backed up and removed. The notes database is never touched.

  python3 scripts/install.py                  full install (or upgrade)
  python3 scripts/install.py --sync           dev: copy plugin files + restart shell only
  python3 scripts/install.py --no-shortcuts   keep your own Super bindings
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ID = "lolu13.desknotes"
PLUGIN_SRC = ROOT  # the repository root is the plugin: manifest.json sits here
HELPER_DEFAULT = ROOT / "helper/target/release/desknotes-helper"
# Not needed by the shell; kept out of the installed copy.
PLUGIN_SKIP = {".git", ".codex-artifacts", "__pycache__", "target"}
SOURCE_LINE = 'dofile((os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/hypr/desknotes.lua")'


def run(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def copy_plugin(dest: Path):
    """Copy the plugin directory verbatim (the shell rejects symlinks)."""
    stage = dest.with_name(dest.name + ".desknotes-install")
    if stage.exists():
        shutil.rmtree(stage)
    shutil.copytree(PLUGIN_SRC, stage, ignore=lambda d, names: [n for n in names if n in PLUGIN_SKIP])
    if dest.exists():
        shutil.rmtree(dest)
    stage.rename(dest)


def restart_shell():
    subprocess.run(["omarchy-restart-shell"], text=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--helper", type=Path, default=HELPER_DEFAULT, help="built desknotes-helper binary")
    parser.add_argument("--no-shortcuts", action="store_true", help="install the window rule but no Super keybindings")
    parser.add_argument("--sync", action="store_true", help="only copy plugin files and restart the shell (development)")
    args = parser.parse_args()

    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share"))
    state = Path(os.environ.get("XDG_STATE_HOME", home / ".local/state"))
    plugin_dest = config / "omarchy/plugins" / PLUGIN_ID

    validation = run("omarchy-plugin-validate", str(PLUGIN_SRC), check=False)
    if validation:
        parser.error(f"plugin validation failed:\n{validation}")

    if args.sync:
        copy_plugin(plugin_dest)
        restart_shell()
        print(f"Synced {PLUGIN_SRC} -> {plugin_dest} and restarted omarchy-shell.")
        return

    if not args.helper.is_file():
        parser.error("Build the helper first:\n  cargo build --release --manifest-path helper/Cargo.toml")
    if run("hyprctl", "configerrors"):
        parser.error("Resolve existing Hyprland config errors before installing.")
    if not args.no_shortcuts:
        wanted = {(64, "N"), (72, "N"), (72, "H")}
        for binding in json.loads(run("hyprctl", "binds", "-j")):
            key = (binding["modmask"], binding["key"].upper())
            if key in wanted and not binding.get("description", "").startswith("DeskNotes:"):
                parser.error(f"Shortcut already used: {binding.get('description', key)}. Use --no-shortcuts or choose your own bindings.")

    backup = state / "desknotes-omarchy/install-backups" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup.mkdir(parents=True)
    originals = {}

    def write(path, content=None, source=None, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        # A symlinked config file (dotfile managers) is written through on purpose,
        # but only when both the link and its target belong to this user and the
        # target lives under $HOME.
        if path.is_symlink():
            target = path.resolve()
            if target.is_relative_to(home) and target.parent.is_dir() and target.parent.stat().st_uid == os.getuid():
                path = target
            else:
                raise RuntimeError(f"{path} is a symlink to {target}; refusing to write through it")
        if path not in originals:
            originals[path] = path.read_bytes() if path.exists() else None
            if path.exists():
                shutil.copy2(path, backup / f"{len(originals)}-{path.name}")
        # Exclusive random temporary beside the destination, mode set before the
        # first byte, then an atomic replace: a planted name is never followed.
        data_bytes = Path(source).read_bytes() if source else content.encode()
        fd, stage = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
        try:
            os.fchmod(fd, 0o755 if executable else 0o644)
            with os.fdopen(fd, "wb") as f:
                f.write(data_bytes)
                f.flush()
                os.fsync(f.fileno())
            os.replace(stage, path)
        except BaseException:
            try:
                os.unlink(stage)
            except OSError:
                pass
            raise

    def retire(path):
        """Back up and remove a file left by the Tauri edition."""
        if path.exists() or path.is_symlink():
            shutil.copy2(path, backup / f"retired-{path.name}", follow_symlinks=False)
            path.unlink()
            print(f"Removed {path}")

    # 1. Hyprland rule + bindings, validated with rollback.
    bindings = config / "hypr/bindings.lua"
    lua = (ROOT / "hypr/desknotes.lua").read_text()
    if args.no_shortcuts:
        lua = "\n".join(line for line in lua.splitlines() if not line.startswith("o.bind(")) + "\n"
    existing = bindings.read_text() if bindings.exists() else ""
    try:
        write(config / "hypr/desknotes.lua", lua)
        if SOURCE_LINE not in existing:
            write(bindings, existing + "\n-- DeskNotes Omarchy\n" + SOURCE_LINE + "\n")
        run("hyprctl", "reload")
        errors = run("hyprctl", "configerrors")
        if errors:
            raise RuntimeError(errors)
    except Exception:
        for path, content in originals.items():
            if content is not None:
                path.write_bytes(content)
            else:
                path.write_text("-- Installation rolled back.\n")
        run("hyprctl", "reload")
        raise

    # 2. Retire the Tauri app (binary, launcher entry, old icon). Database untouched.
    # Signal only processes whose executable really is the old binary (comm is
    # truncated to 15 chars and a -f pattern would match any command line).
    old_binary = home / ".local/bin/desknotes-omarchy"
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if os.readlink(proc / "exe") == str(old_binary) and proc.stat().st_uid == os.getuid():
                os.kill(int(proc.name), signal.SIGTERM)
        except OSError:
            continue
    retire(home / ".local/bin/desknotes-omarchy")
    retire(data / "applications/desknotes-omarchy.desktop")

    # 3. Helper, plugin, launcher entry, icon.
    write(home / ".local/bin/desknotes-helper", source=args.helper, executable=True)
    write(data / "applications/desknotes.desktop", (ROOT / "desknotes.desktop").read_text())
    write(data / "icons/hicolor/128x128/apps/desknotes-omarchy.png", source=ROOT / "icons/desknotes-omarchy.png")
    shell_config = config / "omarchy/shell.json"
    if shell_config.exists():
        shutil.copy2(shell_config, backup / "shell.json")
    copy_plugin(plugin_dest)

    # 4. Register with the shell. The shell must restart to load new QML.
    run("omarchy-shell", "shell", "rescanPlugins")
    plugins = json.loads(run("omarchy-shell", "shell", "listPlugins") or "[]")
    entry = next((p for p in plugins if p.get("id") == PLUGIN_ID), None)
    if entry is None:
        raise RuntimeError("shell did not discover the plugin after rescan")
    if not entry.get("enabled"):
        run("omarchy", "plugin", "enable", PLUGIN_ID)
    run("omarchy", "bar", "put", PLUGIN_ID, "--section", "right")
    restart_shell()

    (backup / "paths.json").write_text(json.dumps([str(p) for p in originals], indent=2))
    print(f"Installed the DeskNotes shell plugin. Backups: {backup}")
    print("Open the library: Super+N, or the bar button, or: omarchy-shell shell toggle " + PLUGIN_ID)
    if not args.no_shortcuts:
        print("Super+N: notes and stack; Super+Alt+N: new note; Super+Alt+H: stack all")


if __name__ == "__main__":
    main()
