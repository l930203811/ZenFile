#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""插入远程加密「加密上传 / 解密下载」与保险箱「本地·远程」选择相关的新 key。

铁律（与 add_remote_crypt_l10n.py / add_crypt_profile_l10n.py 一致）：
- lib/l10n/app_*.arb 用 CRLF，lib/l10n/generated/*.dart 用 LF → 全程二进制读写。
- 按锚点（crypt_settings_title）插入，不重跑 gen-l10n
  （会覆盖手工合并的 L10nZh / L10nZhTw）。
- zh.dart 里锚点出现两次（L10nZh、L10nZhTw）：第一次用 zh，第二次用 zh_TW。
- 全部为**无占位符**的纯字符串 getter（dart 侧 `String get xxx => '...';）。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

KEYS = [
    'vault_import_source_title',
    'vault_import_source_remote',
    'vault_import_source_remote_desc',
    'vault_link_remote_crypt_desc',
    'vault_encrypt_upload',
    'vault_encrypt_upload_desc',
    'vault_encrypt_uploading',
    'vault_encrypt_upload_done',
    'vault_encrypt_upload_failed',
    'crypt_remote_upload',
    'crypt_remote_download',
    'crypt_remote_downloading',
    'crypt_remote_download_done',
    'crypt_remote_download_failed',
]

EN = {
    'vault_import_source_title': 'Choose encryption source',
    'vault_import_source_remote': 'Remote',
    'vault_import_source_remote_desc': 'Link a remote encrypted folder, or encrypt local files and upload',
    'vault_link_remote_crypt_desc': 'Link an existing rclone crypt folder on the server (decrypted on device)',
    'vault_encrypt_upload': 'Encrypt and upload to remote',
    'vault_encrypt_upload_desc': 'Pick local files, encrypt them and upload to the remote server',
    'vault_encrypt_uploading': 'Encrypting and uploading...',
    'vault_encrypt_upload_done': 'Encrypted upload complete',
    'vault_encrypt_upload_failed': 'Encrypted upload failed',
    'crypt_remote_upload': 'Encrypt and upload',
    'crypt_remote_download': 'Decrypt and download',
    'crypt_remote_downloading': 'Decrypting and downloading...',
    'crypt_remote_download_done': 'Decrypted download complete',
    'crypt_remote_download_failed': 'Decrypted download failed',
}

ZH = {
    'vault_import_source_title': '选择加密来源',
    'vault_import_source_remote': '远程',
    'vault_import_source_remote_desc': '关联远程加密目录，或将本地文件加密后上传到远程',
    'vault_link_remote_crypt_desc': '关联服务器上已有的 rclone crypt 密文目录（在客户端解密）',
    'vault_encrypt_upload': '加密上传到远程',
    'vault_encrypt_upload_desc': '选择本地文件，加密后上传到远程服务器',
    'vault_encrypt_uploading': '正在加密上传…',
    'vault_encrypt_upload_done': '加密上传完成',
    'vault_encrypt_upload_failed': '加密上传失败',
    'crypt_remote_upload': '加密上传',
    'crypt_remote_download': '解密下载',
    'crypt_remote_downloading': '正在解密下载…',
    'crypt_remote_download_done': '解密下载完成',
    'crypt_remote_download_failed': '解密下载失败',
}

ZH_TW = {
    'vault_import_source_title': '選擇加密來源',
    'vault_import_source_remote': '遠端',
    'vault_import_source_remote_desc': '關聯遠端加密目錄，或將本機檔案加密後上傳到遠端',
    'vault_link_remote_crypt_desc': '關聯伺服器上已有的 rclone crypt 密文目錄（在用戶端解密）',
    'vault_encrypt_upload': '加密上傳到遠端',
    'vault_encrypt_upload_desc': '選擇本機檔案，加密後上傳到遠端伺服器',
    'vault_encrypt_uploading': '正在加密上傳…',
    'vault_encrypt_upload_done': '加密上傳完成',
    'vault_encrypt_upload_failed': '加密上傳失敗',
    'crypt_remote_upload': '加密上傳',
    'crypt_remote_download': '解密下載',
    'crypt_remote_downloading': '正在解密下載…',
    'crypt_remote_download_done': '解密下載完成',
    'crypt_remote_download_failed': '解密下載失敗',
}

JA = {
    'vault_import_source_title': '暗号化元を選択',
    'vault_import_source_remote': 'リモート',
    'vault_import_source_remote_desc': 'リモート暗号化フォルダを紐付ける、またはローカルファイルを暗号化してアップロード',
    'vault_link_remote_crypt_desc': 'サーバー上の既存 rclone crypt フォルダを紐付け（端末側で復号）',
    'vault_encrypt_upload': '暗号化してリモートへアップロード',
    'vault_encrypt_upload_desc': 'ローカルファイルを選択し、暗号化してリモートサーバーへアップロード',
    'vault_encrypt_uploading': '暗号化してアップロード中…',
    'vault_encrypt_upload_done': '暗号化アップロードが完了しました',
    'vault_encrypt_upload_failed': '暗号化アップロードに失敗しました',
    'crypt_remote_upload': '暗号化してアップロード',
    'crypt_remote_download': '復号してダウンロード',
    'crypt_remote_downloading': '復号してダウンロード中…',
    'crypt_remote_download_done': '復号ダウンロードが完了しました',
    'crypt_remote_download_failed': '復号ダウンロードに失敗しました',
}

KO = {
    'vault_import_source_title': '암호화 소스 선택',
    'vault_import_source_remote': '원격',
    'vault_import_source_remote_desc': '원격 암호화 폴더를 연결하거나 로컬 파일을 암호화하여 업로드',
    'vault_link_remote_crypt_desc': '서버의 기존 rclone crypt 폴더 연결 (기기에서 복호화)',
    'vault_encrypt_upload': '암호화하여 원격에 업로드',
    'vault_encrypt_upload_desc': '로컬 파일을 선택하여 암호화한 뒤 원격 서버에 업로드',
    'vault_encrypt_uploading': '암호화 및 업로드 중…',
    'vault_encrypt_upload_done': '암호화 업로드 완료',
    'vault_encrypt_upload_failed': '암호화 업로드 실패',
    'crypt_remote_upload': '암호화 업로드',
    'crypt_remote_download': '복호화 다운로드',
    'crypt_remote_downloading': '복호화 및 다운로드 중…',
    'crypt_remote_download_done': '복호화 다운로드 완료',
    'crypt_remote_download_failed': '복호화 다운로드 실패',
}

DE = {
    'vault_import_source_title': 'Verschlüsselungsquelle wählen',
    'vault_import_source_remote': 'Remote',
    'vault_import_source_remote_desc': 'Remote-Ordner verknüpfen oder lokale Dateien verschlüsselt hochladen',
    'vault_link_remote_crypt_desc': 'Bestehenden rclone-crypt-Ordner auf dem Server verknüpfen (lokal entschlüsselt)',
    'vault_encrypt_upload': 'Verschlüsselt auf Remote hochladen',
    'vault_encrypt_upload_desc': 'Lokale Dateien auswählen, verschlüsseln und auf den Remote-Server hochladen',
    'vault_encrypt_uploading': 'Verschlüssele und lade hoch…',
    'vault_encrypt_upload_done': 'Verschlüsselter Upload abgeschlossen',
    'vault_encrypt_upload_failed': 'Verschlüsselter Upload fehlgeschlagen',
    'crypt_remote_upload': 'Verschlüsselt hochladen',
    'crypt_remote_download': 'Entschlüsselt herunterladen',
    'crypt_remote_downloading': 'Entschlüssele und lade herunter…',
    'crypt_remote_download_done': 'Entschlüsselter Download abgeschlossen',
    'crypt_remote_download_failed': 'Entschlüsselter Download fehlgeschlagen',
}

ES = {
    'vault_import_source_title': 'Elegir origen de cifrado',
    'vault_import_source_remote': 'Remoto',
    'vault_import_source_remote_desc': 'Vincular una carpeta cifrada remota o cifrar y subir archivos locales',
    'vault_link_remote_crypt_desc': 'Vincular una carpeta rclone crypt existente en el servidor (se descifra en el dispositivo)',
    'vault_encrypt_upload': 'Cifrar y subir al remoto',
    'vault_encrypt_upload_desc': 'Elegir archivos locales, cifrarlos y subirlos al servidor remoto',
    'vault_encrypt_uploading': 'Cifrando y subiendo…',
    'vault_encrypt_upload_done': 'Subida cifrada completada',
    'vault_encrypt_upload_failed': 'Error en la subida cifrada',
    'crypt_remote_upload': 'Cifrar y subir',
    'crypt_remote_download': 'Descifrar y descargar',
    'crypt_remote_downloading': 'Descifrando y descargando…',
    'crypt_remote_download_done': 'Descarga descifrada completada',
    'crypt_remote_download_failed': 'Error en la descarga descifrada',
}

FR = {
    'vault_import_source_title': 'Choisir la source de chiffrement',
    'vault_import_source_remote': 'Distant',
    'vault_import_source_remote_desc': 'Associer un dossier chiffré distant ou chiffrer et envoyer des fichiers locaux',
    'vault_link_remote_crypt_desc': 'Associer un dossier rclone crypt existant sur le serveur (déchiffré sur l appareil)',
    'vault_encrypt_upload': 'Chiffrer et envoyer vers le serveur distant',
    'vault_encrypt_upload_desc': 'Choisir des fichiers locaux, les chiffrer puis les envoyer vers le serveur distant',
    'vault_encrypt_uploading': 'Chiffrement et envoi en cours…',
    'vault_encrypt_upload_done': 'Envoi chiffré terminé',
    'vault_encrypt_upload_failed': 'Échec de l envoi chiffré',
    'crypt_remote_upload': 'Chiffrer et envoyer',
    'crypt_remote_download': 'Déchiffrer et télécharger',
    'crypt_remote_downloading': 'Déchiffrement et téléchargement en cours…',
    'crypt_remote_download_done': 'Téléchargement déchiffré terminé',
    'crypt_remote_download_failed': 'Échec du téléchargement déchiffré',
}

RU = {
    'vault_import_source_title': 'Выберите источник шифрования',
    'vault_import_source_remote': 'Удалённый',
    'vault_import_source_remote_desc': 'Связать удалённую зашифрованную папку или зашифровать и загрузить локальные файлы',
    'vault_link_remote_crypt_desc': 'Связать существующую папку rclone crypt на сервере (расшифровка на устройстве)',
    'vault_encrypt_upload': 'Зашифровать и загрузить на удалённый сервер',
    'vault_encrypt_upload_desc': 'Выберите локальные файлы, зашифруйте и загрузите на удалённый сервер',
    'vault_encrypt_uploading': 'Шифрование и загрузка…',
    'vault_encrypt_upload_done': 'Зашифрованная загрузка завершена',
    'vault_encrypt_upload_failed': 'Ошибка зашифрованной загрузки',
    'crypt_remote_upload': 'Зашифровать и загрузить',
    'crypt_remote_download': 'Расшифровать и скачать',
    'crypt_remote_downloading': 'Расшифровка и загрузка…',
    'crypt_remote_download_done': 'Расшифрованная загрузка завершена',
    'crypt_remote_download_failed': 'Ошибка расшифрованной загрузки',
}

AR = {
    'vault_import_source_title': 'اختر مصدر التشفير',
    'vault_import_source_remote': 'بعيد',
    'vault_import_source_remote_desc': 'ربط مجلد مشفّر بعيد أو تشفير الملفات المحلية ورفعها',
    'vault_link_remote_crypt_desc': 'ربط مجلد rclone crypt موجود على الخادم (فك التشفير على الجهاز)',
    'vault_encrypt_upload': 'تشفير ورفع إلى الخادم البعيد',
    'vault_encrypt_upload_desc': 'اختيار ملفات محلية وتشفيرها ورفعها إلى الخادم البعيد',
    'vault_encrypt_uploading': 'جارٍ التشفير والرفع…',
    'vault_encrypt_upload_done': 'اكتمل الرفع المشفّر',
    'vault_encrypt_upload_failed': 'فشل الرفع المشفّر',
    'crypt_remote_upload': 'تشفير ورفع',
    'crypt_remote_download': 'فك التشفير والتنزيل',
    'crypt_remote_downloading': 'جارٍ فك التشفير والتنزيل…',
    'crypt_remote_download_done': 'اكتمل التنزيل مع فك التشفير',
    'crypt_remote_download_failed': 'فشل التنزيل مع فك التشفير',
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
