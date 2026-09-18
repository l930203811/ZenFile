#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import io, re
p = r'D:\Xiangmu\ZenFile-main\lib\l10n\generated\app_localizations_zh.dart'
t = io.open(p, encoding='utf-8').read()
i = t.index('class L10nZhTw extends L10nZh {')
head, tw = t[:i], t[i:]
pat = re.compile(r"String get (\w+) =>\s*'((?:[^'\\]|\\.)*)';", re.S)
for label, seg in (('ZH(simplified)', head), ('TW(traditional)', tw)):
    for k in ['ui_test_failed', 'ui_backup', 'cl213_features']:
        m = pat.search('')  # placeholder
    print('---', label)
    for m in pat.finditer(seg):
        if m.group(1) in ('ui_test_failed', 'ui_backup', 'cl213_features', 'remote_err_auth'):
            print(' ', m.group(1), '=', m.group(2)[:40])
