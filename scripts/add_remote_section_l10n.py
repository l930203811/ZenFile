#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""插入保险箱首页「远程加密」区域标题 key: vault_remote_encrypt。

铁律（与 add_remote_crypt_io_l10n.py 一致）：
- lib/l10n/app_*.arb 用 CRLF，lib/l10n/generated/*.dart 用 LF → 全程二进制读写。
- 按锚点（crypt_settings_title）插入，不重跑 gen-l10n。
- zh.dart 里锚点出现两次（L10nZh、L10nZhTw）：第一次 zh，第二次 zh_TW。
- 纯字符串 getter（dart 侧 `String get xxx => '...';`）。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

KEY = 'vault_remote_encrypt'

LANGS = {
    'en': 'Remote Encryption',
    'zh': '远程加密',
    'zh_TW': '遠端加密',
    'ja': 'リモート暗号化',
    'ko': '원격 암호화',
    'de': 'Remote-Verschlüsselung',
    'es': 'Cifrado remoto',
    'fr': 'Chiffrement distant',
    'ru': 'Удалённое шифрование',
    'ar': 'تشفير بعيد',
}
# zh.dart 双类（L10nZh / L10nZhTw）分别用 zh / zh_TW
ZH = LANGS['zh']
ZH_TW = LANGS['zh_TW']

DART_LOCALES = ['en', 'zh', 'ar', 'de', 'es', 'fr', 'ja', 'ko', 'ru']


def read_bytes(path):
    with io.open(path, 'rb') as f:
        return f.read()


def write_bytes(path, data):
    with io.open(path, 'wb') as f:
        f.write(data)


def esc(s):
    return s.replace('\\', '\\\\').replace("'", "\\'")


def insert_arb(lang, value):
    path = os.path.join(ARB_DIR, 'app_%s.arb' % lang)
    data = read_bytes(path)
    nl = b'\r\n' if b'\r\n' in data else b'\n'
    text = data.decode('utf-8')

    anchor = '"@crypt_settings_title"'
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit('anchor not found in %s' % path)
    end = text.find('\n  },', idx)
    if end < 0:
        end = text.find('\n  }', idx)
        if end < 0:
            raise SystemExit('meta end not found in %s' % path)
        end += len('\n  }')
    else:
        end += len('\n  },')

    block = '\n'.join([
        '  "%s": "%s",' % (KEY, value.replace('"', '\\"')),
        '  "@%s": {' % KEY,
        '    "description": "crypt: %s"' % KEY,
        '  },',
    ]).replace('\n', nl.decode('utf-8'))

    text = text[:end] + nl.decode('utf-8') + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    with io.open(path, 'r', encoding='utf-8') as f:
        json.load(f)
    print('ARB  %-8s +1 key' % lang)


def insert_base():
    path = os.path.join(GEN_DIR, 'app_localizations.dart')
    data = read_bytes(path)
    nl = b'\r\n' if b'\r\n' in data else b'\n'
    text = data.decode('utf-8')

    anchor = '  String get crypt_settings_title;'
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit('anchor not found in base')
    end = idx + len(anchor)

    block = ('\n\n  /// No description provided for @%s.\n  String get %s;'
             % (KEY, KEY)).replace('\n', nl.decode('utf-8'))
    text = text[:end] + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    print('BASE app_localizations.dart +1 key')


def insert_locale(lang):
    path = os.path.join(GEN_DIR, 'app_localizations_%s.dart' % lang)
    data = read_bytes(path)
    nl = b'\r\n' if b'\r\n' in data else b'\n'
    text = data.decode('utf-8')

    anchor = "  String get crypt_settings_title => '"
    occurrences = []
    pos = text.find(anchor)
    while pos >= 0:
        occurrences.append(pos)
        pos = text.find(anchor, pos + 1)
    if not occurrences:
        raise SystemExit('anchor not found in %s' % path)

    tables = [LANGS[lang]] if len(occurrences) == 1 else [ZH, ZH_TW]
    if len(occurrences) > 2:
        raise SystemExit('unexpected %d occurrences in %s' % (len(occurrences), path))

    for i in range(len(occurrences) - 1, -1, -1):
        start = occurrences[i]
        end = text.find("';", start)
        if end < 0:
            raise SystemExit('end not found in %s' % path)
        end += len("';")
        table = tables[i]
        block = ('\n\n  @override\n  String get %s => \'%s\';'
                 % (KEY, esc(table))).replace('\n', nl.decode('utf-8'))
        text = text[:end] + block + text[end:]

    write_bytes(path, text.encode('utf-8'))
    print('DART %-8s +1 key (x%d)' % (lang, len(occurrences)))


def main():
    for lang in sorted(LANGS.keys()):
        insert_arb(lang, LANGS[lang])
    insert_base()
    for lang in DART_LOCALES:
        insert_locale(lang)
    print('done')


if __name__ == '__main__':
    sys.exit(main())
