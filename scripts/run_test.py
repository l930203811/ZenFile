#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Run `flutter test` with the env the sandbox Bash lacks.

Usage:  python scripts/run_test.py [<test path or args> ...]
Default target: test/remote/netbios_nbstat_test.dart
Prints the tail of the output (pass/fail summary included)."""
import subprocess
import sys
import os

env = dict(os.environ)
env['LOCALAPPDATA'] = r'C:\Users\admin\AppData\Local'
env['PUB_CACHE'] = r'C:\Users\admin\AppData\Local\Pub\Cache'
env['PROGRAMFILES(X86)'] = r'C:\Program Files (x86)'

args = sys.argv[1:] or [r'test/remote/netbios_nbstat_test.dart']

proc = subprocess.run(
    [r'D:\dev\flutter\bin\flutter.bat', 'test', '--no-pub', *args],
    cwd=r'D:\Xiangmu\ZenFile-main',
    env=env,
    capture_output=True,
    text=True,
    encoding='utf-8',
    errors='replace',
)

out = (proc.stdout or '') + (proc.stderr or '')
print('EXIT CODE:', proc.returncode)
print('---- last 60 lines ----')
for ln in out.splitlines()[-60:]:
    print(ln.rstrip())
