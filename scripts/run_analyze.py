#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Run `flutter analyze` with the env the sandbox Bash lacks, dump full output
to analyze_out.txt, and print only the real error lines + summary.
Baseline: ~1950 info/warning (non-fatal). We care about `error •` lines."""
import subprocess
import sys
import os
import io

LOG = r'D:\Xiangmu\ZenFile-main\scripts\analyze_out.txt'

env = dict(os.environ)
env['LOCALAPPDATA'] = r'C:\Users\admin\AppData\Local'
env['PUB_CACHE'] = r'C:\Users\admin\AppData\Local\Pub\Cache'
env['PROGRAMFILES(X86)'] = r'C:\Program Files (x86)'

proc = subprocess.run(
    [r'D:\dev\flutter\bin\flutter.bat', 'analyze', '--no-pub',
     '--no-fatal-infos', '--no-fatal-warnings'],
    cwd=r'D:\Xiangmu\ZenFile-main',
    env=env,
    capture_output=True,
    text=True,
    encoding='utf-8',
    errors='replace',
)

out = proc.stdout + proc.stderr
with io.open(LOG, 'w', encoding='utf-8') as f:
    f.write(out)

err_lines = [ln for ln in out.splitlines() if 'error •' in ln]
print('EXIT CODE:', proc.returncode)
print('TOTAL RAW CHARS:', len(out))
print('REAL ERROR LINES (error •):', len(err_lines))
print('---- error lines ----')
for ln in err_lines:
    print(ln.strip())
print('---- last 3 lines of output ----')
for ln in out.splitlines()[-3:]:
    print(ln.strip())
