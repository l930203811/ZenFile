#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为保险箱新增 vault_config_password key，并更新 vault_uninstall_warning 文案。

- ARB 文件：CRLF；generated dart：LF。
- 禁止重跑 gen-l10n（app_localizations_zh.dart 手工合并了 L10nZh + L10nZhTw）。
- 插入锚点：crypt_settings_title（其值保持「加密设置」，仅按钮改用新 key）。
- 幂等：已存在 vault_config_password 则跳过新增。
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

LOCALES = ['ar', 'de', 'en', 'es', 'fr', 'ja', 'ko', 'ru', 'zh', 'zh_TW']

CONFIG_PW = {
    'zh': '配置密码',
    'zh_TW': '配置密碼',
    'en': 'Configure Password',
    'ar': 'إعداد كلمة المرور',
    'de': 'Passwort konfigurieren',
    'es': 'Configurar contraseña',
    'fr': 'Configurer le mot de passe',
    'ja': 'パスワード設定',
    'ko': '비밀번호 설정',
    'ru': 'Настроить пароль',
}

UNINSTALL = {
    'zh': '卸载应用会清空沙盒加密，建议先导出备份',
    'zh_TW': '卸載應用會清空沙盒加密，建議先匯出備份',
    'en': 'Uninstalling the app clears sandbox-encrypted files. Export a backup first.',
    'ar': 'إزالة التطبيق تمحو تشفير الصندوق الرملي. صدّر نسخة احتياطية أولاً.',
    'de': 'Bei Deinstallation der App wird die Sandbox-Verschlüsselung gelöscht. Exportieren Sie zuerst eine Sicherung.',
    'es': 'Al desinstalar la app se borra el cifrado en sandbox. Exporta una copia de seguridad antes.',
    'fr': "La désinstallation de l'application efface le chiffrement en bac à sable. Exportez une sauvegarde d'abord.",
    'ja': 'アプリをアンインストールするとサンドボックス暗号化が消去されます。先にバックアップを書き出してください。',
    'ko': '앱을 제거하면 샌드박스 암호화가 삭제됩니다. 먼저 백업을 내보내세요.',
    'ru': 'При удалении приложения данные шифрования песочницы очищаются. Сначала экспортируйте резервную копию.',
}

NEW_KEY = 'vault_config_password'


def read_text(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8')


def write_text(path, text):
    with open(path, 'wb') as f:
        f.write(text.encode('utf-8'))


def patch_arb(locale):
    path = os.path.join(ARB_DIR, f'app_{locale}.arb')
    text = read_text(path)
    crlf = '\r\n' in text
    nl = '\r\n' if crlf else '\n'
    pw = CONFIG_PW[locale]
    warn = UNINSTALL[locale]

    # ① 更新 vault_uninstall_warning 值
    pattern = re.compile(r'("vault_uninstall_warning"\s*:\s*)"[^"]*"')
    if not pattern.search(text):
        raise RuntimeError(f'{path}: vault_uninstall_warning not found')
    text = pattern.sub(lambda m: m.group(1) + '"' + warn + '"', text, count=1)

    # ② 新增 vault_config_password（锚点 crypt_settings_title）
    if f'"{NEW_KEY}"' not in text:
        anchor = re.compile(r'(\r\n)(\s*)"crypt_settings_title"\s*:\s*"[^"]*",')
        m = anchor.search(text)
        if not m:
            raise RuntimeError(f'{path}: crypt_settings_title anchor not found')
        insert = f'{nl}  "{NEW_KEY}": "{pw}",'
        text = text[:m.end()] + insert + text[m.end():]

    write_text(path, text)
    # 校验 JSON 合法
    with open(path, 'r', encoding='utf-8') as f:
        json.load(f)
    print(f'  [ARB] {locale}: ok')


def patch_gen_base():
    path = os.path.join(GEN_DIR, 'app_localizations.dart')
    text = read_text(path)
    assert '\r\n' not in text, 'base generated should be LF'

    # 更新 vault_uninstall_warning 的 doc 注释（模板语言 zh 的值）
    old_doc = "  /// **'卸载应用会清空保险箱，建议先导出备份'**"
    new_doc = f"  /// **'{UNINSTALL['zh']}'**"
    if old_doc in text:
        text = text.replace(old_doc, new_doc, 1)
    else:
        print('  [base] 警告 doc 注释未命中（可能已更新），跳过')

    # 新增 getter 声明（锚点 crypt_settings_title 的抽象声明）
    if f'String get {NEW_KEY};' not in text:
        anchor = '  String get crypt_settings_title;'
        block = (
            '\n'
            f'  /// No description provided for @{NEW_KEY}.\n'
            '  ///\n'
            '  /// In zh, this message translates to:\n'
            f"  /// **'{CONFIG_PW['zh']}'**\n"
            f'  String get {NEW_KEY};'
        )
        idx = text.find(anchor)
        if idx < 0:
            raise RuntimeError('base: crypt_settings_title decl not found')
        end = idx + len(anchor)
        text = text[:end] + block + text[end:]

    write_text(path, text)
    print('  [base] app_localizations.dart: ok')


def dart_escape(s):
    return s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$')


def patch_gen_locale(locale):
    path = os.path.join(GEN_DIR, f'app_localizations_{locale}.dart')
    text = read_text(path)
    assert '\r\n' not in text, f'{path} should be LF'
    pw = dart_escape(CONFIG_PW[locale])
    warn = dart_escape(UNINSTALL[locale])

    # ① 更新 vault_uninstall_warning getter 值（兼容单行 / 折行两种形式，
    #    并正确处理 Dart 转义引号 \'）。保留原有的换行缩进布局。
    pat = re.compile(r"(String get vault_uninstall_warning =>\s*)'(?:[^'\\]|\\.)*';")
    cnt_w = len(pat.findall(text))
    if cnt_w == 0:
        raise RuntimeError(f'{path}: vault_uninstall_warning getter not found')
    text = pat.sub(lambda m: m.group(1) + "'" + warn + "';", text)

    # ② 新增 vault_config_password getter（锚点 crypt_settings_title getter；
    #    zh 文件有 L10nZh / L10nZhTw 两处，两处都会插入）
    if f'get {NEW_KEY}' not in text:
        pat2 = re.compile(r"( *String get crypt_settings_title => '[^']*';)")
        cnt = len(pat2.findall(text))
        if cnt == 0:
            raise RuntimeError(f'{path}: crypt_settings_title getter not found')

        def rep(m):
            return (m.group(1)
                    + '\n\n  @override\n'
                    + f"  String get {NEW_KEY} => '{pw}';")

        text = pat2.sub(rep, text)
        print(f'  [gen] {locale}: inserted x{cnt}')

    write_text(path, text)
    print(f'  [gen] {locale}: ok (warn x{cnt_w})')


def main():
    print('== ARB ==')
    for loc in LOCALES:
        patch_arb(loc)
    print('== generated base ==')
    patch_gen_base()
    print('== generated locales ==')
    for loc in LOCALES:
        # zh_TW 无独立 generated 文件（与 zh 合并在 app_localizations_zh.dart，
        # 已在 zh 的两次插入中覆盖）
        if loc == 'zh_TW':
            continue
        patch_gen_locale(loc)
    print('DONE')


if __name__ == '__main__':
    sys.exit(main())
