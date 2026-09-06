#!/usr/bin/env python3
"""Run QML regressions through the project's activation-free isolated harness."""
import json,os,shlex,subprocess,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
profile='qml-regression-'+str(time.time_ns())
folder=ROOT/'.codex-artifacts'/profile;folder.mkdir(parents=True)
harness=ROOT/'scripts/isolated-app-session.py'
runner=Path('/usr/lib/qt6/bin/qmltestrunner')
if not runner.exists():raise SystemExit('Qt 6 qmltestrunner is required for Omarchy QML tests.')
wrapper=folder/'run.sh';result=folder/'exit-code'
command=[str(runner),'-input',str(ROOT/'tests'),'-o',str(folder/'results.txt')+',txt']
wrapper.write_text('#!/bin/sh\nunset WAYLAND_DISPLAY\nexport QT_QPA_PLATFORM=offscreen\nexport QT_QUICK_BACKEND=software\nexport QT_QPA_PLATFORMTHEME=generic\n'+shlex.join(command)+'\nstatus=$?\nprintf "%s\\n" "$status" > '+shlex.quote(str(result))+'\nexit "$status"\n')
wrapper.chmod(0o755)
try:
    subprocess.run(['python3',str(harness),'start',profile,'--binary',str(wrapper)],check=True)
    session=json.loads((folder/'session.json').read_text())
    # Any external driver must use the same private session; the QML driver
    # already inherits these overrides as the harness's child process.
    driver_env={**os.environ,**session['env']}
    assert driver_env['DBUS_SESSION_BUS_ADDRESS']==session['bus']
    assert Path(driver_env['XDG_DATA_HOME']).is_relative_to(folder)
    deadline=time.monotonic()+120
    while not result.exists() and time.monotonic()<deadline:time.sleep(.1)
    if not result.exists():raise RuntimeError('QML regression run timed out; see '+str(folder/'runtime.log'))
    report=folder/'results.txt'
    print(report.read_text() if report.exists() else (folder/'runtime.log').read_text())
    code=int(result.read_text())
finally:
    if (folder/'session.json').exists():subprocess.run(['python3',str(harness),'stop',profile],check=True)
raise SystemExit(code)
