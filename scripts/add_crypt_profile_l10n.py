#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""向 10 个 ARB + 基类 + 9 个 locale dart 插入 crypt_profile_* 新 key。

铁律：
- lib/l10n/app_*.arb 用 CRLF，lib/l10n/generated/*.dart 用 LF
  → 全程二进制读写，绝不触发 Python 的换行转换。
- 按锚点插入（锚点 = crypt_settings_title），不重跑 gen-l10n
  （会覆盖手工合并的 L10nZh / L10nZhTw）。
- zh.dart 里 crypt_settings_title 出现两次（L10nZh、L10nZhTw），
  第一次用 app_zh.arb 的值，第二次用 app_zh_TW.arb 的值。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

KEYS = [
    'crypt_profile_name',
    'crypt_profile_name_hint',
    'crypt_profile_name_required',
    'crypt_profile_name_duplicate',
    'crypt_profile_title_new',
    'crypt_profile_title_edit',
    'crypt_profile_section',
    'crypt_profile_add',
    'crypt_profile_default',
    'crypt_profile_set_default',
    'crypt_profile_set_default_desc',
    'crypt_profile_default_done',
    'crypt_profile_delete_message',
    'crypt_profile_empty',
    'crypt_profile_action_config',
    'crypt_profile_select_title',
    'crypt_profile_bound_done',
    'crypt_profile_credential_locked',
    'crypt_profile_credential_locked_desc',
    'crypt_profile_suffix_none',
    'crypt_profile_sandbox_title',
    'crypt_profile_sandbox_message',
    'crypt_mount_section',
]

EN = {
    'crypt_profile_name': 'Encryption name',
    'crypt_profile_name_hint': 'e.g. Work / Personal',
    'crypt_profile_name_required': 'Please enter an encryption name',
    'crypt_profile_name_duplicate': 'This name already exists',
    'crypt_profile_title_new': 'New encryption profile',
    'crypt_profile_title_edit': 'Edit encryption profile',
    'crypt_profile_section': 'Encryption profiles',
    'crypt_profile_add': 'New profile',
    'crypt_profile_default': 'Default',
    'crypt_profile_set_default': 'Set as default',
    'crypt_profile_set_default_desc': 'Files without a bound profile use this one',
    'crypt_profile_default_done': 'Default profile updated',
    'crypt_profile_delete_message': 'Deleting this profile makes files encrypted with it undecryptable.',
    'crypt_profile_empty': 'No encryption profile yet',
    'crypt_profile_action_config': 'Profile',
    'crypt_profile_select_title': 'Select encryption profile',
    'crypt_profile_bound_done': 'Profile bound',
    'crypt_profile_credential_locked': 'Locked',
    'crypt_profile_credential_locked_desc': 'Password and salt define the key. Changing them makes existing files undecryptable - create a new profile instead.',
    'crypt_profile_suffix_none': 'no suffix',
    'crypt_profile_sandbox_title': 'Switch sandbox profile',
    'crypt_profile_sandbox_message': 'The sandbox uses one profile as a whole. Other sandbox files may show as ciphertext after switching. Continue?',
    'crypt_mount_section': 'Encrypted locations',
}

ZH = {
    'crypt_profile_name': '加密名称',
    'crypt_profile_name_hint': '例如：工作 / 私人',
    'crypt_profile_name_required': '请输入加密名称',
    'crypt_profile_name_duplicate': '该名称已存在，请更换',
    'crypt_profile_title_new': '新建加密配置',
    'crypt_profile_title_edit': '编辑加密配置',
    'crypt_profile_section': '加密配置',
    'crypt_profile_add': '新建配置',
    'crypt_profile_default': '默认',
    'crypt_profile_set_default': '设为默认配置',
    'crypt_profile_set_default_desc': '未绑定配置的文件将使用此配置',
    'crypt_profile_default_done': '已更新默认配置',
    'crypt_profile_delete_message': '删除该配置后，使用它加密的文件将无法解密。',
    'crypt_profile_empty': '暂无加密配置',
    'crypt_profile_action_config': '配置',
    'crypt_profile_select_title': '选择加密配置',
    'crypt_profile_bound_done': '已绑定该加密配置',
    'crypt_profile_credential_locked': '不可修改',
    'crypt_profile_credential_locked_desc': '密码与加盐决定密钥，修改后已加密文件将无法解密；如需更换请新建配置。',
    'crypt_profile_suffix_none': '无后缀',
    'crypt_profile_sandbox_title': '切换沙盒配置',
    'crypt_profile_sandbox_message': '沙盒整体只使用一套配置，切换后沙盒内其他文件可能显示为密文。是否继续？',
    'crypt_mount_section': '加密位置',
}

ZH_TW = {
    'crypt_profile_name': '加密名稱',
    'crypt_profile_name_hint': '例如：工作 / 私人',
    'crypt_profile_name_required': '請輸入加密名稱',
    'crypt_profile_name_duplicate': '此名稱已存在，請更換',
    'crypt_profile_title_new': '新增加密配置',
    'crypt_profile_title_edit': '編輯加密配置',
    'crypt_profile_section': '加密配置',
    'crypt_profile_add': '新增配置',
    'crypt_profile_default': '預設',
    'crypt_profile_set_default': '設為預設配置',
    'crypt_profile_set_default_desc': '未綁定配置的檔案將使用此配置',
    'crypt_profile_default_done': '已更新預設配置',
    'crypt_profile_delete_message': '刪除此配置後，使用它加密的檔案將無法解密。',
    'crypt_profile_empty': '尚無加密配置',
    'crypt_profile_action_config': '配置',
    'crypt_profile_select_title': '選擇加密配置',
    'crypt_profile_bound_done': '已綁定此加密配置',
    'crypt_profile_credential_locked': '不可修改',
    'crypt_profile_credential_locked_desc': '密碼與加鹽決定金鑰，修改後已加密檔案將無法解密；如需更換請新增配置。',
    'crypt_profile_suffix_none': '無後綴',
    'crypt_profile_sandbox_title': '切換沙盒配置',
    'crypt_profile_sandbox_message': '沙盒整體只使用一套配置，切換後沙盒內其他檔案可能顯示為密文。是否繼續？',
    'crypt_mount_section': '加密位置',
}

JA = {
    'crypt_profile_name': '暗号化名',
    'crypt_profile_name_hint': '例：仕事 / プライベート',
    'crypt_profile_name_required': '暗号化名を入力してください',
    'crypt_profile_name_duplicate': 'この名前は既に存在します',
    'crypt_profile_title_new': '暗号化設定を新規作成',
    'crypt_profile_title_edit': '暗号化設定を編集',
    'crypt_profile_section': '暗号化設定',
    'crypt_profile_add': '新規設定',
    'crypt_profile_default': 'デフォルト',
    'crypt_profile_set_default': 'デフォルトに設定',
    'crypt_profile_set_default_desc': '設定が未指定のファイルはこれを使用します',
    'crypt_profile_default_done': 'デフォルト設定を更新しました',
    'crypt_profile_delete_message': 'この設定を削除すると、それで暗号化したファイルは復号できなくなります。',
    'crypt_profile_empty': '暗号化設定がありません',
    'crypt_profile_action_config': '設定',
    'crypt_profile_select_title': '暗号化設定を選択',
    'crypt_profile_bound_done': '暗号化設定を紐付けました',
    'crypt_profile_credential_locked': '変更不可',
    'crypt_profile_credential_locked_desc': 'パスワードとソルトが鍵を決定します。変更すると既存の暗号化ファイルは復号できなくなります。変更する場合は新しい設定を作成してください。',
    'crypt_profile_suffix_none': '拡張子なし',
    'crypt_profile_sandbox_title': 'サンドボックスの設定を切り替え',
    'crypt_profile_sandbox_message': 'サンドボックスは全体で1つの設定を使用します。切り替えると他のファイルが暗号名で表示される場合があります。続けますか？',
    'crypt_mount_section': '暗号化された場所',
}

KO = {
    'crypt_profile_name': '암호화 이름',
    'crypt_profile_name_hint': '예: 업무 / 개인',
    'crypt_profile_name_required': '암호화 이름을 입력하세요',
    'crypt_profile_name_duplicate': '이미 존재하는 이름입니다',
    'crypt_profile_title_new': '암호화 설정 새로 만들기',
    'crypt_profile_title_edit': '암호화 설정 편집',
    'crypt_profile_section': '암호화 설정',
    'crypt_profile_add': '새 설정',
    'crypt_profile_default': '기본',
    'crypt_profile_set_default': '기본으로 설정',
    'crypt_profile_set_default_desc': '설정이 지정되지 않은 파일은 이 설정을 사용합니다',
    'crypt_profile_default_done': '기본 설정이 변경되었습니다',
    'crypt_profile_delete_message': '이 설정을 삭제하면 해당 설정으로 암호화된 파일은 복호화할 수 없습니다.',
    'crypt_profile_empty': '암호화 설정이 없습니다',
    'crypt_profile_action_config': '설정',
    'crypt_profile_select_title': '암호화 설정 선택',
    'crypt_profile_bound_done': '암호화 설정이 연결되었습니다',
    'crypt_profile_credential_locked': '수정 불가',
    'crypt_profile_credential_locked_desc': '비밀번호와 솔트가 키를 결정합니다. 변경하면 기존 암호화 파일을 복호화할 수 없습니다. 변경이 필요하면 새 설정을 만드세요.',
    'crypt_profile_suffix_none': '접미사 없음',
    'crypt_profile_sandbox_title': '샌드박스 설정 변경',
    'crypt_profile_sandbox_message': '샌드박스는 전체가 하나의 설정을 사용합니다. 변경하면 다른 파일이 암호문으로 표시될 수 있습니다. 계속하시겠습니까?',
    'crypt_mount_section': '암호화 위치',
}

DE = {
    'crypt_profile_name': 'Verschlüsselungsname',
    'crypt_profile_name_hint': 'z. B. Arbeit / Privat',
    'crypt_profile_name_required': 'Bitte Verschlüsselungsnamen eingeben',
    'crypt_profile_name_duplicate': 'Dieser Name existiert bereits',
    'crypt_profile_title_new': 'Neues Verschlüsselungsprofil',
    'crypt_profile_title_edit': 'Verschlüsselungsprofil bearbeiten',
    'crypt_profile_section': 'Verschlüsselungsprofile',
    'crypt_profile_add': 'Neues Profil',
    'crypt_profile_default': 'Standard',
    'crypt_profile_set_default': 'Als Standard festlegen',
    'crypt_profile_set_default_desc': 'Dateien ohne zugeordnetes Profil nutzen dieses',
    'crypt_profile_default_done': 'Standardprofil aktualisiert',
    'crypt_profile_delete_message': 'Beim Löschen dieses Profils können damit verschlüsselte Dateien nicht mehr entschlüsselt werden.',
    'crypt_profile_empty': 'Noch kein Verschlüsselungsprofil',
    'crypt_profile_action_config': 'Profil',
    'crypt_profile_select_title': 'Verschlüsselungsprofil wählen',
    'crypt_profile_bound_done': 'Profil zugeordnet',
    'crypt_profile_credential_locked': 'Gesperrt',
    'crypt_profile_credential_locked_desc': 'Passwort und Salt bestimmen den Schlüssel. Nach einer Änderung sind verschlüsselte Dateien nicht mehr lesbar - erstelle stattdessen ein neues Profil.',
    'crypt_profile_suffix_none': 'kein Suffix',
    'crypt_profile_sandbox_title': 'Sandbox-Profil wechseln',
    'crypt_profile_sandbox_message': 'Die Sandbox nutzt insgesamt ein Profil. Nach dem Wechsel können andere Dateien als Chiffre angezeigt werden. Fortfahren?',
    'crypt_mount_section': 'Verschlüsselte Orte',
}

ES = {
    'crypt_profile_name': 'Nombre de cifrado',
    'crypt_profile_name_hint': 'p. ej. Trabajo / Personal',
    'crypt_profile_name_required': 'Introduce un nombre de cifrado',
    'crypt_profile_name_duplicate': 'Este nombre ya existe',
    'crypt_profile_title_new': 'Nuevo perfil de cifrado',
    'crypt_profile_title_edit': 'Editar perfil de cifrado',
    'crypt_profile_section': 'Perfiles de cifrado',
    'crypt_profile_add': 'Nuevo perfil',
    'crypt_profile_default': 'Predeterminado',
    'crypt_profile_set_default': 'Establecer como predeterminado',
    'crypt_profile_set_default_desc': 'Los archivos sin perfil asignado usan este',
    'crypt_profile_default_done': 'Perfil predeterminado actualizado',
    'crypt_profile_delete_message': 'Al eliminar este perfil, los archivos cifrados con él no se podrán descifrar.',
    'crypt_profile_empty': 'Aún no hay perfiles de cifrado',
    'crypt_profile_action_config': 'Perfil',
    'crypt_profile_select_title': 'Seleccionar perfil de cifrado',
    'crypt_profile_bound_done': 'Perfil asignado',
    'crypt_profile_credential_locked': 'Bloqueado',
    'crypt_profile_credential_locked_desc': 'La contraseña y la sal determinan la clave. Cambiarlas hará ilegibles los archivos cifrados; crea un perfil nuevo en su lugar.',
    'crypt_profile_suffix_none': 'sin sufijo',
    'crypt_profile_sandbox_title': 'Cambiar perfil del sandbox',
    'crypt_profile_sandbox_message': 'El sandbox usa un único perfil en conjunto. Tras el cambio, otros archivos podrían mostrarse como cifrados. ¿Continuar?',
    'crypt_mount_section': 'Ubicaciones cifradas',
}

FR = {
    'crypt_profile_name': 'Nom du chiffrement',
    'crypt_profile_name_hint': 'ex. Travail / Personnel',
    'crypt_profile_name_required': 'Veuillez saisir un nom de chiffrement',
    'crypt_profile_name_duplicate': 'Ce nom existe déjà',
    'crypt_profile_title_new': 'Nouveau profil de chiffrement',
    'crypt_profile_title_edit': 'Modifier le profil de chiffrement',
    'crypt_profile_section': 'Profils de chiffrement',
    'crypt_profile_add': 'Nouveau profil',
    'crypt_profile_default': 'Par défaut',
    'crypt_profile_set_default': 'Définir par défaut',
    'crypt_profile_set_default_desc': 'Les fichiers sans profil associé utilisent celui-ci',
    'crypt_profile_default_done': 'Profil par défaut mis à jour',
    'crypt_profile_delete_message': 'Supprimer ce profil rendra illisibles les fichiers chiffrés avec celui-ci.',
    'crypt_profile_empty': 'Aucun profil de chiffrement',
    'crypt_profile_action_config': 'Profil',
    'crypt_profile_select_title': 'Choisir un profil de chiffrement',
    'crypt_profile_bound_done': 'Profil associé',
    'crypt_profile_credential_locked': 'Verrouillé',
    'crypt_profile_credential_locked_desc': "Le mot de passe et le sel déterminent la clé. Les modifier rendra les fichiers chiffrés illisibles - créez plutôt un nouveau profil.",
    'crypt_profile_suffix_none': 'sans suffixe',
    'crypt_profile_sandbox_title': 'Changer le profil du sandbox',
    'crypt_profile_sandbox_message': "Le sandbox utilise un seul profil dans son ensemble. Après le changement, d'autres fichiers peuvent s'afficher en texte chiffré. Continuer ?",
    'crypt_mount_section': 'Emplacements chiffrés',
}

RU = {
    'crypt_profile_name': 'Имя шифрования',
    'crypt_profile_name_hint': 'например: Работа / Личное',
    'crypt_profile_name_required': 'Введите имя шифрования',
    'crypt_profile_name_duplicate': 'Такое имя уже существует',
    'crypt_profile_title_new': 'Новый профиль шифрования',
    'crypt_profile_title_edit': 'Изменить профиль шифрования',
    'crypt_profile_section': 'Профили шифрования',
    'crypt_profile_add': 'Новый профиль',
    'crypt_profile_default': 'По умолчанию',
    'crypt_profile_set_default': 'Сделать по умолчанию',
    'crypt_profile_set_default_desc': 'Файлы без привязанного профиля используют этот',
    'crypt_profile_default_done': 'Профиль по умолчанию обновлён',
    'crypt_profile_delete_message': 'После удаления этого профиля зашифрованные им файлы нельзя будет расшифровать.',
    'crypt_profile_empty': 'Профилей шифрования пока нет',
    'crypt_profile_action_config': 'Профиль',
    'crypt_profile_select_title': 'Выберите профиль шифрования',
    'crypt_profile_bound_done': 'Профиль привязан',
    'crypt_profile_credential_locked': 'Заблокировано',
    'crypt_profile_credential_locked_desc': 'Пароль и соль определяют ключ. Изменение сделает зашифрованные файлы нечитаемыми — создайте новый профиль.',
    'crypt_profile_suffix_none': 'без суффикса',
    'crypt_profile_sandbox_title': 'Сменить профиль песочницы',
    'crypt_profile_sandbox_message': 'Песочница использует один профиль целиком. После смены другие файлы могут отображаться как шифротекст. Продолжить?',
    'crypt_mount_section': 'Зашифрованные расположения',
}

AR = {
    'crypt_profile_name': 'اسم التشفير',
    'crypt_profile_name_hint': 'مثال: العمل / شخصي',
    'crypt_profile_name_required': 'يرجى إدخال اسم التشفير',
    'crypt_profile_name_duplicate': 'هذا الاسم موجود بالفعل',
    'crypt_profile_title_new': 'ملف تعريف تشفير جديد',
    'crypt_profile_title_edit': 'تحرير ملف تعريف التشفير',
    'crypt_profile_section': 'ملفات تعريف التشفير',
    'crypt_profile_add': 'ملف تعريف جديد',
    'crypt_profile_default': 'الافتراضي',
    'crypt_profile_set_default': 'تعيين كافتراضي',
    'crypt_profile_set_default_desc': 'الملفات بدون ملف تعريف مرتبط تستخدم هذا',
    'crypt_profile_default_done': 'تم تحديث الملف الافتراضي',
    'crypt_profile_delete_message': 'حذف ملف التعريف هذا يجعل الملفات المشفرة به غير قابلة للفك.',
    'crypt_profile_empty': 'لا يوجد ملف تعريف تشفير بعد',
    'crypt_profile_action_config': 'ملف التعريف',
    'crypt_profile_select_title': 'اختيار ملف تعريف التشفير',
    'crypt_profile_bound_done': 'تم ربط ملف التعريف',
    'crypt_profile_credential_locked': 'مقفل',
    'crypt_profile_credential_locked_desc': 'كلمة المرور والملح يحددان المفتاح. تغييرهما يجعل الملفات المشفرة غير قابلة للفك — أنشئ ملف تعريف جديدًا بدلًا من ذلك.',
    'crypt_profile_suffix_none': 'بدون لاحقة',
    'crypt_profile_sandbox_title': 'تغيير ملف تعريف Sandbox',
    'crypt_profile_sandbox_message': 'تستخدم Sandbox ملف تعريف واحدًا ككل. بعد التغيير قد تظهر ملفات أخرى كنص مشفر. المتابعة؟',
    'crypt_mount_section': 'المواقع المشفرة',
}

LANGS = {
    'en': EN, 'zh': ZH, 'zh_TW': ZH_TW, 'ja': JA, 'ko': KO,
    'de': DE, 'es': ES, 'fr': FR, 'ru': RU, 'ar': AR,
}

# dart locale 文件对应的语言
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
    # 找到锚点 @meta 块的结尾 "  },"
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

    # zh.dart 有 L10nZh / L10nZhTw 两处：第一处用 zh，第二处用 zh_TW
    tables = [LANGS[lang]] if len(occurrences) == 1 else [ZH, ZH_TW]
    if len(occurrences) > 2:
        raise SystemExit('unexpected %d occurrences in %s' % (len(occurrences), path))

    # 从后往前插，避免位置偏移
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
