# -*- coding: utf-8 -*-
"""注入 ui_anonymous_login（SMB 匿名登录勾选框）到 10 ARB + 基类 + 9 locale dart（zh 双类）。
锚点：ARB = "ui_share_scan_failed" 行前插入；dart = ui_share_scan_failed 方法前插入。
ARB=CRLF，generated dart=LF；定点插入不重排，幂等（已存在则跳过）。"""
import io, json, os

DIR = r'D:\Xiangmu\ZenFile-main\lib\l10n'
GEN = os.path.join(DIR, 'generated')

VALUES = {
    'en': 'Anonymous login',
    'zh': '匿名登录',
    'zh_TW': '匿名登入',
    'ja': '匿名ログイン',
    'ko': '익명 로그인',
    'de': 'Anonyme Anmeldung',
    'fr': "Connexion anonyme",
    'es': 'Inicio de sesión anónimo',
    'ru': 'Анонимный вход',
    'ar': 'تسجيل الدخول المجهول',
}

DESC = 'SMB wizard: anonymous login checkbox label'
ok = True


def insert_arb(lang, value):
    path = os.path.join(DIR, f'app_{lang}.arb')
    with io.open(path, 'r', encoding='utf-8') as f:
        raw = f.read()
    if '"ui_anonymous_login"' in raw:
        print(f'{lang}: skip (exists)')
        return
    data = json.loads(raw)  # 校验仍是合法 JSON
    anchor = '  "ui_share_scan_failed":'
    idx = raw.find(anchor)
    assert idx > 0, f'{lang}: anchor not found'
    newline = '\r\n' if '\r\n' in raw else '\n'
    block = '  "ui_anonymous_login": ' + json.dumps(value, ensure_ascii=False) + ',' + newline
    block += '  "@ui_anonymous_login": {' + newline
    block += '    "description": ' + json.dumps(f'{DESC} ({lang})', ensure_ascii=False) + newline
    block += '  },' + newline
    raw2 = raw[:idx] + block + raw[idx:]
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(raw2)
    json.loads(io.open(path, encoding='utf-8').read())  # 复检
    print(f'{lang}: arb ok')


def insert_dart(fn, value, expect=1):
    path = os.path.join(GEN, fn)
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        raw = f.read()
    anchor = '  String ui_share_scan_failed(Object error) {'
    n = raw.count(anchor)
    if 'ui_anonymous_login' in raw:
        print(f'{fn}: skip (exists)')
        return
    assert n >= expect, f'{fn}: anchor x{n} < {expect}'
    newline = '\r\n' if '\r\n' in raw else '\n'
    getter = ('  @override' + newline +
              "  String get ui_anonymous_login => '" + value.replace("'", "\\'") + "';" + newline + newline)
    raw2 = raw.replace(anchor, getter + anchor)
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(raw2)
    print(f'{fn}: dart ok x{n}')


def insert_base():
    path = os.path.join(GEN, 'app_localizations.dart')
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        raw = f.read()
    if 'ui_anonymous_login' in raw:
        print('base: skip (exists)')
        return
    anchor = '  String ui_share_scan_failed(Object error);'
    idx = raw.find(anchor)
    assert idx > 0, 'base: anchor not found'
    getter = '  String get ui_anonymous_login;\n\n'
    raw2 = raw[:idx] + getter + raw[idx:]
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(raw2)
    print('base: ok')


for lang, v in VALUES.items():
    insert_arb(lang, v)
insert_base()
for lang in ['ar', 'de', 'en', 'es', 'fr', 'ja', 'ko', 'ru']:
    insert_dart(f'app_localizations_{lang}.dart', VALUES[lang], expect=1)
insert_dart('app_localizations_zh.dart', VALUES['zh'], expect=2)
print('ALL DONE')
