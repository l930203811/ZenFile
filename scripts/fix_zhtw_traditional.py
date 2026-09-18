#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Convert zh_TW l10n from Simplified to Traditional (Taiwan, phrase-aware).
- ARB: app_zh_TW.arb  (targeted regex, CRLF preserved, no reformat)
- generated: app_localizations_zh.dart, only inside `class L10nZhTw`
Values already Traditional pass through unchanged.
"""
import io, re, json, os
from opencc import OpenCC

cc = OpenCC('s2twp')
ARB = r'D:\Xiangmu\ZenFile-main\lib\l10n\app_zh_TW.arb'
DART = r'D:\Xiangmu\ZenFile-main\lib\l10n\generated\app_localizations_zh.dart'

# ---------- ARB ----------
with io.open(ARB, 'r', encoding='utf-8', newline='') as f:
    raw = f.read()
data = json.load(io.open(ARB, encoding='utf-8'))
n_arb = 0
for key in list(data.keys()):
    if key.startswith('@'):
        continue
    val = data[key]
    if not isinstance(val, str):
        continue
    new = cc.convert(val)
    if new == val:
        continue
    pat = re.compile(r'("' + re.escape(key) + r'"\s*:\s*")((?:[^"\\]|\\.)*)(")')
    m = pat.search(raw)
    if not m:
        print('  [ARB] MISS', key)
        continue
    raw = pat.sub(lambda mm: mm.group(1) + new.replace('\\', '\\\\').replace('"', '\\"') + mm.group(3), raw, count=1)
    n_arb += 1
with io.open(ARB, 'w', encoding='utf-8', newline='') as f:
    f.write(raw)
json.load(io.open(ARB, encoding='utf-8'))
print('ARB converted:', n_arb)

# ---------- DART (only L10nZhTw region) ----------
with io.open(DART, 'r', encoding='utf-8', newline='') as f:
    txt = f.read()
idx = txt.index('class L10nZhTw extends L10nZh {')
head, tail = txt[:idx], txt[idx:]

GET = re.compile(r"(String get \w+ =>\s*')((?:[^'\\]|\\.)*)(';)", re.S)
METH = re.compile(r"(String \w+\([^)]*\) \{\s*return\s*')((?:[^'\\]|\\.)*)(';)", re.S)

n_get = n_meth = 0
def conv(m):
    return m.group(1) + cc.convert(m.group(2)) + m.group(3)
tail, n_get = GET.subn(conv, tail)
tail, n_meth = METH.subn(conv, tail)

with io.open(DART, 'w', encoding='utf-8', newline='') as f:
    f.write(head + tail)
print('DART getters converted:', n_get, ' methods converted:', n_meth)
