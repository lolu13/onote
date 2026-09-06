#!/usr/bin/env python3
"""Run the QML regression suite offscreen with qmltestrunner.

The runner gets a throwaway XDG_DATA_HOME and no session bus, so nothing it
does can reach the real shell, portals or notes.
"""
import os, shlex, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
runner = Path("/usr/lib/qt6/bin/qmltestrunner")
if not runner.exists():
    sys.exit("Qt 6 qmltestrunner is required for the QML tests.")
with tempfile.TemporaryDirectory(prefix="onote-qml-") as tmp:
    tmp = Path(tmp)
    report = tmp / "results.txt"
    env = {
        "HOME": str(tmp), "XDG_DATA_HOME": str(tmp / "data"), "XDG_CONFIG_HOME": str(tmp / "config"),
        "XDG_CACHE_HOME": str(tmp / "cache"), "XDG_RUNTIME_DIR": str(tmp / "run"),
        "DBUS_SESSION_BUS_ADDRESS": "disabled:", "PATH": "/usr/bin",
        "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software", "QT_QPA_PLATFORMTHEME": "generic",
    }
    (tmp / "run").mkdir(mode=0o700)
    cmd = [str(runner), "-input", str(ROOT / "tests"), "-o", f"{report},txt"]
    code = subprocess.run(cmd, env=env, cwd=tmp, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT).returncode
    print(report.read_text() if report.exists() else f"{shlex.join(cmd)} produced no report")
raise SystemExit(code)
