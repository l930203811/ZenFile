#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""插入 1 个新 key：vault_remote_crypt_unsupported（远程加密流式播放不支持该类型）。

铁律（与 add_remote_crypt_l10n.py 一致）：
- lib/l10n/app_*.arb 用 CRLF，lib/l10n/generated/*.dart 用 LF → 全程二进制读写。
- 按锚点（crypt_settings_title）插入，不重跑 gen-l10n。
- zh.dart 里锚点出现两次（L10nZh、L10nZhTw）：第一次用 zh，第二次用 zh_TW。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

KEYS = ['vault_remote_crypt_unsupported']

EN = {'vault_remote_crypt_unsupported': 'This file type is not supported for remote encrypted streaming'}
ZH = {'vault_remote_crypt_unsupported': '该类型暂不支持远程加密流式播放'}
ZH_TW = {'vault_remote_crypt_unsupported': '此類型暫不支援遠端加密串流播放'}
JA = {'vault_remote_crypt_unsupported': 'この形式はリモート暗号化のストリーミング再生に対応していません'}
KO = {'vault_remote_crypt_unsupported': '이 형식은 원격 암호화 스트리밍 재생을 지원하지 않습니다'}
DE = {'vault_remote_crypt_unsupported': 'Dieser Dateityp wird für verschlüsseltes Remote-Streaming nicht unterstützt'}
ES = {'vault_remote_crypt_unsupported': 'Este tipo de archivo no admite la reproducción en streaming cifrado remoto'}
FR = {'vault_remote_crypt_unsupported': "Ce type de fichier n'est pas pris en charge pour la lecture en streaming chiffré distant"}
RU = {'vault_remote_crypt_unsupported': 'Этот тип файла не поддерживается для удалённого зашифрованного потокового воспроизведения'}
AR = {'vault_remote_crypt_unsupported': 'هذا النوع من الملفات غير مدعوم للبث المشفّر عن بُعد'}

LANGS = {
    'en': EN, 'zh': ZH, 'zh_TW': ZH_TW, 'ja': JA, 'ko': KO,
    'de': DE, 'es': ES, 'fr': FR, 'ru': RU, 'ar': AR,
}

DART_LOCALES = ['en', 'zh', 'ar', 'de', 'es', 'fr', 'ja', 'ko', 'ru']


def read_bytes(path):
    with io.open(path, 'rb') as f:
        return f.read()


def write_bytes(path, data):
    with io.open(path, 'wb') as f:
        f.write(data)


def esc(s):
    return s.replace('\\', '\\\\').replace("'", "\\'")


def insert_arb(lang, table):
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

    lines = []
    for key in KEYS:
        lines.append('  "%s": "%s",' % (key, table[key].replace('"', '\\"')))
        lines.append('  "@%s": {' % key)
        lines.append('    "description": "crypt: %s"' % key)
        lines.append('  },')
    block = '\n'.join(lines).replace('\n', nl.decode('utf-8'))

    text = text[:end] + nl.decode('utf-8') + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    with io.open(path, 'r', encoding='utf-8') as f:
        json.load(f)
    print('ARB  %-8s +%d keys' % (lang, len(KEYS)))


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

    lines = []
    for key in KEYS:
        lines.append('')
        lines.append('  /// No description provided for @%s.' % key)
        lines.append('  String get %s;' % key)
    block = '\n'.join(lines).replace('\n', nl.decode('utf-8'))

    text = text[:end] + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    print('BASE app_localizations.dart +%d keys' % len(KEYS))


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
        lines = []
        for key in KEYS:
            lines.append('')
            lines.append('  @override')
            lines.append("  String get %s => '%s';" % (key, esc(table[key])))
        block = '\n'.join(lines).replace('\n', nl.decode('utf-8'))
        text = text[:end] + block + text[end:]

    write_bytes(path, text.encode('utf-8'))
    print('DART %-8s +%d keys (x%d)' % (lang, len(KEYS), len(occurrences)))


def main():
    for lang in sorted(LANGS.keys()):
        insert_arb(lang, LANGS[lang])
    insert_base()
    for lang in DART_LOCALES:
        insert_locale(lang)
    print('done')


if __name__ == '__main__':
    sys.exit(main())
