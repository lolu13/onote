#!/usr/bin/env python3
"""Update Onote to the newest published commit, in a terminal you can watch.

  python3 scripts/update.py            update if a newer commit is published
  python3 scripts/update.py --force    rebuild and reinstall the current commit

Three steps, each of them the same command the README's install section uses:
  1. `omarchy plugin update io.github.lolu13.onote` (Omarchy's own updater:
     it shows the diff and asks before fast-forwarding, validates the tree
     and rolls back if validation fails),
  2. `cargo build --release --locked --manifest-path helper/Cargo.toml`
     with the build output under ~/.cache/onote (the shell watches the plugin
     directory and would reload on every artifact written there),
  3. `python3 scripts/install.py`, which copies the helper, refreshes the
     Hyprland rule and bindings (keeping the choices of the first install)
     and restarts the shell.
The shell's red square (bottom-right corner) and `omarchy-shell onote update`
open this script in a floating terminal.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN_ID = "io.github.lolu13.onote"


def say(text=""):
    print(text, flush=True)


def pause(code):
    # The terminal closes with the script: keep the outcome on screen.
    try:
        input("\nPress Enter to close this window.")
    except (EOFError, KeyboardInterrupt):
        pass
    sys.exit(code)


def git(*args):
    r = subprocess.run(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", str(ROOT), *args],
                       text=True, capture_output=True, timeout=120)
    return r.returncode, r.stdout.strip()


def find_cargo():
    """rustup's cargo, one on PATH, or mise's; each only tried when present."""
    rustup = Path.home() / ".cargo/bin/cargo"
    candidates = []
    if rustup.is_file():
        candidates.append([str(rustup)])
    if shutil.which("cargo"):
        candidates.append(["cargo"])
    if shutil.which("mise"):
        candidates.append(["mise", "exec", "rust@stable", "--", "cargo"])
    for cmd in candidates:
        try:
            r = subprocess.run([*cmd, "--version"], text=True, capture_output=True, timeout=15)
        except (OSError, subprocess.SubprocessError):
            continue
        if r.returncode == 0 and r.stdout.startswith("cargo "):
            return cmd
    return None


def main():
    force = "--force" in sys.argv[1:]
    say(f"Onote update · {ROOT}")
    plugin_dir = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "omarchy/plugins" / PLUGIN_ID
    if ROOT.resolve() != plugin_dir.resolve():
        say(f"\nThis script must run from the installed plugin, {plugin_dir}, because that is what")
        say("`omarchy plugin update` updates. From a source checkout use `python3 scripts/install.py` instead.")
        pause(1)
    if not (ROOT / ".git").is_dir():
        say("\nThis copy of Onote is not a git checkout, so there is nothing to pull from.")
        say("It was installed by copying files (install.py --sync). To get updates, reinstall from git:")
        say(f"  omarchy plugin remove {PLUGIN_ID}")
        say("  omarchy plugin add https://github.com/lolu13/onote.git")
        say(f"  cd ~/.config/omarchy/plugins/{PLUGIN_ID}")
        say("  cargo build --release --locked --manifest-path helper/Cargo.toml && python3 scripts/install.py")
        say("Your notes are not touched by any of this.")
        pause(1)
    code, before = git("rev-parse", "HEAD")
    if code != 0:
        say("git cannot read this checkout; nothing was changed.")
        pause(1)
    # What install.py last put in place; a merge that was never built or
    # installed (a failed cargo run, a closed window) leaves this behind HEAD.
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "onote/install.json"
    try:
        installed = str(json.loads(state.read_text()).get("installed", ""))
    except (OSError, ValueError, AttributeError):
        installed = ""

    say("\n1/3  omarchy plugin update (shows the diff and asks first)\n")
    r = subprocess.run(["omarchy", "plugin", "update", PLUGIN_ID])
    if r.returncode != 0:
        say("\nThe updater did not finish; nothing else was changed.")
        pause(r.returncode)
    after = git("rev-parse", "HEAD")[1]
    # The updater fetched and asked; a "No" leaves HEAD where it was while
    # FETCH_HEAD (the updater's, the shell's check never writes it) is ahead.
    fetched = git("rev-parse", "FETCH_HEAD")[1] if git("rev-parse", "--verify", "-q", "FETCH_HEAD")[0] == 0 else ""
    if after == before and after == installed and fetched and fetched != after and not force:
        say(f"\nThe update to {fetched[:7]} was skipped; nothing was changed. Run this again and confirm to apply it.")
        pause(0)
    if after == installed and not force:
        say("\nAlready on the newest published commit, and it is installed. Nothing to rebuild.")
        say("(Run with --force to rebuild and reinstall this commit anyway.)")
        pause(0)
    if after == before and after != installed:
        say(f"\nCommit {after[:7]} was fetched earlier but never finished installing; finishing now.")

    say(f"\n2/3  building the helper ({'same commit, forced' if after == before else before[:7] + ' -> ' + after[:7]})\n")
    cargo = find_cargo()
    if cargo is None:
        say("cargo was not found (~/.cargo/bin/cargo, PATH, or mise). Install a Rust toolchain, then run:")
        say(f"  python3 {ROOT}/scripts/update.py --force")
        pause(1)
    # Built outside the plugin directory: the shell watches it and reloads the
    # plugin on every file that appears, which would churn the note windows.
    target = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "onote/cargo-target"
    r = subprocess.run([*cargo, "build", "--release", "--locked", "--manifest-path", str(ROOT / "helper/Cargo.toml"),
                        "--target-dir", str(target)])
    if r.returncode != 0:
        say("\nThe helper did not build. The plugin files are already updated, but the old helper stays in")
        say("place until a build succeeds; if the shell reports a protocol error, run this again after fixing the build.")
        pause(r.returncode)

    say("\n3/3  installing the helper and restarting the shell\n")
    r = subprocess.run([sys.executable, str(ROOT / "scripts/install.py"), "--helper", str(target / "release/onote-helper")])
    if r.returncode != 0:
        say("\nInstall failed; see the messages above. Backups are listed in ~/.local/state/onote/install-backups/.")
        pause(r.returncode)
    say(f"\nOnote is now at {after[:7]}.")
    pause(0)


if __name__ == "__main__":
    main()
