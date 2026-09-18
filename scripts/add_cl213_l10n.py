#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.1.3 更新日志 l10n 补齐（2026-09-18）：
新增 2 个 key（cl213_features / cl213_feat_1）插入 10 ARB + 基类 dart + 9 locale dart（zh 双类）。
cl213_feat_1 记录「远程客户端错误提示本地化」这一 2.1.3 首发特性。

铁律（同 add_cl212_l10n.py / add_remote_err_l10n.py）：
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

NEW_KEYS = ['cl213_features', 'cl213_feat_1']

EN_NEW = {
    'cl213_features': 'Remote connection errors',
    'cl213_feat_1': 'Remote client errors (FTP / WebDAV / SFTP / SMB) now show clear, localized messages instead of raw English exceptions - e.g. connection failed, login failed, timeout, permission denied, file not found - so failures are easier to understand.',
}
ZH_NEW = {
    'cl213_features': '远程连接错误提示',
    'cl213_feat_1': 'FTP / WebDAV / SFTP / SMB 等远程客户端的报错，由原始英文异常改为清晰的多语言文字提示（如：连接失败、登录失败、超时、权限不足、文件不存在），便于理解问题原因。',
}
ZH_TW_NEW = {
    'cl213_features': '遠端連線錯誤提示',
    'cl213_feat_1': 'FTP / WebDAV / SFTP / SMB 等遠端客戶端的報錯，由原始英文例外改為清晰的多語言文字提示（如：連線失敗、登入失敗、逾時、權限不足、檔案不存在），便於理解問題原因。',
}
JA_NEW = {
    'cl213_features': 'Remote connection errors',
    'cl213_feat_1': 'FTP / WebDAV / SFTP / SMB などのリモートクライアントのエラーが、生の英語例外ではなく分かりやすい多言語メッセージ（接続失敗、ログイン失敗、タイムアウト、権限不足、ファイルが見つからないなど）に置き換わり、原因を理解しやすくなりました。',
}
KO_NEW = {
    'cl213_features': '원격 연결 오류',
    'cl213_feat_1': 'FTP / WebDAV / SFTP / SMB 등 원격 클라이언트 오류가 영문 예외 대신 명확한 다국어 메시지(연결 실패, 로그인 실패, 시간 초과, 권한 없음, 파일 없음 등)로 표시되어 원인을 쉽게 이해할 수 있습니다.',
}
RU_NEW = {
    'cl213_features': 'Ошибки удалённого подключения',
    'cl213_feat_1': 'Ошибки удалённых клиентов (FTP / WebDAV / SFTP / SMB) теперь показывают понятные локализованные сообщения вместо сырых английских исключений - например, подключение не удалось, ошибка входа, таймаут, нет доступа, файл не найден.',
}
FR_NEW = {
    'cl213_features': 'Erreurs de connexion distante',
    'cl213_feat_1': "Les erreurs des clients distants (FTP / WebDAV / SFTP / SMB) affichent désormais des messages localisés et clairs au lieu d'exceptions anglaises brutes - par exemple connexion échouée, échec de connexion, expiration, accès refusé, fichier introuvable.",
}
ES_NEW = {
    'cl213_features': 'Errores de conexión remota',
    'cl213_feat_1': 'Los errores de los clientes remotos (FTP / WebDAV / SFTP / SMB) ahora muestran mensajes localizados y claros en lugar de excepciones en inglés sin formato - por ejemplo, conexión fallida, error de inicio de sesión, tiempo de espera agotado, permiso denegado, archivo no encontrado.',
}
DE_NEW = {
    'cl213_features': 'Fehler bei Remote-Verbindungen',
    'cl213_feat_1': 'Fehler der Remote-Clients (FTP / WebDAV / SFTP / SMB) zeigen nun klare, lokalisierte Meldungen statt roher englischer Ausnahmen - z. B. Verbindung fehlgeschlagen, Anmeldung fehlgeschlagen, Timeout, Zugriff verweigert, Datei nicht gefunden.',
}
AR_NEW = {
    'cl213_features': 'أخطاء الاتصال عن بُعد',
    'cl213_feat_1': 'تُظهر أخطاء العملاء عن بُعد (FTP / WebDAV / SFTP / SMB) الآن رسائل مترجمة وواضحة بدلاً من الاستثناءات الإنجليزية الخام - مثل فشل الاتصال، فشل تسجيل الدخول، انتهاء المهلة، تم رفض الإذن، الملف غير موجود.',
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
    anchor = '"@cl212_fix_3"'
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
        lines.append('    "description": "v2.1.3 changelog: %s"' % key)
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
    anchor = '  String get cl212_fix_3;'
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
    anchor = "  String get cl212_fix_3 =>"
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
