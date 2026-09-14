#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""补插 v2.1.0 更新日志遗漏的一条：分贝仪（cl210_feat_6）。

与 add_changelog_210_l10n.py 完全同源的铁律：
- lib/l10n/app_*.arb 用 CRLF，lib/l10n/generated/*.dart 用 LF → 全程二进制读写。
- 按锚点（crypt_settings_title）插入，不重跑 gen-l10n。
- zh.dart 里锚点出现两次（L10nZh、L10nZhTw）：第一次用 zh，第二次用 zh_TW。
- 纯字符串 getter，无占位符。
- FR/DE 等语言避免半角撇号（dart 会 esc 成 \\'，FR 里统一写成空格分隔）。
"""
import io
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

KEYS = ['cl210_feat_6']

TABLES = {
    'zh': {
        'cl210_feat_6': '新增分贝仪：可在工具箱或侧边栏打开，实时测量环境噪音分贝值，并显示噪声曲线、环境判定与对听力的影响提示。',
    },
    'zh_TW': {
        'cl210_feat_6': '新增分貝儀：可從工具箱或側邊欄開啟，即時測量環境噪音分貝值，並顯示噪音曲線、環境判定與對聽力的影響提示。',
    },
    'en': {
        'cl210_feat_6': 'Decibel meter: open it from the toolbox or the side drawer to measure ambient noise in real time, with a live noise curve, a verdict for your surroundings and notes on how the level affects hearing.',
    },
    'ja': {
        'cl210_feat_6': '騒音計を追加：ツールボックスまたはサイドメニューから開けます。周囲の騒音をリアルタイムで測定し、騒音曲線、環境判定、聴覚への影響の目安を表示します。',
    },
    'ko': {
        'cl210_feat_6': '데시벨 측정기 추가: 도구 상자나 측면 메뉴에서 열어 주변 소음을 실시간으로 측정하고, 소음 곡선과 환경 판정, 청력에 미치는 영향 안내를 함께 보여 줍니다.',
    },
    'de': {
        'cl210_feat_6': 'Schallpegelmesser: Über die Werkzeugsammlung oder das Seitenmenü zu öffnen; misst die Umgebungsgeräusche in Dezibel und zeigt den Verlauf, eine Bewertung der Umgebung und Hinweise auf die Wirkung auf das Gehör.',
    },
    'es': {
        'cl210_feat_6': 'Sonómetro: ábrelo desde la caja de herramientas o el menú lateral para medir el ruido ambiente en tiempo real, con la curva de ruido, la valoración del entorno y avisos sobre cómo afecta al oído.',
    },
    'fr': {
        'cl210_feat_6': 'Sonomètre : ouvrez-le depuis la boîte à outils ou le menu latéral pour mesurer le bruit ambiant en temps réel, avec la courbe de bruit, l évaluation de l environnement et des indications sur les effets sur l audition.',
    },
    'ru': {
        'cl210_feat_6': 'Шумомер: открывается из набора инструментов или бокового меню и измеряет уровень шума вокруг в реальном времени, показывая кривую шума, оценку обстановки и сведения о влиянии на слух.',
    },
    'ar': {
        'cl210_feat_6': 'مقياس مستوى الصوت: افتحه من صندوق الأدوات أو القائمة الجانبية لقياس الضجيج المحيط في الوقت الفعلي، مع منحنى الضجيج وتقييم البيئة وإرشادات عن تأثيره على السمع.',
    },
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
        lines.append('    "description": "changelog 2.1.0: %s"' % key)
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

    if len(occurrences) == 1:
        tables = [TABLES[lang]]
    elif len(occurrences) == 2:
        tables = [TABLES['zh'], TABLES['zh_TW']]
    else:
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


if __name__ == '__main__':
    for lang in TABLES:
        insert_arb(lang, TABLES[lang])
    insert_base()
    for lang in DART_LOCALES:
        insert_locale(lang)
    print('DONE')
