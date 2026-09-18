#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Scan non-zh ARB locales for values that contain CJK (Chinese placeholder) text."""
import json, io, re, os

LANGS = ['en','ko','ja','de','fr','es','ru','ar','zh_TW']
DIR = r'D:\Xiangmu\ZenFile-main\lib\l10n'
CJK = re.compile(r'[\u4e00-\u9fff]')

out = io.open(r'D:\Xiangmu\ZenFile-main\scripts\cjk_scan.txt', 'w', encoding='utf-8')
for lang in LANGS:
    path = os.path.join(DIR, f'app_{lang}.arb')
    with io.open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    hits = []
    for k, v in data.items():
        if k.startswith('@'):
            continue
        if isinstance(v, str) and CJK.search(v):
            hits.append((k, v))
    out.write(f'== {lang}: {len(hits)} keys with CJK values ==\n')
    for k, v in hits:
        out.write(f'  {k} = {v[:80]}\n')
out.close()
print('done')
