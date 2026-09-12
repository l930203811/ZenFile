#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""向 10 个 ARB + 基类 + 9 个 locale dart 插入 vault_(un)link_remote_crypt* 新 key。

铁律（与 add_crypt_profile_l10n.py 一致）：
- lib/l10n/app_*.arb 用 CRLF，lib/l10n/generated/*.dart 用 LF → 全程二进制读写。
- 按锚点（crypt_settings_title）插入，不重跑 gen-l10n
  （会覆盖手工合并的 L10nZh / L10nZhTw）。
- zh.dart 里锚点出现两次（L10nZh、L10nZhTw）：第一次用 zh，第二次用 zh_TW。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

KEYS = [
    'vault_link_remote_crypt',
    'vault_link_remote_crypt_success',
    'vault_unlink_remote_crypt',
]

EN = {
    'vault_link_remote_crypt': 'Link remote encrypted folder',
    'vault_link_remote_crypt_success': 'Remote encrypted folder linked',
    'vault_unlink_remote_crypt': 'Unlink',
}
ZH = {
    'vault_link_remote_crypt': '关联远程加密目录',
    'vault_link_remote_crypt_success': '已关联远程加密目录',
    'vault_unlink_remote_crypt': '取消关联',
}
ZH_TW = {
    'vault_link_remote_crypt': '關聯遠端加密目錄',
    'vault_link_remote_crypt_success': '已關聯遠端加密目錄',
    'vault_unlink_remote_crypt': '取消關聯',
}
JA = {
    'vault_link_remote_crypt': 'リモート暗号化フォルダを紐付け',
    'vault_link_remote_crypt_success': 'リモート暗号化フォルダを紐付けました',
    'vault_unlink_remote_crypt': '紐付けを解除',
}
KO = {
    'vault_link_remote_crypt': '원격 암호화 폴더 연결',
    'vault_link_remote_crypt_success': '원격 암호화 폴더를 연결했습니다',
    'vault_unlink_remote_crypt': '연결 해제',
}
DE = {
    'vault_link_remote_crypt': 'Verschlüsselten Remote-Ordner verknüpfen',
    'vault_link_remote_crypt_success': 'Verschlüsselter Remote-Ordner verknüpft',
    'vault_unlink_remote_crypt': 'Verknüpfung aufheben',
}
ES = {
    'vault_link_remote_crypt': 'Vincular carpeta cifrada remota',
    'vault_link_remote_crypt_success': 'Carpeta cifrada remota vinculada',
    'vault_unlink_remote_crypt': 'Desvincular',
}
FR = {
    'vault_link_remote_crypt': 'Associer un dossier chiffre distant',
    'vault_link_remote_crypt_success': 'Dossier chiffre distant associe',
    'vault_unlink_remote_crypt': 'Dissocier',
}
RU = {
    'vault_link_remote_crypt': 'Связать удалённую зашифрованную папку',
    'vault_link_remote_crypt_success': 'Удалённая зашифрованная папка связана',
    'vault_unlink_remote_crypt': 'Отвязать',
}
AR = {
    'vault_link_remote_crypt': 'ربط مجلد مشفّر بعيد',
    'vault_link_remote_crypt_success': 'تم ربط المجلد المشفّر البعيد',
    'vault_unlink_remote_crypt': 'إلغاء الربط',
}

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
    # 防呆：去掉可能出现的「末尾多余逗号」（仅在 } 前）
    write_bytes(path, text.encode('utf-8'))
    # 立即校验 JSON
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
