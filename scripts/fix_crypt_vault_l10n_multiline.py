#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""补漏：dart 里折行 getter（String get key =>\n  '...';）的多行替换。
复用 fix_crypt_vault_l10n.py 的 FIX_TABLES。幂等：已替换的值再次替换结果不变。"""
import importlib.util
import io
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(os.path.dirname(HERE), 'lib', 'l10n', 'generated')

spec = importlib.util.spec_from_file_location('fixmod', os.path.join(HERE, 'fix_crypt_vault_l10n.py'))
fixmod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixmod)


def esc(s):
    return s.replace('\\', '\\\\').replace("'", "\\'")


def main():
    for lang, table in fixmod.FIX_TABLES.items():
        path = os.path.join(GEN, 'app_localizations_%s.dart' % lang)
        with io.open(path, 'rb') as f:
            data = f.read()
        text = data.decode('utf-8')
        count = 0
        for key, val in table.items():
            if key in fixmod.TECH_KEYS:
                continue
            esc_val = esc(val)
            # 多行 getter：String get key =>\n    '...';
            pat = re.compile(r"(String get %s =>\s*')(?:[^'\\]|\\.)*(';)" % re.escape(key), re.S)
            text, n = pat.subn(lambda m: m.group(1) + esc_val + m.group(2), text, count=1)
            if n == 0:
                # 单行（可能上轮已改）：仅当仍是英文旧值才需要（幂等，跳过）
                pat1 = re.compile(r"(String get %s => ')(?:[^'\\]|\\.)*(';)" % re.escape(key))
                text, n = pat1.subn(lambda m: m.group(1) + esc_val + m.group(2), text, count=1)
            if n == 0:
                print('  !! still not found: %s in %s' % (key, lang))
            count += n
        with io.open(path, 'wb') as f:
            f.write(text.encode('utf-8'))
        print('DART-ML %-6s %d keys' % (lang, count))


if __name__ == '__main__':
    main()
