#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.1.3 远程客户端错误本地化 l10n 补齐（2026-09-18）：
新增 15 个 key（remote_err_*）插入 10 ARB + 基类 dart + 9 locale dart（zh 双类）。
这些 key 用于把 FTP/WebDAV/SFTP/SMB 等远程客户端的英文异常提示，
统一替换为友好的本地化文字提示（见 lib/services/remote/remote_error_localizer.dart）。

铁律（同 add_cl212_l10n.py）：
- app_*.arb 为 CRLF，generated/*.dart 为 LF → 全程二进制读写；
- 按锚点插入，绝不重跑 gen-l10n；
- zh.dart 双类：第一处 L10nZh 用 zh 值，第二处 L10nZhTw 用 zh_TW 值；
- remote_err_server 含占位符 {code}，@ 元数据需声明 placeholders。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

# remote_err_server 带 {code} 占位符
PLACEHOLDER_PARAMS = {'remote_err_server': ['code']}
PLACEHOLDER_META = {'remote_err_server': 'code'}

NEW_KEYS = [
    'remote_err_cancelled', 'remote_err_auth', 'remote_err_not_connected',
    'remote_err_not_found', 'remote_err_timeout', 'remote_err_connection',
    'remote_err_reconnect', 'remote_err_download', 'remote_err_upload',
    'remote_err_delete', 'remote_err_rename', 'remote_err_create_dir',
    'remote_err_dir_open', 'remote_err_server', 'remote_err_generic',
]

EN_NEW = {
    'remote_err_cancelled': 'Operation cancelled',
    'remote_err_auth': 'Login failed: wrong username or password. If using a key, check the private key and its passphrase.',
    'remote_err_not_connected': 'Not connected to the server. Connect first and try again.',
    'remote_err_not_found': 'The file or folder does not exist (it may have been moved or deleted).',
    'remote_err_timeout': 'Connection timed out: the server responded too slowly or the network is unstable. Please try again.',
    'remote_err_connection': 'Could not connect to the server: check the address, port, network, and that the server is running.',
    'remote_err_reconnect': 'The connection to the server was lost and is trying to reconnect.',
    'remote_err_download': 'Download failed. Check the network and try again.',
    'remote_err_upload': 'Upload failed. Check the network and try again.',
    'remote_err_delete': 'Delete failed. Please try again.',
    'remote_err_rename': 'Rename failed. Please try again.',
    'remote_err_create_dir': 'Failed to create folder. Please try again.',
    'remote_err_dir_open': 'Cannot open this folder. Make sure you have access.',
    'remote_err_server': 'The server returned an error (status code {code}). Contact the server admin.',
    'remote_err_generic': 'Operation failed. Please try again.',
}
ZH_NEW = {
    'remote_err_cancelled': '操作已取消',
    'remote_err_auth': '登录失败：用户名或密码错误。若使用密钥登录，请确认私钥文件与密码正确。',
    'remote_err_not_connected': '尚未连接到服务器，请先连接后重试。',
    'remote_err_not_found': '文件或文件夹不存在（可能已被移动或删除）。',
    'remote_err_timeout': '连接超时：服务器响应过慢或网络不稳定，请稍后重试。',
    'remote_err_connection': '无法连接到服务器：请检查地址、端口、网络，以及服务器是否已开启。',
    'remote_err_reconnect': '与服务器的连接已断开，正在尝试重新连接。',
    'remote_err_download': '下载失败，请检查网络后重试。',
    'remote_err_upload': '上传失败，请检查网络后重试。',
    'remote_err_delete': '删除失败，请重试。',
    'remote_err_rename': '重命名失败，请重试。',
    'remote_err_create_dir': '创建文件夹失败，请重试。',
    'remote_err_dir_open': '无法打开该文件夹，请确认你有访问权限。',
    'remote_err_server': '服务器返回错误（状态码 {code}），请联系服务器管理员。',
    'remote_err_generic': '操作失败，请重试。',
}
ZH_TW_NEW = {
    'remote_err_cancelled': '操作已取消',
    'remote_err_auth': '登入失敗：使用者名稱或密碼錯誤。若使用金鑰登入，請確認私鑰檔案與密碼正確。',
    'remote_err_not_connected': '尚未連線到伺服器，請先連線後重試。',
    'remote_err_not_found': '檔案或資料夾不存在（可能已被移動或刪除）。',
    'remote_err_timeout': '連線逾時：伺服器回應過慢或網路不穩定，請稍後重試。',
    'remote_err_connection': '無法連線到伺服器：請檢查位址、連接埠、網路，以及伺服器是否已開啟。',
    'remote_err_reconnect': '與伺服器的連線已中斷，正在嘗試重新連線。',
    'remote_err_download': '下載失敗，請檢查網路後重試。',
    'remote_err_upload': '上傳失敗，請檢查網路後重試。',
    'remote_err_delete': '刪除失敗，請重試。',
    'remote_err_rename': '重新命名失敗，請重試。',
    'remote_err_create_dir': '建立資料夾失敗，請重試。',
    'remote_err_dir_open': '無法開啟此資料夾，請確認你有存取權限。',
    'remote_err_server': '伺服器回傳錯誤（狀態碼 {code}），請聯絡伺服器管理員。',
    'remote_err_generic': '操作失敗，請重試。',
}
JA_NEW = {
    'remote_err_cancelled': '操作がキャンセルされました',
    'remote_err_auth': 'ログイン失敗：ユーザー名またはパスワードが違います。鍵認証の場合は秘密鍵とそのパスフレーズを確認してください。',
    'remote_err_not_connected': 'サーバーに接続されていません。先に接続してから再試行してください。',
    'remote_err_not_found': 'ファイルまたはフォルダが存在しません（移動または削除された可能性があります）。',
    'remote_err_timeout': '接続がタイムアウトしました：サーバーの応答が遅いかネットワークが不安定です。後ほど再試行してください。',
    'remote_err_connection': 'サーバーに接続できません：アドレス、ポート、ネットワーク、およびサーバーが起動しているかを確認してください。',
    'remote_err_reconnect': 'サーバーへの接続が切れました。再接続を試みています。',
    'remote_err_download': 'ダウンロードに失敗しました。ネットワークを確認して再試行してください。',
    'remote_err_upload': 'アップロードに失敗しました。ネットワークを確認して再試行してください。',
    'remote_err_delete': '削除に失敗しました。再試行してください。',
    'remote_err_rename': '名前の変更に失敗しました。再試行してください。',
    'remote_err_create_dir': 'フォルダの作成に失敗しました。再試行してください。',
    'remote_err_dir_open': 'このフォルダを開けません。アクセス権があるか確認してください。',
    'remote_err_server': 'サーバーがエラーを返しました（ステータスコード {code}）。サーバー管理者に連絡してください。',
    'remote_err_generic': '操作に失敗しました。再試行してください。',
}
KO_NEW = {
    'remote_err_cancelled': '작업이 취소되었습니다',
    'remote_err_auth': '로그인 실패: 사용자 이름이나 비밀번호가 잘못되었습니다. 키 로그인 시 개인키와 비밀번호를 확인하세요.',
    'remote_err_not_connected': '서버에 연결되어 있지 않습니다. 먼저 연결한 후 다시 시도하세요.',
    'remote_err_not_found': '파일 또는 폴더가 존재하지 않습니다(이동되거나 삭제되었을 수 있음).',
    'remote_err_timeout': '연결 시간 초과: 서버 응답이 너무 느리거나 네트워크가 불안정합니다. 나중에 다시 시도하세요.',
    'remote_err_connection': '서버에 연결할 수 없습니다: 주소, 포트, 네트워크 및 서버가 실행 중인지 확인하세요.',
    'remote_err_reconnect': '서버와의 연결이 끊겼습니다. 다시 연결을 시도하는 중입니다.',
    'remote_err_download': '다운로드 실패. 네트워크를 확인하고 다시 시도하세요.',
    'remote_err_upload': '업로드 실패. 네트워크를 확인하고 다시 시도하세요.',
    'remote_err_delete': '삭제 실패. 다시 시도하세요.',
    'remote_err_rename': '이름 변경 실패. 다시 시도하세요.',
    'remote_err_create_dir': '폴더 생성 실패. 다시 시도하세요.',
    'remote_err_dir_open': '이 폴더를 열 수 없습니다. 접근 권한이 있는지 확인하세요.',
    'remote_err_server': '서버가 오류를 반환했습니다(상태 코드 {code}). 서버 관리자에게 문의하세요.',
    'remote_err_generic': '작업 실패. 다시 시도하세요.',
}
RU_NEW = {
    'remote_err_cancelled': 'Операция отменена',
    'remote_err_auth': 'Ошибка входа: неверное имя пользователя или пароль. При входе по ключу проверьте закрытый ключ и его пароль.',
    'remote_err_not_connected': 'Нет подключения к серверу. Сначала подключитесь и повторите попытку.',
    'remote_err_not_found': 'Файл или папка не существует (возможно, перемещены или удалены).',
    'remote_err_timeout': 'Истекло время ожидания подключения: сервер отвечает слишком медленно или сеть нестабильна. Повторите позже.',
    'remote_err_connection': 'Не удалось подключиться к серверу: проверьте адрес, порт, сеть и то, что сервер запущен.',
    'remote_err_reconnect': 'Соединение с сервером потеряно, выполняется повторное подключение.',
    'remote_err_download': 'Не удалось загрузить. Проверьте сеть и повторите попытку.',
    'remote_err_upload': 'Не удалось отправить. Проверьте сеть и повторите попытку.',
    'remote_err_delete': 'Не удалось удалить. Повторите попытку.',
    'remote_err_rename': 'Не удалось переименовать. Повторите попытку.',
    'remote_err_create_dir': 'Не удалось создать папку. Повторите попытку.',
    'remote_err_dir_open': 'Не удаётся открыть эту папку. Убедитесь, что у вас есть доступ.',
    'remote_err_server': 'Сервер вернул ошибку (код состояния {code}). Обратитесь к администратору сервера.',
    'remote_err_generic': 'Операция не выполнена. Повторите попытку.',
}
FR_NEW = {
    'remote_err_cancelled': 'Opération annulée',
    'remote_err_auth': "Échec de la connexion : nom d'utilisateur ou mot de passe incorrect. En cas d'authentification par clé, vérifiez la clé privée et sa phrase de passe.",
    'remote_err_not_connected': "Non connecté au serveur. Connectez-vous d'abord et réessayez.",
    'remote_err_not_found': "Le fichier ou le dossier n'existe pas (il a peut-être été déplacé ou supprimé).",
    'remote_err_timeout': "Délai de connexion dépassé : le serveur répond trop lentement ou le réseau est instable. Réessayez plus tard.",
    'remote_err_connection': "Impossible de se connecter au serveur : vérifiez l'adresse, le port, le réseau et que le serveur est démarré.",
    'remote_err_reconnect': "La connexion au serveur a été perdue et tente de se reconnecter.",
    'remote_err_download': 'Échec du téléchargement. Vérifiez le réseau et réessayez.',
    'remote_err_upload': "Échec de l'envoi. Vérifiez le réseau et réessayez.",
    'remote_err_delete': 'Échec de la suppression. Réessayez.',
    'remote_err_rename': 'Échec du renommage. Réessayez.',
    'remote_err_create_dir': 'Échec de la création du dossier. Réessayez.',
    'remote_err_dir_open': "Impossible d'ouvrir ce dossier. Assurez-vous que vous y avez accès.",
    'remote_err_server': "Le serveur a renvoyé une erreur (code d'état {code}). Contactez l'administrateur du serveur.",
    'remote_err_generic': "Échec de l'opération. Réessayez.",
}
ES_NEW = {
    'remote_err_cancelled': 'Operación cancelada',
    'remote_err_auth': 'Error de inicio de sesión: usuario o contraseña incorrectos. Si usas clave, comprueba la clave privada y su contraseña.',
    'remote_err_not_connected': 'No conectado al servidor. Conéctate primero e inténtalo de nuevo.',
    'remote_err_not_found': 'El archivo o carpeta no existe (puede que se haya movido o eliminado).',
    'remote_err_timeout': 'Tiempo de conexión agotado: el servidor responde demasiado lento o la red es inestable. Inténtalo más tarde.',
    'remote_err_connection': 'No se pudo conectar al servidor: comprueba la dirección, el puerto, la red y que el servidor está en marcha.',
    'remote_err_reconnect': 'Se perdió la conexión con el servidor y se está intentando reconectar.',
    'remote_err_download': 'Error de descarga. Comprueba la red e inténtalo de nuevo.',
    'remote_err_upload': 'Error de subida. Comprueba la red e inténtalo de nuevo.',
    'remote_err_delete': 'Error al eliminar. Inténtalo de nuevo.',
    'remote_err_rename': 'Error al renombrar. Inténtalo de nuevo.',
    'remote_err_create_dir': 'Error al crear la carpeta. Inténtalo de nuevo.',
    'remote_err_dir_open': 'No se puede abrir esta carpeta. Asegúrate de tener acceso.',
    'remote_err_server': 'El servidor devolvió un error (código de estado {code}). Contacta al administrador del servidor.',
    'remote_err_generic': 'Error en la operación. Inténtalo de nuevo.',
}
DE_NEW = {
    'remote_err_cancelled': 'Vorgang abgebrochen',
    'remote_err_auth': 'Anmeldung fehlgeschlagen: Benutzername oder Passwort falsch. Bei Schlüsselanmeldung private Schlüsseldatei und Passphrase prüfen.',
    'remote_err_not_connected': 'Nicht mit dem Server verbunden. Stelle zuerst die Verbindung her und versuche es erneut.',
    'remote_err_not_found': 'Datei oder Ordner existiert nicht (möglicherweise verschoben oder gelöscht).',
    'remote_err_timeout': 'Verbindungstimeout: Server antwortet zu langsam oder Netzwerk instabil. Bitte später erneut versuchen.',
    'remote_err_connection': 'Verbindung zum Server fehlgeschlagen: Adresse, Port, Netzwerk und dass der Server läuft prüfen.',
    'remote_err_reconnect': 'Die Verbindung zum Server wurde getrennt und es wird versucht, sie wiederherzustellen.',
    'remote_err_download': 'Download fehlgeschlagen. Netzwerk prüfen und erneut versuchen.',
    'remote_err_upload': 'Upload fehlgeschlagen. Netzwerk prüfen und erneut versuchen.',
    'remote_err_delete': 'Löschen fehlgeschlagen. Erneut versuchen.',
    'remote_err_rename': 'Umbenennen fehlgeschlagen. Erneut versuchen.',
    'remote_err_create_dir': 'Ordner erstellen fehlgeschlagen. Erneut versuchen.',
    'remote_err_dir_open': 'Dieser Ordner kann nicht geöffnet werden. Stelle sicher, dass du Zugriff hast.',
    'remote_err_server': 'Der Server lieferte einen Fehler (Statuscode {code}). Kontaktiere den Server-Admin.',
    'remote_err_generic': 'Vorgang fehlgeschlagen. Erneut versuchen.',
}
AR_NEW = {
    'remote_err_cancelled': 'تم إلغاء العملية',
    'remote_err_auth': 'فشل تسجيل الدخول: اسم المستخدم أو كلمة المرور غير صحيحين. عند استخدام مفتاح، تحقق من المفتاح الخاص وكلمة المرور الخاصة به.',
    'remote_err_not_connected': 'غير متصل بالخادم. اتصل أولاً ثم حاول مجدداً.',
    'remote_err_not_found': 'الملف أو المجلد غير موجود (ربما تم نقله أو حذفه).',
    'remote_err_timeout': 'انتهت مهلة الاتصال: استجابة الخادم بطيئة جداً أو الشبكة غير مستقرة. حاول لاحقاً.',
    'remote_err_connection': 'تعذر الاتصال بالخادم: تحقق من العنوان والمنفذ والشبكة وأن الخادم يعمل.',
    'remote_err_reconnect': 'انقطع الاتصال بالخادم ويجري محاولة إعادة الاتصال.',
    'remote_err_download': 'فشل التنزيل. تحقق من الشبكة وحاول مجدداً.',
    'remote_err_upload': 'فشل الرفع. تحقق من الشبكة وحاول مجدداً.',
    'remote_err_delete': 'فشل الحذف. حاول مجدداً.',
    'remote_err_rename': 'فشل إعادة التسمية. حاول مجدداً.',
    'remote_err_create_dir': 'فشل إنشاء المجلد. حاول مجدداً.',
    'remote_err_dir_open': 'تعذر فتح هذا المجلد. تأكد أن لديك حق الوصول.',
    'remote_err_server': 'أرجع الخادم خطأً (رمز الحالة {code}). تواصل مع مسؤول الخادم.',
    'remote_err_generic': 'فشلت العملية. حاول مجدداً.',
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
        if key in PLACEHOLDER_META:
            lines.append('    "description": "v2.1.3 remote error localization: %s",' % key)
            lines.append('    "placeholders": {')
            lines.append('      "%s": {}' % PLACEHOLDER_META[key])
            lines.append('    }')
        else:
            lines.append('    "description": "v2.1.3 remote error localization: %s"' % key)
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
        # 定位 getter 的真正结束（'），避免值内含 ASCII ';' 时插入到字符串中间。
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
