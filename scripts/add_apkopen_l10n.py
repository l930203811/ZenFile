#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""APK 打开方式 l10n 补齐（2026-09-16）：
新增 2 个 key（apk_open_mode_title / apk_open_mode_desc）插入 10 ARB + 基类 dart
+ 9 locale dart（zh 双类）。

铁律（同 add_cl211_l10n.py）：
- app_*.arb 为 CRLF，generated/*.dart 为 LF → 全程二进制读写；
- 按锚点插入，绝不重跑 gen-l10n；
- zh.dart 双类：第一处 L10nZh 用 zh 值，第二处 L10nZhTw 用 zh_TW 值。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

PLACEHOLDER_PARAMS = {}

NEW_KEYS = ['apk_open_mode_title', 'apk_open_mode_desc']

EN_NEW = {
    'apk_open_mode_title': 'APK open method',
    'apk_open_mode_desc': 'Use the system chooser to open APKs so third-party installers like InstallerX can handle them; off uses the built-in installer.',
}
ZH_NEW = {
    'apk_open_mode_title': 'APK 打开方式',
    'apk_open_mode_desc': '使用系统选择器打开 APK，允许 InstallerX 等第三方安装器接管；关闭则使用内置安装器。',
}
ZH_TW_NEW = {
    'apk_open_mode_title': 'APK 開啟方式',
    'apk_open_mode_desc': '使用系統選擇器開啟 APK，允許 InstallerX 等第三方安裝器接管；關閉則使用內建安裝器。',
}
JA_NEW = {
    'apk_open_mode_title': 'APK の開き方',
    'apk_open_mode_desc': 'APK を開く際にシステムの選択画面を使用し、InstallerX などのサードパーティ製インストーラーに処理を任せます。オフの場合は内蔵インストーラーを使用します。',
}
KO_NEW = {
    'apk_open_mode_title': 'APK 열기 방식',
    'apk_open_mode_desc': 'APK를 열 때 시스템 선택기를 사용하여 InstallerX 같은 서드파티 설치기가 처리하도록 합니다. 끄면 내장 설치기를 사용합니다.',
}
RU_NEW = {
    'apk_open_mode_title': 'Способ открытия APK',
    'apk_open_mode_desc': 'Использовать системный выборщик для открытия APK, чтобы сторонние установщики вроде InstallerX могли их обрабатывать; при выключении используется встроенный установщик.',
}
FR_NEW = {
    'apk_open_mode_title': "Méthode d'ouverture des APK",
    'apk_open_mode_desc': "Utilise le sélecteur système pour ouvrir les APK afin que des installateurs tiers comme InstallerX les prennent en charge ; si désactivé, l'installateur intégré est utilisé.",
}
ES_NEW = {
    'apk_open_mode_title': 'Método de apertura de APK',
    'apk_open_mode_desc': 'Usa el selector del sistema para abrir los APK y permitir que instaladores de terceros como InstallerX los gestionen; si está desactivado se usa el instalador integrado.',
}
DE_NEW = {
    'apk_open_mode_title': 'APK-Öffnen',
    'apk_open_mode_desc': 'Den Systemauswähler zum Öffnen von APKs verwenden, damit Drittanbieter-Installer wie InstallerX sie übernehmen können; aus nutzt den eingebauten Installer.',
}
AR_NEW = {
    'apk_open_mode_title': 'طريقة فتح ملفات APK',
    'apk_open_mode_desc': 'استخدم منتقي النظام لفتح ملفات APK بحيث يمكن لأدوات التثبيت الخارجية مثل InstallerX التعامل معها؛ عند التعطيل يُستخدم المثبّت المدمج.',
}

LANGS = {'en': EN_NEW, 'zh': ZH_NEW, 'zh_TW': ZH_TW_NEW, 'ja': JA_NEW, 'ko': KO_NEW,
         'ru': RU_NEW, 'fr': FR_NEW, 'es': ES_NEW, 'de': DE_NEW, 'ar': AR_NEW}
DART_LOCALES = ['en', 'zh', 'ar', 'de', 'es', 'fr', 'ja', 'ko', 'ru']


def read_bytes(path):
    with io.open(path, 'rb') as f:
        return f.read()


def write_bytes(path, data):
    with io.open(path, 'wb') as f:
        f.write(data)


def esc(s):
    return s.replace('\\', '\\\\').replace("'", "\\'")


def dart_body(table, key):
    s = table[key]
    params = PLACEHOLDER_PARAMS.get(key)
    if params:
        for p in params:
            s = s.replace('{%s}' % p, '${%s}' % p)
    return esc(s)


def insert_arb(lang, table):
    path = os.path.join(ARB_DIR, 'app_%s.arb' % lang)
    data = read_bytes(path)
    nl = '\r\n' if b'\r\n' in data else '\n'
    text = data.decode('utf-8')
    if '"%s"' % NEW_KEYS[0] in text:
        print('ARB  %-8s skip (already inserted)' % lang)
        return
    anchor = '"@vt_keep_apk_desc"'
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit('anchor not found in %s' % path)
    end = text.find('\n  },', idx)
    if end < 0:
        end = text.find('\n  }', idx) + len('\n  }')
    else:
        end += len('\n  },')
    lines = []
    for key in NEW_KEYS:
        lines.append('  "%s": "%s",' % (key, table[key].replace('"', '\\"')))
        lines.append('  "@%s": {' % key)
        lines.append('    "description": "apk open mode: %s"' % key)
        lines.append('  },')
    block = nl.join(lines)
    text = text[:end] + nl + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    json.loads(text)
    print('ARB  %-8s +%d keys' % (lang, len(NEW_KEYS)))


def insert_base():
    path = os.path.join(GEN_DIR, 'app_localizations.dart')
    data = read_bytes(path)
    nl = '\r\n' if b'\r\n' in data else '\n'
    text = data.decode('utf-8')
    if 'String get %s;' % NEW_KEYS[0] in text:
        print('BASE skip')
        return
    anchor = '  String get vt_keep_apk_desc;'
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit('anchor not found in base')
    end = idx + len(anchor)
    lines = []
    for key in NEW_KEYS:
        params = PLACEHOLDER_PARAMS.get(key)
        lines.append('')
        lines.append('  /// No description provided for @%s.' % key)
        if params:
            sig = '(' + ', '.join('Object %s' % p for p in params) + ')'
            lines.append('  String %s%s;' % (key, sig))
        else:
            lines.append('  String get %s;' % key)
    block = nl.join(lines)
    text = text[:end] + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    print('BASE +%d keys' % len(NEW_KEYS))


def insert_locale(lang):
    path = os.path.join(GEN_DIR, 'app_localizations_%s.dart' % lang)
    data = read_bytes(path)
    nl = '\r\n' if b'\r\n' in data else '\n'
    text = data.decode('utf-8')
    if "String get %s =>" % NEW_KEYS[0] in text:
        print('DART %-8s skip' % lang)
        return
    anchor = "  String get vt_keep_apk_desc =>"
    occurrences = []
    pos = text.find(anchor)
    while pos >= 0:
        occurrences.append(pos)
        pos = text.find(anchor, pos + 1)
    if not occurrences:
        raise SystemExit('anchor not found in %s' % path)
    tables = [LANGS[lang]] if len(occurrences) == 1 else [ZH_NEW, ZH_TW_NEW]
    if len(occurrences) > 2:
        raise SystemExit('unexpected %d occurrences in %s' % (len(occurrences), path))
    for i in range(len(occurrences) - 1, -1, -1):
        start = occurrences[i]
        # 定位 getter 的真正结束（'），避免值内含 ASCII ';' 时插入到字符串中间。
        # 结束标志是 '; 且 ' 前面不是转义反斜杠（排除值内的 \' + ;）。
        idx = text.find("';", start)
        end = -1
        while idx >= 0:
            if idx == 0 or text[idx - 1] != '\\':
                end = idx + 2
                break
            idx = text.find("';", idx + 1)
        if end < 0:
            raise SystemExit('no getter terminator after anchor in %s' % path)
        table = tables[i]
        lines = []
        for key in NEW_KEYS:
            params = PLACEHOLDER_PARAMS.get(key)
            lines.append('')
            lines.append('  @override')
            if params:
                sig = '(' + ', '.join('Object %s' % p for p in params) + ')'
                lines.append('  String %s%s {' % (key, sig))
                lines.append("    return '%s';" % dart_body(table, key))
                lines.append('  }')
            else:
                lines.append("  String get %s => '%s';" % (key, dart_body(table, key)))
        block = nl.join(lines)
        text = text[:end] + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    print('DART %-8s +%d keys (x%d)' % (lang, len(NEW_KEYS), len(occurrences)))


def main():
    for lang in sorted(LANGS.keys()):
        insert_arb(lang, LANGS[lang])
    insert_base()
    for lang in DART_LOCALES:
        insert_locale(lang)
    print('done')


if __name__ == '__main__':
    sys.exit(main())
