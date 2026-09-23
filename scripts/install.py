#!/usr/bin/env python3
"""Install the Onote shell plugin and its database helper.

Replaces the earlier Tauri-based app on this machine: its binary, desktop entry
and icon are backed up and removed. The notes database is never touched.

  python3 scripts/install.py                  full install (or upgrade)
  python3 scripts/install.py --sync           dev: copy plugin files + restart shell only
  python3 scripts/install.py --no-shortcuts   keep your own Super bindings
"""
import argparse, time
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ID = "io.github.lolu13.onote"
PLUGIN_SRC = ROOT  # the repository root is the plugin: manifest.json sits here
# Without --helper: the build in this tree (the README's first build) or, only
# when this tree is the installed plugin itself, the cache directory update.py
# builds that tree into. A cache build never pairs with another checkout.
HELPER_IN_TREE = ROOT / "helper/target/release/onote-helper"
HELPER_CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "onote/cargo-target/release/onote-helper"
# Not needed by the shell; kept out of the installed copy.
PLUGIN_SKIP = {".git", ".codex-artifacts", "__pycache__", "target"}
# Owned by the destination, never by the copy: the helper's build output. The
# destination's .git is deliberately NOT kept: a copy from another source tree
# over a checkout would leave git describing files it never had, and the
# update check would then offer updates the updater cannot apply. A copy is
# not a checkout; only the in-place install (from `omarchy plugin add`) is.
PLUGIN_KEEP = ["helper/target"]
# ...minus the helper it built: that binary belongs to the tree it replaces, and
# a later flagless install from the destination would otherwise pick it up and
# pair it with this tree's QML. The incremental build cache stays.
PLUGIN_KEEP_DROP = ["helper/target/release/onote-helper"]
SOURCE_LINE = 'dofile((os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/hypr/onote.lua")'


