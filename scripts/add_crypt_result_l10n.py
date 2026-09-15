#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""保险箱加解密结果提示 l10n 补齐（2026-09-15）：
新增 7 个 key（替换浏览页/批量入口里硬编码的中文「加密成功/解密成功/加密失败/解密失败/
没有选中的加密项/批量部分成功/批量解密确认/移除后提示」）→ 插入 10 ARB + 基类 dart + 9 locale dart。

铁律（同 fix_crypt_vault_l10n.py）：
- app_*.arb 为 CRLF，generated/*.dart 为 LF → 全程二进制读写；
- 按锚点插入，绝不重跑 gen-l10n（会覆盖手工合并的 L10nZh/L10nZhTw）；
- zh.dart 双类：第一处 L10nZh 用 zh 值，第二处 L10nZhTw 用 zh_TW 值；
- ARB 占位符为 {param}，dart getter 体内需写成 ${param}（Dart 字符串插值）。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

# ───────────────────────── 新 key ─────────────────────────
# 带占位符的 key：key -> 参数名列表
PLACEHOLDER_PARAMS = {
    'vault_encrypt_partial': ['success', 'failed'],
    'vault_decrypt_partial': ['success', 'failed'],
    'vault_decrypt_confirm_multi_desc': ['count'],
}

NEW_KEYS = [
    'vault_encrypt_done',
    'vault_decrypt_done',
    'vault_encrypt_partial',
    'vault_decrypt_partial',
    'vault_no_encrypted_selected',
    'vault_decrypt_confirm_multi_desc',
    'vault_removed_from_list',
]

# 各语言翻译字典
EN_NEW = {
    'vault_encrypt_done': 'Encryption successful',
    'vault_decrypt_done': 'Decryption successful',
    'vault_encrypt_partial': 'Encryption finished: {success} succeeded, {failed} failed',
    'vault_decrypt_partial': 'Decryption finished: {success} succeeded, {failed} failed',
    'vault_no_encrypted_selected': 'No encrypted items selected',
    'vault_decrypt_confirm_multi_desc': 'Decrypt {count} selected files? They will be restored to normal files after decryption.',
    'vault_removed_from_list': 'Removed from list',
}

ZH_NEW = {
    'vault_encrypt_done': '加密成功',
    'vault_decrypt_done': '解密成功',
    'vault_encrypt_partial': '加密完成，{success} 成功，{failed} 失败',
    'vault_decrypt_partial': '解密成功，{success} 成功，{failed} 失败',
    'vault_no_encrypted_selected': '没有选中的加密项',
    'vault_decrypt_confirm_multi_desc': '确定要解密选中的 {count} 个文件吗？解密后文件将恢复为普通文件。',
    'vault_removed_from_list': '已从列表移除',
}

ZH_TW_NEW = {
    'vault_encrypt_done': '加密成功',
    'vault_decrypt_done': '解密成功',
    'vault_encrypt_partial': '加密完成，{success} 成功，{failed} 失敗',
    'vault_decrypt_partial': '解密成功，{success} 成功，{failed} 失敗',
    'vault_no_encrypted_selected': '沒有選中的加密項',
    'vault_decrypt_confirm_multi_desc': '確定要解密選中的 {count} 個檔案嗎？解密後檔案將恢復為普通檔案。',
    'vault_removed_from_list': '已從清單移除',
}

JA_NEW = {
    'vault_encrypt_done': '暗号化が成功しました',
    'vault_decrypt_done': '復号に成功しました',
    'vault_encrypt_partial': '暗号化が完了しました：成功 {success} 件、失敗 {failed} 件',
    'vault_decrypt_partial': '復号が完了しました：成功 {success} 件、失敗 {failed} 件',
    'vault_no_encrypted_selected': '選択された暗号化項目はありません',
    'vault_decrypt_confirm_multi_desc': '選択した {count} 個のファイルを復号しますか？復号後は通常のファイルに戻ります。',
    'vault_removed_from_list': 'リストから削除しました',
}

KO_NEW = {
    'vault_encrypt_done': '암호화 성공',
    'vault_decrypt_done': '복호화 성공',
    'vault_encrypt_partial': '암호화 완료: 성공 {success}개, 실패 {failed}개',
    'vault_decrypt_partial': '복호화 완료: 성공 {success}개, 실패 {failed}개',
    'vault_no_encrypted_selected': '선택된 암호화 항목이 없습니다',
    'vault_decrypt_confirm_multi_desc': '선택한 암호화 파일 {count}개를 복호화할까요? 복호화 후 파일은 일반 파일로 복원됩니다.',
    'vault_removed_from_list': '목록에서 제거되었습니다',
}

RU_NEW = {
    'vault_encrypt_done': 'Шифрование выполнено',
    'vault_decrypt_done': 'Расшифровка выполнена',
    'vault_encrypt_partial': 'Шифрование завершено: успешно {success}, с ошибкой {failed}',
    'vault_decrypt_partial': 'Расшифровка завершена: успешно {success}, с ошибкой {failed}',
    'vault_no_encrypted_selected': 'Не выбрано зашифрованных элементов',
    'vault_decrypt_confirm_multi_desc': 'Расшифровать выбранные {count} файлов? После расшифровки они станут обычными файлами.',
    'vault_removed_from_list': 'Удалено из списка',
}

FR_NEW = {
    'vault_encrypt_done': 'Chiffrement réussi',
    'vault_decrypt_done': 'Déchiffrement réussi',
    'vault_encrypt_partial': 'Chiffrement terminé : {success} réussi(s), {failed} échoué(s)',
    'vault_decrypt_partial': 'Déchiffrement terminé : {success} réussi(s), {failed} échoué(s)',
    'vault_no_encrypted_selected': 'Aucun élément chiffré sélectionné',
    'vault_decrypt_confirm_multi_desc': "Déchiffrer les {count} fichiers sélectionnés ? Ils redeviendront des fichiers normaux après déchiffrement.",
    'vault_removed_from_list': 'Retiré de la liste',
}

ES_NEW = {
    'vault_encrypt_done': 'Cifrado correcto',
    'vault_decrypt_done': 'Descifrado correcto',
    'vault_encrypt_partial': 'Cifrado completado: {success} correctos, {failed} fallidos',
    'vault_decrypt_partial': 'Descifrado completado: {success} correctos, {failed} fallidos',
    'vault_no_encrypted_selected': 'No hay elementos cifrados seleccionados',
    'vault_decrypt_confirm_multi_desc': '¿Descifrar los {count} archivos seleccionados? Tras el descifrado volverán a ser archivos normales.',
    'vault_removed_from_list': 'Eliminado de la lista',
}

DE_NEW = {
    'vault_encrypt_done': 'Verschlüsselung erfolgreich',
    'vault_decrypt_done': 'Entschlüsselung erfolgreich',
    'vault_encrypt_partial': 'Verschlüsselung abgeschlossen: {success} erfolgreich, {failed} fehlgeschlagen',
    'vault_decrypt_partial': 'Entschlüsselung abgeschlossen: {success} erfolgreich, {failed} fehlgeschlagen',
    'vault_no_encrypted_selected': 'Keine verschlüsselten Elemente ausgewählt',
    'vault_decrypt_confirm_multi_desc': 'Die {count} ausgewählten Dateien entschlüsseln? Nach dem Entschlüsseln werden sie wieder normale Dateien.',
    'vault_removed_from_list': 'Aus der Liste entfernt',
}

AR_NEW = {
    'vault_encrypt_done': 'تم التشفير بنجاح',
    'vault_decrypt_done': 'تم فك التشفير بنجاح',
    'vault_encrypt_partial': 'اكتمل التشفير: نجح {success}، فشل {failed}',
    'vault_decrypt_partial': 'اكتمل فك التشفير: نجح {success}، فشل {failed}',
    'vault_no_encrypted_selected': 'لا توجد عناصر مشفرة محددة',
    'vault_decrypt_confirm_multi_desc': 'هل تريد فك تشفير {count} ملفاً محدداً؟ ستصبح الملفات ملفات عادية بعد فك التشفير.',
    'vault_removed_from_list': 'تمت الإزالة من القائمة',
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
    """把 ARB 占位符 {param} 转成 Dart 插值 ${param}，再转义引号/反斜杠。"""
    s = table[key]
    params = PLACEHOLDER_PARAMS.get(key)
    if params:
        for p in params:
            s = s.replace('{%s}' % p, '${%s}' % p)
    return esc(s)


# ─────────── 插入新 key 到 ARB ───────────
def insert_arb(lang, table):
    path = os.path.join(ARB_DIR, 'app_%s.arb' % lang)
    data = read_bytes(path)
    nl = '\r\n' if b'\r\n' in data else '\n'
    text = data.decode('utf-8')
    if '"%s"' % NEW_KEYS[0] in text:
        print('ARB  %-8s skip (already inserted)' % lang)
        return
    anchor = '"@crypt_settings_title"'
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit('anchor not found in %s' % path)
    # 找到该 metadata 块的结束 '},'
    end = text.find('\n  },', idx)
    if end < 0:
        end = text.find('\n  }', idx) + len('\n  }')
    else:
        end += len('\n  },')
    lines = []
    for key in NEW_KEYS:
        lines.append('  "%s": "%s",' % (key, table[key].replace('"', '\\"')))
        lines.append('  "@%s": {' % key)
        lines.append('    "description": "vault/crypt: %s"' % key)
        lines.append('  },')
    block = nl.join(lines)
    text = text[:end] + nl + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    # 校验 JSON 合法
    json.loads(text)
    print('ARB  %-8s +%d keys' % (lang, len(NEW_KEYS)))


# ─────────── 插入新 key 到基类 ───────────
def insert_base():
    path = os.path.join(GEN_DIR, 'app_localizations.dart')
    data = read_bytes(path)
    nl = '\r\n' if b'\r\n' in data else '\n'
    text = data.decode('utf-8')
    if 'String get %s;' % NEW_KEYS[0] in text:
        print('BASE skip')
        return
    anchor = '  String get crypt_settings_title;'
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


# ─────────── 插入新 key 到 locale dart ───────────
def insert_locale(lang):
    path = os.path.join(GEN_DIR, 'app_localizations_%s.dart' % lang)
    data = read_bytes(path)
    nl = '\r\n' if b'\r\n' in data else '\n'
    text = data.decode('utf-8')
    if "String get %s => '" % NEW_KEYS[0] in text:
        print('DART %-8s skip' % lang)
        return
    anchor = "  String get crypt_settings_title => '"
    occurrences = []
    pos = text.find(anchor)
    while pos >= 0:
        occurrences.append(pos)
        pos = text.find(anchor, pos + 1)
    if not occurrences:
        raise SystemExit('anchor not found in %s' % path)
    # zh 双类：第 1 处 L10nZh 用 zh，第 2 处 L10nZhTw 用 zh_TW
    tables = [LANGS[lang]] if len(occurrences) == 1 else [ZH_NEW, ZH_TW_NEW]
    if len(occurrences) > 2:
        raise SystemExit('unexpected %d occurrences in %s' % (len(occurrences), path))
    for i in range(len(occurrences) - 1, -1, -1):
        start = occurrences[i]
        end = text.find("';", start) + len("';")
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
