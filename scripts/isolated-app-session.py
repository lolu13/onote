#!/usr/bin/env python3
"""Run DeskNotes in an isolated profile on a private, activation-free D-Bus.

Why this exists: earlier test runs started `dbus-daemon --session`, which
auto-launched xdg-desktop-portal(-hyprland), xdg-document-portal and the
at-spi broker on the throwaway bus. Killing the bus then crashed
xdg-desktop-portal-hyprland (SIGSEGV on exit, upstream #330) and left the real
session's xdg-document-portal.service failed. This script uses
scripts/isolated-dbus.conf, which cannot activate services, and tears down in
the right order.

Usage:
  scripts/isolated-app-session.py start <profile> [--binary PATH] [-- APP ARGS...]
  scripts/isolated-app-session.py run   <profile> -- APP ARGS...     # e.g. -- --settings
  scripts/isolated-app-session.py env   <profile>                    # KEY=VALUE lines
  scripts/isolated-app-session.py stop  <profile>

<profile> is a name; its data, config and state live in
.codex-artifacts/<profile>/ (gitignored). session.json there records the bus
address, bus pid and app pid, so later commands and other scripts can reuse it:

  s = json.load(open('.codex-artifacts/<profile>/session.json'))
  env = dict(os.environ, **s['env'])
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BUS_CONF = REPO / "scripts" / "isolated-dbus.conf"
ARTIFACTS = REPO / ".codex-artifacts"
DEFAULT_BINARIES = [
    REPO / "src-tauri" / "target" / "debug" / "desknotes-omarchy",
    Path.home() / ".local" / "bin" / "desknotes-omarchy",
]


def profile_root(name: str) -> Path:
    if not name or "/" in name or name.startswith("."):
        sys.exit(f"invalid profile name: {name!r}")
    return ARTIFACTS / name


def session_path(root: Path) -> Path:
    return root / "session.json"


def load_session(root: Path) -> dict:
    p = session_path(root)
    if not p.exists():
        sys.exit(f"no session at {p}; run 'start' first")
    return json.loads(p.read_text())


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def kill_group(pid: int, label: str, grace: float = 3.0) -> None:
    """SIGTERM a process group (falls back to the pid), SIGKILL survivors."""
    if not alive(pid):
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            return
        except PermissionError:
            os.kill(pid, sig)
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            if not alive(pid):
                return
            time.sleep(0.05)
        print(f"{label} {pid} ignored SIGTERM, killing", file=sys.stderr)


def start_bus() -> tuple[str, int]:
    out = subprocess.check_output(
        ["dbus-daemon", f"--config-file={BUS_CONF}", "--fork",
         "--print-address=1", "--print-pid=1"],
        text=True,
    ).splitlines()
    return out[0], int(out[1])


def resolve_binary(explicit: str | None) -> str:
    if explicit:
        return str(Path(explicit).resolve())
    for candidate in DEFAULT_BINARIES:
        if candidate.exists():
            return str(candidate)
    sys.exit("no desknotes-omarchy binary found; pass --binary")


def session_env(s: dict) -> dict:
    return dict(os.environ, **s["env"])


def cmd_start(args) -> None:
    root = profile_root(args.profile)
    if session_path(root).exists():
        old = load_session(root)
        if alive(old["bus_pid"]) or alive(old["pid"]):
            sys.exit(f"profile {args.profile} still running; 'stop' it first")
    root.mkdir(parents=True, exist_ok=True)
    binary = resolve_binary(args.binary)
    address, bus_pid = start_bus()
    env_overrides = {
        "DBUS_SESSION_BUS_ADDRESS": address,
        "XDG_DATA_HOME": str(root / "data"),
        "XDG_CONFIG_HOME": str(root / "config"),
        "XDG_STATE_HOME": str(root / "state"),
        "NO_AT_BRIDGE": "1",  # no a11y bus on this D-Bus; skip the AT-SPI lookup warning
    }
    env = dict(os.environ, **env_overrides)
    log = open(root / "runtime.log", "a")
    app = subprocess.Popen(
        [binary, *args.app_args], env=env, stdout=log, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    session = {
        "profile": args.profile, "root": str(root), "binary": binary,
        "bus": address, "bus_pid": bus_pid, "pid": app.pid, "env": env_overrides,
    }
    session_path(root).write_text(json.dumps(session, indent=1))
    print(f"started {args.profile}: app pid {app.pid}, bus pid {bus_pid}")


def cmd_run(args) -> None:
    s = load_session(profile_root(args.profile))
    sys.exit(subprocess.run([s["binary"], *args.app_args], env=session_env(s)).returncode)


def cmd_env(args) -> None:
    s = load_session(profile_root(args.profile))
    for k, v in s["env"].items():
        print(f"{k}={v}")


def repair_document_portal() -> None:
    """Safety net for runs made with the old activation-enabled bus."""
    failed = subprocess.run(
        ["systemctl", "--user", "is-failed", "--quiet", "xdg-document-portal.service"]
    ).returncode == 0
    if failed:
        subprocess.run(["systemctl", "--user", "restart", "xdg-document-portal.service"])
        print("restarted xdg-document-portal.service (was failed)")


def cmd_stop(args) -> None:
    root = profile_root(args.profile)
    s = load_session(root)
    kill_group(s["pid"], "app")          # app first, so it disconnects cleanly
    kill_group(s["bus_pid"], "dbus")     # then the bus and anything it owns
    session_path(root).unlink()
    repair_document_portal()
    print(f"stopped {args.profile}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("start", help="start a private bus and the app")
    sp.add_argument("profile")
    sp.add_argument("--binary", help="app binary (default: debug build, then ~/.local/bin)")
    sp.add_argument("app_args", nargs="*", help="arguments for the app, after --")
    sp.set_defaults(fn=cmd_start)
    rp = sub.add_parser("run", help="run the app binary inside an existing session")
    rp.add_argument("profile")
    rp.add_argument("app_args", nargs="*")
    rp.set_defaults(fn=cmd_run)
    ep = sub.add_parser("env", help="print the session's environment overrides")
    ep.add_argument("profile")
    ep.set_defaults(fn=cmd_env)
    st = sub.add_parser("stop", help="stop the app, then the bus")
    st.add_argument("profile")
    st.set_defaults(fn=cmd_stop)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