def run(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def copy_plugin(dest: Path) -> bool:
    """Copy the plugin directory verbatim (the shell rejects symlinks).

    Run from the installed checkout itself (the marketplace flow: `omarchy
    plugin add`, build, install) there is nothing to copy; returns False."""
    if PLUGIN_SRC.resolve() == dest.resolve():
        return False
    # A dot name: the shell's plugin scan and its file watcher skip those, so
    # a half-copied stage is never listed as a second plugin with this id.
    stage = dest.with_name("." + dest.name + ".onote-install")
    if stage.exists():
        shutil.rmtree(stage)
    moved = []
    try:
        shutil.copytree(PLUGIN_SRC, stage, ignore=lambda d, names: [n for n in names if n in PLUGIN_SKIP])
        for rel in PLUGIN_KEEP:
            kept = dest / rel
            if kept.is_dir() and not kept.is_symlink():
                (stage / rel).parent.mkdir(parents=True, exist_ok=True)
                kept.rename(stage / rel)
                moved.append(rel)
        for rel in PLUGIN_KEEP_DROP:
            stale = stage / rel
            if stale.is_file() or stale.is_symlink():
                stale.unlink()
        if dest.exists():
            shutil.rmtree(dest)
        stage.rename(dest)
    except BaseException:
        # Nothing half done is left where the shell looks: the kept folders go
        # back and the stage goes.
        for rel in moved:
            if dest.exists() and (stage / rel).exists() and not (dest / rel).exists():
                (stage / rel).rename(dest / rel)
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return True


def wait_for_plugin(timeout_s: float = 2.0):
    """The shell's rescan is deferred and parses a `find` on exit: a list asked
    right after it can be the previous scan (Omarchy's own `plugin add` polls
    the same way). Returns the entry, or None."""
    deadline = time.monotonic() + timeout_s
    while True:
        plugins = json.loads(run("omarchy-shell", "shell", "listPlugins") or "[]")
        entry = next((p for p in plugins if p.get("id") == PLUGIN_ID), None)
        if entry is not None or time.monotonic() >= deadline:
            return entry
        time.sleep(0.05)


def installed_revision(dest: Path):
    """The commit the installed plugin is at, "" when it is a copy, not a checkout."""
    if not (dest / ".git").is_dir():
        return ""
    return run("git", "-c", "core.hooksPath=/dev/null", "-C", str(dest), "rev-parse", "HEAD", check=False)


def restart_shell():
    # A refused restart (session locked) or a shell that does not come back
    # must stop the install: the old app is retired only after this.
    run("omarchy-restart-shell")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--helper", type=Path, default=None, help="built onote-helper binary (default: the newest build)")
    parser.add_argument("--no-shortcuts", action="store_true", help="install the window rule but no Super keybindings")
    parser.add_argument("--shortcuts", action="store_true", help="install the Super keybindings again after an earlier --no-shortcuts")
    parser.add_argument("--sync", action="store_true", help="only copy plugin files and restart the shell (development)")
    args = parser.parse_args()

    home = Path.home()
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share"))
    state = Path(os.environ.get("XDG_STATE_HOME", home / ".local/state"))
    plugin_dest = config / "omarchy/plugins" / PLUGIN_ID
    # The choice made at the first install holds for every later one (an
    # update re-runs this script without flags) until --shortcuts or
    # --no-shortcuts says otherwise.
    choices = state / "onote/install.json"
    if not args.no_shortcuts and not args.shortcuts and choices.is_file():
        try:
            args.no_shortcuts = bool(json.loads(choices.read_text()).get("no_shortcuts"))
        except (OSError, ValueError, AttributeError):
            pass
    if args.no_shortcuts and not args.sync:
        print("Installing without the Super keybindings (pass --shortcuts to add them).")

    # The validator answers with its exit code and puts every diagnostic on
    # stderr (its stdout is always empty): only the code says whether it passed.
    validation = subprocess.run(["omarchy-plugin-validate", str(PLUGIN_SRC)], text=True, capture_output=True)
    if validation.returncode != 0:
        parser.error(f"plugin validation failed:\n{(validation.stderr or validation.stdout).strip()}")

    if args.sync:
        copied = copy_plugin(plugin_dest)
        restart_shell()
        print(f"Synced {PLUGIN_SRC} -> {plugin_dest} and restarted omarchy-shell." if copied
              else "Plugin already in place; restarted omarchy-shell.")
        return

    if args.helper is None:
        candidates = [HELPER_IN_TREE]
        if PLUGIN_SRC.resolve() == plugin_dest.resolve():
            candidates.append(HELPER_CACHE)
        built = [p for p in candidates if p.is_file()]
        args.helper = max(built, key=lambda p: p.stat().st_mtime) if built else HELPER_IN_TREE
        if built:
            print(f"Helper: {args.helper}")
    if not args.helper.is_file():
        parser.error("Build the helper first:\n  cargo build --release --manifest-path helper/Cargo.toml")
    if run("hyprctl", "configerrors"):
        parser.error("Resolve existing Hyprland config errors before installing.")
    if not args.no_shortcuts:
        # Every binding onote.lua installs, as Hyprland reports it (modmask, key),
        # read from the file so the check cannot drift from what is written.
        masks = {"SUPER": 64, "ALT": 8, "SHIFT": 1, "CTRL": 4}
        wanted = set()
        for chord in re.findall(r'^o\.bind\("([^"]+)"', (ROOT / "hypr/onote.lua").read_text(), re.M):
            parts = [p.strip().upper() for p in chord.split("+")]
            wanted.add((sum(masks[m] for m in parts[:-1]), parts[-1]))
        for binding in json.loads(run("hyprctl", "binds", "-j")):
            key = (binding["modmask"], binding["key"].upper())
            if key in wanted and not binding.get("description", "").startswith("Onote:"):
                parser.error(f"Shortcut already used: {binding.get('description', key)}. Use --no-shortcuts or choose your own bindings.")

    backup = state / "onote/install-backups" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
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
    lua = (ROOT / "hypr/onote.lua").read_text()
    if args.no_shortcuts:
        lua = "\n".join(line for line in lua.splitlines() if not line.startswith("o.bind(")) + "\n"
    existing = bindings.read_text() if bindings.exists() else ""
    try:
        write(config / "hypr/onote.lua", lua)
        if SOURCE_LINE not in existing:
            write(bindings, existing + "\n-- Onote\n" + SOURCE_LINE + "\n")
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

    # Steps 2-3 have no rollback, so say where the backups are before failing;
    # re-running the installer finishes the job.
    try:
        # 2. Helper, plugin, launcher entry, icon.
        write(home / ".local/bin/onote-helper", source=args.helper, executable=True)
        write(data / "applications/onote.desktop", (ROOT / "onote.desktop").read_text())
        write(data / "icons/hicolor/128x128/apps/onote.png", source=ROOT / "icons/onote.png")
        shell_config = config / "omarchy/shell.json"
        if shell_config.exists():
            shutil.copy2(shell_config, backup / "shell.json")
        copy_plugin(plugin_dest)

        # 3. Register with the shell. The shell must restart to load new QML.
        run("omarchy-shell", "shell", "rescanPlugins")
        entry = wait_for_plugin()
        if entry is None:
            raise RuntimeError("shell did not discover the plugin after rescan")
        if not entry.get("enabled"):
            run("omarchy", "plugin", "enable", PLUGIN_ID)
        run("omarchy", "bar", "put", PLUGIN_ID, "--section", "right")
        restart_shell()
    except Exception:
        print(f"Install stopped before finishing. Backups: {backup}. Run install.py again to complete it.")
        raise

    # 4. Retire the Tauri app (binary, launcher entry), only once Onote is registered
    # and running, so a failed install never leaves neither. Database untouched.
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

    (backup / "paths.json").write_text(json.dumps([str(p) for p in originals], indent=2))
    write(choices, json.dumps({"no_shortcuts": args.no_shortcuts, "installed": installed_revision(plugin_dest)}) + "\n")
    print(f"Installed the Onote shell plugin. Backups: {backup}")
    print("Open the library: Super+N, or the bar button, or: omarchy-shell shell toggle " + PLUGIN_ID)
    if not args.no_shortcuts:
        print("Super+N: notes and stack; Super+Alt+N: new note; Super+Alt+V: note from clipboard; "
              "Super+Alt+H: hide the focused note; Super+Alt+Shift+H: hide all; Super+Alt+P: pin")


if __name__ == "__main__":
    main()
