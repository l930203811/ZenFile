#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Run `flutter analyze` with the env the sandbox Bash lacks, dump full output
to analyze_out.txt, and print only the real error lines + summary.
Baseline: ~1950 info/warning (non-fatal). We care about `error` lines.

⚠️ 2026-09-20 修正：flutter analyze 默认输出用的是 ` - ` 分隔（`error - msg - file - code`），
不是 `•`。旧版过滤串 `'error •'` 永远匹配不到 → 会**误报 0 error**（曾因此漏掉真实语法错误
直到 release 构建才炸）。现在按行首 `error` 匹配，并在末尾打印 EXIT CODE 的含义：
退出码 0 = 无 error（只有 info/warning）；非 0 = 真有 error。
"""
import re
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

# 同时兼容 ` - ` 与 `•` 两种分隔形式
ERR_RE = re.compile(r'^\s*error\s*[-\u2022]\s')
err_lines = [ln for ln in out.splitlines() if ERR_RE.match(ln)]
print('EXIT CODE:', proc.returncode, '(0 = 无 error；非 0 = 有 error)')
print('TOTAL RAW CHARS:', len(out))
print('REAL ERROR LINES:', len(err_lines))
print('---- error lines ----')
for ln in err_lines:
    print(ln.strip())
print('---- last 3 lines of output ----')
for ln in out.splitlines()[-3:]:
    print(ln.strip())
