#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""加密相关 l10n 补齐（2026-09-11）：
A) 新增 15 个 key（vault_exporting 等，替换代码里硬编码的中英文案）→ 插入 10 ARB + dart；
B) 把 ko/ja/ru/fr/es/ar/de 七个语言里 82 个「英文占位」crypt_/vault_ key 替换为真翻译。

铁律（同 add_crypt_profile_l10n.py）：
- app_*.arb 为 CRLF，generated/*.dart 为 LF → 全程二进制读写；
- 按锚点插入，绝不重跑 gen-l10n（会覆盖手工合并的 L10nZh/L10nZhTw）；
- zh.dart 双类：第一处 L10nZh 用 zh 值，第二处 L10nZhTw 用 zh_TW 值。
"""
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

# ───────────────────────── A) 新 key ─────────────────────────
NEW_KEYS = [
    'vault_exporting', 'vault_importing', 'vault_importing_backup',
    'vault_restoring', 'vault_decrypting', 'vault_import_backup_confirm',
    'vault_load_error', 'vault_restore_folder_hint', 'vault_decrypt_open_failed',
    'vault_badge_inplace', 'vault_badge_sandbox', 'vault_item_folder',
    'crypt_need_master_title', 'crypt_need_master_body', 'crypt_master_banner',
]

# 带占位符的 key：key -> 参数名
PLACEHOLDER_PARAMS = {
    'vault_load_error': 'error',
    'vault_decrypt_open_failed': 'error',
}

EN_NEW = {
    'vault_exporting': 'Exporting...',
    'vault_importing': 'Importing...',
    'vault_importing_backup': 'Importing backup...',
    'vault_restoring': 'Restoring...',
    'vault_decrypting': 'Decrypting...',
    'vault_import_backup_confirm': 'Importing will overwrite the current vault sandbox and encryption config with the backup contents (unlock password is not affected). Continue?',
    'vault_load_error': 'Failed to load vault: {error}',
    'vault_restore_folder_hint': 'For folders, long-press and choose "Restore" to view them at the original location',
    'vault_decrypt_open_failed': 'Failed to decrypt and open: {error}',
    'vault_badge_inplace': 'In-place',
    'vault_badge_sandbox': 'Sandbox',
    'vault_item_folder': 'Folder',
    'crypt_need_master_title': 'Encryption master password not set',
    'crypt_need_master_body': 'In-place and sandbox encryption both use the master password from Encryption settings. Please set it up first.',
    'crypt_master_banner': 'The master password and salt configured here are used for in-place and sandbox encryption. Keep them safe; they are independent of the vault unlock password.',
}

ZH_NEW = {
    'vault_exporting': '正在导出...',
    'vault_importing': '正在导入...',
    'vault_importing_backup': '正在导入备份...',
    'vault_restoring': '正在恢复...',
    'vault_decrypting': '正在解密...',
    'vault_import_backup_confirm': '导入将用备份内容覆盖当前保险箱沙盒与加密配置（解锁密码不受影响）。是否继续？',
    'vault_load_error': '加载保险箱出错：{error}',
    'vault_restore_folder_hint': '文件夹请长按后选择「恢复」到原位置查看',
    'vault_decrypt_open_failed': '解密并打开项目失败：{error}',
    'vault_badge_inplace': '原地',
    'vault_badge_sandbox': '沙盒',
    'vault_item_folder': '文件夹',
    'crypt_need_master_title': '尚未设置加密主密码',
    'crypt_need_master_body': '原地加密与沙盒加密都使用「加密设置」中的主密码，请先前往设置。',
    'crypt_master_banner': '此处配置的主密码与加盐用于原地加密和沙盒加密，请务必牢记；它与保险箱解锁密码相互独立。',
}

ZH_TW_NEW = {
    'vault_exporting': '正在匯出...',
    'vault_importing': '正在匯入...',
    'vault_importing_backup': '正在匯入備份...',
    'vault_restoring': '正在還原...',
    'vault_decrypting': '正在解密...',
    'vault_import_backup_confirm': '匯入將以備份內容覆蓋目前保險箱沙盒與加密配置（解鎖密碼不受影響）。是否繼續？',
    'vault_load_error': '載入保險箱出錯：{error}',
    'vault_restore_folder_hint': '資料夾請長按後選擇「還原」到原始位置查看',
    'vault_decrypt_open_failed': '解密並開啟項目失敗：{error}',
    'vault_badge_inplace': '原地',
    'vault_badge_sandbox': '沙盒',
    'vault_item_folder': '資料夾',
    'crypt_need_master_title': '尚未設定加密主密碼',
    'crypt_need_master_body': '原地加密與沙盒加密都使用「加密設定」中的主密碼，請先前往設定。',
    'crypt_master_banner': '此處配置的主密碼與加鹽用於原地加密和沙盒加密，請務必牢記；它與保險箱解鎖密碼相互獨立。',
}

JA_NEW = {
    'vault_exporting': 'エクスポート中...',
    'vault_importing': 'インポート中...',
    'vault_importing_backup': 'バックアップをインポート中...',
    'vault_restoring': '復元中...',
    'vault_decrypting': '復号中...',
    'vault_import_backup_confirm': 'インポートすると、バックアップの内容でサンドボックスと暗号化設定が上書きされます（ロック解除パスワードは影響しません）。続けますか？',
    'vault_load_error': '保管庫の読み込みエラー：{error}',
    'vault_restore_folder_hint': 'フォルダは長押しで「復元」を選ぶと元の場所で表示できます',
    'vault_decrypt_open_failed': '復号して開くのに失敗しました：{error}',
    'vault_badge_inplace': 'その場',
    'vault_badge_sandbox': 'サンドボックス',
    'vault_item_folder': 'フォルダ',
    'crypt_need_master_title': '暗号化マスターパスワードが未設定です',
    'crypt_need_master_body': 'その場暗号化とサンドボックス暗号化の両方で「暗号化設定」のマスターパスワードを使用します。先に設定してください。',
    'crypt_master_banner': 'ここで設定するマスターパスワードとソルトは、その場暗号化とサンドボックス暗号化に使用されます。必ず覚えてください。保管庫のロック解除パスワードとは独立しています。',
}

KO_NEW = {
    'vault_exporting': '내보내는 중...',
    'vault_importing': '가져오는 중...',
    'vault_importing_backup': '백업 가져오는 중...',
    'vault_restoring': '복원하는 중...',
    'vault_decrypting': '복호화하는 중...',
    'vault_import_backup_confirm': '가져오면 백업 내용으로 현재 금고 샌드박스와 암호화 설정을 덮어씁니다(잠금 해제 비밀번호는 영향 없음). 계속하시겠습니까?',
    'vault_load_error': '금고 로드 오류: {error}',
    'vault_restore_folder_hint': '폴더는 길게 눌러 「복원」을 선택하면 원래 위치에서 볼 수 있습니다',
    'vault_decrypt_open_failed': '복호화 후 열기 실패: {error}',
    'vault_badge_inplace': '제자리',
    'vault_badge_sandbox': '샌드박스',
    'vault_item_folder': '폴더',
    'crypt_need_master_title': '암호화 마스터 비밀번호 미설정',
    'crypt_need_master_body': '제자리 암호화와 샌드박스 암호화는 모두 「암호화 설정」의 마스터 비밀번호를 사용합니다. 먼저 설정해 주세요.',
    'crypt_master_banner': '여기서 설정한 마스터 비밀번호와 솔트는 제자리 암호화와 샌드박스 암호화에 사용됩니다. 반드시 기억하세요. 금고 잠금 해제 비밀번호와는 독립적입니다.',
}

RU_NEW = {
    'vault_exporting': 'Экспорт...',
    'vault_importing': 'Импорт...',
    'vault_importing_backup': 'Импорт резервной копии...',
    'vault_restoring': 'Восстановление...',
    'vault_decrypting': 'Расшифровка...',
    'vault_import_backup_confirm': 'Импорт перезапишет текущую песочницу и настройки шифрования содержимым резервной копии (пароль разблокировки не изменится). Продолжить?',
    'vault_load_error': 'Ошибка загрузки хранилища: {error}',
    'vault_restore_folder_hint': 'Для папок используйте долгое нажатие → «Восстановить», чтобы увидеть их в исходном месте',
    'vault_decrypt_open_failed': 'Не удалось расшифровать и открыть: {error}',
    'vault_badge_inplace': 'На месте',
    'vault_badge_sandbox': 'Песочница',
    'vault_item_folder': 'Папка',
    'crypt_need_master_title': 'Не задан мастер-пароль шифрования',
    'crypt_need_master_body': 'Шифрование на месте и в песочнице используют мастер-пароль из настроек шифрования. Сначала задайте его.',
    'crypt_master_banner': 'Мастер-пароль и соль здесь используются для шифрования на месте и в песочнице. Обязательно запомните их; они не зависят от пароля разблокировки хранилища.',
}

FR_NEW = {
    'vault_exporting': 'Exportation...',
    'vault_importing': 'Importation...',
    'vault_importing_backup': 'Importation de la sauvegarde...',
    'vault_restoring': 'Restauration...',
    'vault_decrypting': 'Déchiffrement...',
    'vault_import_backup_confirm': "L'importation remplacera le sandbox et la configuration de chiffrement actuels par le contenu de la sauvegarde (le mot de passe de déverrouillage n'est pas affecté). Continuer ?",
    'vault_load_error': 'Erreur de chargement du coffre : {error}',
    'vault_restore_folder_hint': "Pour les dossiers, appuyez longuement et choisissez « Restaurer » pour les voir à leur emplacement d'origine",
    'vault_decrypt_open_failed': "Échec du déchiffrement et de l'ouverture : {error}",
    'vault_badge_inplace': 'Sur place',
    'vault_badge_sandbox': 'Sandbox',
    'vault_item_folder': 'Dossier',
    'crypt_need_master_title': 'Mot de passe maître de chiffrement non défini',
    'crypt_need_master_body': "Le chiffrement sur place et le sandbox utilisent le mot de passe maître des paramètres de chiffrement. Veuillez d'abord le configurer.",
    'crypt_master_banner': "Le mot de passe maître et le sel configurés ici servent au chiffrement sur place et au sandbox. Gardez-les en mémoire ; ils sont indépendants du mot de passe de déverrouillage du coffre.",
}

ES_NEW = {
    'vault_exporting': 'Exportando...',
    'vault_importing': 'Importando...',
    'vault_importing_backup': 'Importando copia de seguridad...',
    'vault_restoring': 'Restaurando...',
    'vault_decrypting': 'Descifrando...',
    'vault_import_backup_confirm': 'La importación sobrescribirá el sandbox y la configuración de cifrado actuales con el contenido de la copia (la contraseña de desbloqueo no se ve afectada). ¿Continuar?',
    'vault_load_error': 'Error al cargar la bóveda: {error}',
    'vault_restore_folder_hint': 'Para carpetas, mantén pulsado y elige «Restaurar» para verlas en su ubicación original',
    'vault_decrypt_open_failed': 'Error al descifrar y abrir: {error}',
    'vault_badge_inplace': 'In situ',
    'vault_badge_sandbox': 'Sandbox',
    'vault_item_folder': 'Carpeta',
    'crypt_need_master_title': 'Contraseña maestra de cifrado sin establecer',
    'crypt_need_master_body': 'El cifrado in situ y el sandbox usan la contraseña maestra de los ajustes de cifrado. Configúrala primero.',
    'crypt_master_banner': 'La contraseña maestra y la sal configuradas aquí se usan para el cifrado in situ y el sandbox. Guárdalas bien; son independientes de la contraseña de desbloqueo de la bóveda.',
}

DE_NEW = {
    'vault_exporting': 'Wird exportiert...',
    'vault_importing': 'Wird importiert...',
    'vault_importing_backup': 'Backup wird importiert...',
    'vault_restoring': 'Wird wiederhergestellt...',
    'vault_decrypting': 'Wird entschlüsselt...',
    'vault_import_backup_confirm': 'Beim Import werden die aktuelle Sandbox und die Verschlüsselungskonfiguration mit dem Backup-Inhalt überschrieben (das Entsperren-Passwort bleibt unberührt). Fortfahren?',
    'vault_load_error': 'Fehler beim Laden des Tresors: {error}',
    'vault_restore_folder_hint': 'Bei Ordnern lange drücken und „Wiederherstellen" wählen, um sie am ursprünglichen Ort zu sehen',
    'vault_decrypt_open_failed': 'Entschlüsseln und Öffnen fehlgeschlagen: {error}',
    'vault_badge_inplace': 'Vor Ort',
    'vault_badge_sandbox': 'Sandbox',
    'vault_item_folder': 'Ordner',
    'crypt_need_master_title': 'Verschlüsselungs-Masterpasswort nicht festgelegt',
    'crypt_need_master_body': 'Vor-Ort- und Sandbox-Verschlüsselung verwenden beide das Masterpasswort aus den Verschlüsselungseinstellungen. Bitte zuerst festlegen.',
    'crypt_master_banner': 'Das hier festgelegte Masterpasswort und Salz werden für Vor-Ort- und Sandbox-Verschlüsselung verwendet. Unbedingt merken; sie sind unabhängig vom Entsperren-Passwort des Tresors.',
}

AR_NEW = {
    'vault_exporting': 'جارٍ التصدير...',
    'vault_importing': 'جارٍ الاستيراد...',
    'vault_importing_backup': 'جارٍ استيراد النسخة الاحتياطية...',
    'vault_restoring': 'جارٍ الاستعادة...',
    'vault_decrypting': 'جارٍ فك التشفير...',
    'vault_import_backup_confirm': 'سيؤدي الاستيراد إلى الكتابة فوق صندوق الخزنة الحالي وإعدادات التشفير بمحتوى النسخة الاحتياطية (كلمة مرور فتح القفل غير متأثرة). المتابعة؟',
    'vault_load_error': 'فشل تحميل الخزنة: {error}',
    'vault_restore_folder_hint': 'للمجلدات، اضغط مطولاً واختر «استعادة» لعرضها في الموقع الأصلي',
    'vault_decrypt_open_failed': 'فشل فك التشفير والفتح: {error}',
    'vault_badge_inplace': 'في المكان',
    'vault_badge_sandbox': 'صندوق الحماية',
    'vault_item_folder': 'مجلد',
    'crypt_need_master_title': 'لم يتم تعيين كلمة المرور الرئيسية للتشفير',
    'crypt_need_master_body': 'يستخدم التشفير في المكان وصندوق الحماية كلاهما كلمة المرور الرئيسية من إعدادات التشفير. يرجى تعيينها أولاً.',
    'crypt_master_banner': 'كلمة المرور الرئيسية والملح المُعدَّان هنا يُستخدمان للتشفير في المكان وصندوق الحماية. احفظهما جيداً؛ فهما مستقلان عن كلمة مرور فتح قفل الخزنة.',
}

NEW_TABLES = {
    'en': EN_NEW, 'zh': ZH_NEW, 'zh_TW': ZH_TW_NEW, 'ja': JA_NEW, 'ko': KO_NEW,
    'ru': RU_NEW, 'fr': FR_NEW, 'es': ES_NEW, 'de': DE_NEW, 'ar': AR_NEW,
}

# ───────────────────── B) 82 个英文占位 key 的真翻译 ─────────────────────
# base32/base32768/base64 为技术名词，各语言保持一致，跳过。
TECH_KEYS = {'crypt_filename_enc_base32', 'crypt_filename_enc_base32768', 'crypt_filename_enc_base64'}

KO_FIX = {
    'crypt_action_browse': '둘러보기', 'crypt_action_decrypt': '복호화', 'crypt_action_encrypt': '지금 암호화',
    'crypt_action_share': '공유', 'crypt_add_mount': '암호화 폴더 추가',
    'crypt_advanced_toggle': '고급 암호화 옵션 표시', 'crypt_decrypt_failed': '복호화 실패: {error}',
    'crypt_decrypt_message': '모든 파일과 하위 폴더를 복호화합니다. 복호화 후 파일은 일반 상태로 복원됩니다. 계속하시겠습니까?',
    'crypt_decrypt_success': '복호화 완료', 'crypt_decrypt_title': '복호화 확인', 'crypt_decrypting': '복호화하는 중...',
    'crypt_delete_message': '"{name}"의 암호화 구성을 삭제할까요? 파일은 삭제되지 않습니다.',
    'crypt_delete_title': '암호화 폴더 삭제', 'crypt_dirname_enc_no': '아니요', 'crypt_dirname_enc_yes': '예',
    'crypt_edit_mount': '암호화 폴더 편집', 'crypt_encrypt_failed': '암호화 실패: {error}',
    'crypt_encrypt_message': '모든 파일과 하위 폴더를 암호화합니다. 암호화 후 다른 파일 관리자에서는 내용과 이름을 볼 수 없습니다. 계속하시겠습니까?',
    'crypt_encrypt_success': '암호화 완료', 'crypt_encrypt_title': '암호화 확인', 'crypt_encrypting': '암호화하는 중...',
    'crypt_error_password_mismatch': '비밀번호가 일치하지 않습니다', 'crypt_error_password_required': '비밀번호를 입력하세요',
    'crypt_error_password_short': '비밀번호는 4자 이상이어야 합니다', 'crypt_error_path_required': '폴더 경로를 선택하세요',
    'crypt_field_confirm_password': '비밀번호 확인', 'crypt_field_dirname_enc': '폴더 이름 암호화',
    'crypt_field_filename_enc': '파일 이름 암호화', 'crypt_field_filename_encoding': '파일 이름 인코딩',
    'crypt_field_name': '이름', 'crypt_field_name_hint': '비워 두면 폴더 이름 사용', 'crypt_field_password': '비밀번호',
    'crypt_field_path': '폴더 경로', 'crypt_field_path_hint': '암호화할 폴더 선택', 'crypt_field_salt': '솔트(선택)',
    'crypt_field_salt_hint': '비워 두면 자동 생성', 'crypt_field_suffix': '암호화 접미사',
    'crypt_filename_enc': '파일 이름 암호화', 'crypt_filename_enc_off': '끔', 'crypt_filename_enc_obfuscate': '난독화',
    'crypt_filename_enc_standard': '표준', 'crypt_mode_inplace': '제자리 암호화',
    'crypt_mode_inplace_desc': '파일은 제자리에 유지되며 이름과 내용이 암호화됩니다',
    'crypt_mode_sandbox': '샌드박스 암호화',
    'crypt_mode_sandbox_desc': '파일을 샌드박스로 이동합니다. 더 안전하지만 약간 느립니다',
    'crypt_no_mounts_subtitle': '아래 버튼을 눌러 첫 암호화 폴더를 추가하세요', 'crypt_no_mounts_title': '암호화 폴더 없음',
    'crypt_section_advanced': '고급 옵션', 'crypt_section_mode': '암호화 방식',
    'crypt_set_master_password': '암호화 마스터 비밀번호 설정', 'crypt_settings_subtitle': '암호화 폴더 및 마운트 지점 관리',
    'crypt_settings_title': '암호화',
    'crypt_share_hint': 'QR 코드를 스캔하면 암호화 구성을 가져옵니다. 파일 복호화에는 비밀번호가 필요합니다.',
    'crypt_share_password_note': 'QR 코드에는 비밀번호가 포함되지 않습니다. 안전한 채널로 별도로 공유하세요.',
    'crypt_share_title': '암호화 폴더 공유', 'vault_decrypt_action': '복호화',
    'vault_decrypt_confirm_desc': '"{name}"을(를) 복호화하시겠습니까? 복호화 후 파일은 일반 상태로 복원됩니다.',
    'vault_decrypt_confirm_title': '파일 복호화', 'vault_decrypt_failed': '복호화 실패: {error}',
    'vault_decrypt_success': '복호화 성공', 'vault_encrypt_failed': '암호화 실패: {error}',
    'vault_encrypt_files': '+ 파일 암호화', 'vault_encrypting': '암호화하는 중...',
    'vault_encrypting_desc': '선택한 파일/폴더를 암호화하는 중입니다. 잠시만 기다려 주세요...',
    'vault_export_backup_confirm': '백업 파일이 다음 위치에 저장됩니다:', 'vault_go_set_password': '비밀번호 설정',
    'vault_import_only_zip': '.zip 백업 파일만 지원됩니다',
    'vault_import_password_hint': '이 백업은 다른 비밀번호를 사용합니다. 백업을 만들 때 사용한 비밀번호로 금고를 다시 잠금 해제해 주세요',
    'vault_inplace_encrypt': '제자리 암호화',
    'vault_inplace_encrypt_desc': '파일은 원래 디렉터리에 그대로 있고, 암호화 후 파일 이름이 암호화되며, 브라우저에 🔐 배지가 표시됩니다',
    'vault_inplace_encrypt_done': '제자리 암호화 완료, {count}개 파일/폴더 암호화됨',
    'vault_inplace_section': '제자리 암호화', 'vault_need_set_password': '먼저 마스터 비밀번호 설정 필요',
    'vault_need_set_password_desc': '먼저 암호화 설정에서 암호화 마스터 비밀번호와 솔트를 구성하세요. 구성 후 제자리 암호화를 사용할 수 있습니다.',
    'vault_open_backup_location': '백업이 저장된 폴더를 열까요?', 'vault_open_location': '위치 열기',
    'vault_sandbox_encrypt': '샌드박스 암호화',
    'vault_sandbox_encrypt_desc': '파일은 금고 전용 디렉터리로 이동되고, 파일 이름이 숨겨지며, 금고 페이지에서만 보입니다',
    'vault_select_encryption_method': '암호화 방식 선택',
}

JA_FIX = {
    'crypt_action_browse': '表示', 'crypt_action_decrypt': '復号', 'crypt_action_encrypt': '今すぐ暗号化',
    'crypt_action_share': '共有', 'crypt_add_mount': '暗号化フォルダを追加',
    'crypt_advanced_toggle': '高度な暗号化オプションを表示', 'crypt_decrypt_failed': '復号に失敗しました: {error}',
    'crypt_decrypt_message': 'すべてのファイルとサブフォルダを復号します。復号後、ファイルは通常の状態に戻ります。続けますか？',
    'crypt_decrypt_success': '復号が完了しました', 'crypt_decrypt_title': '復号の確認', 'crypt_decrypting': '復号中...',
    'crypt_delete_message': '「{name}」の暗号化設定を削除しますか？ファイルは削除されません。',
    'crypt_delete_title': '暗号化フォルダを削除', 'crypt_dirname_enc_no': 'いいえ', 'crypt_dirname_enc_yes': 'はい',
    'crypt_edit_mount': '暗号化フォルダを編集', 'crypt_encrypt_failed': '暗号化に失敗しました: {error}',
    'crypt_encrypt_message': 'すべてのファイルとサブフォルダを暗号化します。暗号化後、他のファイルマネージャーでは内容と名前を表示できません。続けますか？',
    'crypt_encrypt_success': '暗号化が完了しました', 'crypt_encrypt_title': '暗号化の確認', 'crypt_encrypting': '暗号化中...',
    'crypt_error_password_mismatch': 'パスワードが一致しません', 'crypt_error_password_required': 'パスワードを入力してください',
    'crypt_error_password_short': 'パスワードは4文字以上である必要があります', 'crypt_error_path_required': 'フォルダパスを選択してください',
    'crypt_field_confirm_password': 'パスワード（確認）', 'crypt_field_dirname_enc': 'ディレクトリ名を暗号化',
    'crypt_field_filename_enc': 'ファイル名暗号化', 'crypt_field_filename_encoding': 'ファイル名エンコーディング',
    'crypt_field_name': '名前', 'crypt_field_name_hint': '空の場合はフォルダ名を使用', 'crypt_field_password': 'パスワード',
    'crypt_field_path': 'フォルダパス', 'crypt_field_path_hint': '暗号化するフォルダを選択',
    'crypt_field_salt': 'ソルト（任意）', 'crypt_field_salt_hint': '空の場合は自動生成',
    'crypt_field_suffix': '暗号化拡張子', 'crypt_filename_enc': 'ファイル名暗号化', 'crypt_filename_enc_off': 'オフ',
    'crypt_filename_enc_obfuscate': '難読化', 'crypt_filename_enc_standard': '標準',
    'crypt_mode_inplace': 'その場暗号化', 'crypt_mode_inplace_desc': 'ファイルはそのまま残り、名前と内容が暗号化されます',
    'crypt_mode_sandbox': 'サンドボックス暗号化',
    'crypt_mode_sandbox_desc': 'ファイルをサンドボックスへ移動。より安全ですがやや遅くなります',
    'crypt_no_mounts_subtitle': '下のボタンをタップして最初の暗号化フォルダを追加しましょう',
    'crypt_no_mounts_title': '暗号化フォルダがありません', 'crypt_section_advanced': '詳細オプション',
    'crypt_section_mode': '暗号化モード', 'crypt_set_master_password': '暗号化マスターパスワードを設定',
    'crypt_settings_subtitle': '暗号化フォルダとマウントポイントを管理', 'crypt_settings_title': '暗号化',
    'crypt_share_hint': 'QRコードをスキャンして暗号化設定を取り込みます。ファイルの復号にはパスワードが必要です。',
    'crypt_share_password_note': 'QRコードにパスワードは含まれません。安全な手段で別途共有してください。',
    'crypt_share_title': '暗号化フォルダを共有', 'vault_decrypt_action': '復号',
    'vault_decrypt_confirm_desc': '「{name}」を復号しますか？復号後、ファイルは通常の状態に戻ります。',
    'vault_decrypt_confirm_title': 'ファイルを復号', 'vault_decrypt_failed': '復号に失敗しました: {error}',
    'vault_decrypt_success': '復号に成功しました', 'vault_encrypt_failed': '暗号化に失敗しました: {error}',
    'vault_encrypt_files': '+ ファイルを暗号化', 'vault_encrypting': '暗号化中...',
    'vault_encrypting_desc': '選択したファイル/フォルダを暗号化しています。お待ちください...',
    'vault_export_backup_confirm': 'バックアップファイルは次の場所に保存されます：', 'vault_go_set_password': 'パスワードを設定',
    'vault_import_only_zip': '.zip バックアップファイルのみ対応しています',
    'vault_import_password_hint': 'このバックアップは別のパスワードを使用しています。バックアップ作成時のパスワードで保管庫のロックを再度解除してください',
    'vault_inplace_encrypt': 'その場暗号化',
    'vault_inplace_encrypt_desc': 'ファイルは元のディレクトリに残り、暗号化後にファイル名が暗号化されます。ブラウザには 🔐 バッジが表示されます',
    'vault_inplace_encrypt_done': 'その場暗号化が完了しました。{count} 個のファイル/フォルダを暗号化しました',
    'vault_inplace_section': 'その場暗号化', 'vault_need_set_password': '先にマスターパスワードを設定する必要があります',
    'vault_need_set_password_desc': '先に暗号化設定でマスターパスワードとソルトを設定してください。設定後、その場暗号化が利用できます。',
    'vault_open_backup_location': 'バックアップの保存先フォルダを開きますか？', 'vault_open_location': '場所を開く',
    'vault_sandbox_encrypt': 'サンドボックス暗号化',
    'vault_sandbox_encrypt_desc': 'ファイルは保管庫専用ディレクトリに移動され、ファイル名は隠され、保管庫ページでのみ表示されます',
    'vault_select_encryption_method': '暗号化方式を選択',
}

RU_FIX = {
    'crypt_action_browse': 'Просмотр', 'crypt_action_decrypt': 'Расшифровать', 'crypt_action_encrypt': 'Зашифровать сейчас',
    'crypt_action_share': 'Поделиться', 'crypt_add_mount': 'Добавить шифрованную папку',
    'crypt_advanced_toggle': 'Показать дополнительные параметры шифрования',
    'crypt_decrypt_failed': 'Не удалось расшифровать: {error}',
    'crypt_decrypt_message': 'Все файлы и подпапки будут расшифрованы и вернутся к обычному виду. Продолжить?',
    'crypt_decrypt_success': 'Расшифровка завершена', 'crypt_decrypt_title': 'Подтверждение расшифровки',
    'crypt_decrypting': 'Расшифровка...',
    'crypt_delete_message': 'Удалить конфигурацию шифрования для «{name}»? Файлы удалены не будут.',
    'crypt_delete_title': 'Удалить шифрованную папку', 'crypt_dirname_enc_no': 'Нет', 'crypt_dirname_enc_yes': 'Да',
    'crypt_edit_mount': 'Изменить шифрованную папку', 'crypt_encrypt_failed': 'Не удалось зашифровать: {error}',
    'crypt_encrypt_message': 'Все файлы и подпапки будут зашифрованы. Другие файловые менеджеры не смогут видеть их содержимое и имена. Продолжить?',
    'crypt_encrypt_success': 'Шифрование завершено', 'crypt_encrypt_title': 'Подтверждение шифрования',
    'crypt_encrypting': 'Шифрование...', 'crypt_error_password_mismatch': 'Пароли не совпадают',
    'crypt_error_password_required': 'Введите пароль',
    'crypt_error_password_short': 'Пароль должен содержать не менее 4 символов',
    'crypt_error_path_required': 'Выберите путь к папке', 'crypt_field_confirm_password': 'Подтвердите пароль',
    'crypt_field_dirname_enc': 'Шифровать имена папок', 'crypt_field_filename_enc': 'Шифрование имён файлов',
    'crypt_field_filename_encoding': 'Кодирование имён файлов', 'crypt_field_name': 'Название',
    'crypt_field_name_hint': 'Необязательно; если пусто, используется имя папки', 'crypt_field_password': 'Пароль',
    'crypt_field_path': 'Путь к папке', 'crypt_field_path_hint': 'Выберите папку для шифрования',
    'crypt_field_salt': 'Соль (необязательно)', 'crypt_field_salt_hint': 'Если пусто, создаётся автоматически',
    'crypt_field_suffix': 'Суффикс шифрования', 'crypt_filename_enc': 'Имена файлов',
    'crypt_filename_enc_off': 'Выкл.', 'crypt_filename_enc_obfuscate': 'Обфускация', 'crypt_filename_enc_standard': 'Стандарт',
    'crypt_mode_inplace': 'Шифрование на месте',
    'crypt_mode_inplace_desc': 'Файлы остаются на месте, шифруются имена и содержимое',
    'crypt_mode_sandbox': 'Шифрование в песочнице',
    'crypt_mode_sandbox_desc': 'Файлы перемещаются в песочницу; безопаснее, но чуть медленнее',
    'crypt_no_mounts_subtitle': 'Нажмите кнопку ниже, чтобы добавить первую шифрованную папку',
    'crypt_no_mounts_title': 'Нет шифрованных папок', 'crypt_section_advanced': 'Дополнительные параметры',
    'crypt_section_mode': 'Режим шифрования', 'crypt_set_master_password': 'Задать мастер-пароль шифрования',
    'crypt_settings_subtitle': 'Управление шифрованными папками и точками монтирования', 'crypt_settings_title': 'Шифрование',
    'crypt_share_hint': 'Отсканируйте QR-код, чтобы импортировать конфигурацию шифрования. Для расшифровки файлов нужен пароль.',
    'crypt_share_password_note': 'Пароль НЕ включён в QR-код. Передайте его отдельно по защищённому каналу.',
    'crypt_share_title': 'Поделиться шифрованной папкой', 'vault_decrypt_action': 'Расшифровать',
    'vault_decrypt_confirm_desc': 'Расшифровать «{name}»? После расшифровки файл вернётся к обычному виду.',
    'vault_decrypt_confirm_title': 'Расшифровать файл', 'vault_decrypt_failed': 'Не удалось расшифровать: {error}',
    'vault_decrypt_success': 'Расшифровка выполнена', 'vault_encrypt_failed': 'Не удалось зашифровать: {error}',
    'vault_encrypt_files': '+ Зашифровать файлы', 'vault_encrypting': 'Шифрование...',
    'vault_encrypting_desc': 'Шифрование выбранных файлов/папок, подождите...',
    'vault_export_backup_confirm': 'Резервная копия будет сохранена в следующее место:', 'vault_go_set_password': 'Задать пароль',
    'vault_import_only_zip': 'Поддерживаются только файлы резервных копий .zip',
    'vault_import_password_hint': 'Эта копия создана с другим паролем. Разблокируйте хранилище паролем, использованным при её создании',
    'vault_inplace_encrypt': 'Шифрование на месте',
    'vault_inplace_encrypt_desc': 'Файлы остаются в исходной папке, имена шифруются; в браузере показывается значок 🔐',
    'vault_inplace_encrypt_done': 'Шифрование на месте завершено, зашифровано файлов/папок: {count}',
    'vault_inplace_section': 'Шифрование на месте', 'vault_need_set_password': 'Сначала задайте мастер-пароль',
    'vault_need_set_password_desc': 'Сначала настройте мастер-пароль и соль в настройках шифрования, затем можно выполнять шифрование на месте.',
    'vault_open_backup_location': 'Открыть папку, куда сохранена копия?', 'vault_open_location': 'Открыть расположение',
    'vault_sandbox_encrypt': 'Шифрование в песочнице',
    'vault_sandbox_encrypt_desc': 'Файлы перемещаются в закрытую папку хранилища, имена скрыты; видны только на странице хранилища',
    'vault_select_encryption_method': 'Выберите способ шифрования',
}

FR_FIX = {
    'crypt_action_browse': 'Parcourir', 'crypt_action_decrypt': 'Déchiffrer', 'crypt_action_encrypt': 'Chiffrer maintenant',
    'crypt_action_share': 'Partager', 'crypt_add_mount': 'Ajouter un dossier chiffré',
    'crypt_advanced_toggle': 'Afficher les options de chiffrement avancées',
    'crypt_decrypt_failed': 'Échec du déchiffrement : {error}',
    'crypt_decrypt_message': 'Tous les fichiers et sous-dossiers seront déchiffrés et redeviendront normaux. Continuer ?',
    'crypt_decrypt_success': 'Déchiffrement terminé', 'crypt_decrypt_title': 'Confirmation du déchiffrement',
    'crypt_decrypting': 'Déchiffrement...',
    'crypt_delete_message': 'Supprimer la configuration de chiffrement de « {name} » ? Les fichiers ne seront pas supprimés.',
    'crypt_delete_title': 'Supprimer le dossier chiffré', 'crypt_dirname_enc_no': 'Non', 'crypt_dirname_enc_yes': 'Oui',
    'crypt_edit_mount': 'Modifier le dossier chiffré', 'crypt_encrypt_failed': 'Échec du chiffrement : {error}',
    'crypt_encrypt_message': "Tous les fichiers et sous-dossiers seront chiffrés. Les autres gestionnaires de fichiers ne pourront plus voir leur contenu ni leur nom. Continuer ?",
    'crypt_encrypt_success': 'Chiffrement terminé', 'crypt_encrypt_title': 'Confirmation du chiffrement',
    'crypt_encrypting': 'Chiffrement...', 'crypt_error_password_mismatch': 'Les mots de passe ne correspondent pas',
    'crypt_error_password_required': 'Veuillez saisir un mot de passe',
    'crypt_error_password_short': 'Le mot de passe doit contenir au moins 4 caractères',
    'crypt_error_path_required': 'Veuillez sélectionner un chemin de dossier',
    'crypt_field_confirm_password': 'Confirmer le mot de passe', 'crypt_field_dirname_enc': 'Chiffrer les noms de dossiers',
    'crypt_field_filename_enc': 'Chiffrement des noms de fichiers', 'crypt_field_filename_encoding': 'Encodage des noms de fichiers',
    'crypt_field_name': 'Nom', 'crypt_field_name_hint': 'Facultatif ; le nom du dossier sera utilisé si vide',
    'crypt_field_password': 'Mot de passe', 'crypt_field_path': 'Chemin du dossier',
    'crypt_field_path_hint': 'Sélectionner le dossier à chiffrer', 'crypt_field_salt': 'Sel (facultatif)',
    'crypt_field_salt_hint': 'Généré automatiquement si vide', 'crypt_field_suffix': 'Suffixe de chiffrement',
    'crypt_filename_enc': 'Noms de fichiers', 'crypt_filename_enc_off': 'Désactivé',
    'crypt_filename_enc_obfuscate': 'Obfuscation', 'crypt_filename_enc_standard': 'Standard',
    'crypt_mode_inplace': 'Chiffrement sur place',
    'crypt_mode_inplace_desc': 'Les fichiers restent en place, noms et contenus sont chiffrés',
    'crypt_mode_sandbox': 'Chiffrement en sandbox',
    'crypt_mode_sandbox_desc': 'Les fichiers sont déplacés dans le sandbox ; plus sûr mais un peu plus lent',
    'crypt_no_mounts_subtitle': "Appuyez sur le bouton ci-dessous pour ajouter votre premier dossier chiffré",
    'crypt_no_mounts_title': 'Aucun dossier chiffré', 'crypt_section_advanced': 'Options avancées',
    'crypt_section_mode': 'Mode de chiffrement', 'crypt_set_master_password': 'Définir le mot de passe maître de chiffrement',
    'crypt_settings_subtitle': 'Gérer les dossiers chiffrés et les points de montage', 'crypt_settings_title': 'Chiffrement',
    'crypt_share_hint': 'Scannez le QR code pour importer la configuration de chiffrement. Le mot de passe est requis pour déchiffrer les fichiers.',
    'crypt_share_password_note': "Le mot de passe n'est PAS inclus dans le QR code. Partagez-le séparément via un canal sécurisé.",
    'crypt_share_title': 'Partager le dossier chiffré', 'vault_decrypt_action': 'Déchiffrer',
    'vault_decrypt_confirm_desc': 'Déchiffrer « {name} » ? Le fichier redeviendra normal après le déchiffrement.',
    'vault_decrypt_confirm_title': 'Déchiffrer le fichier', 'vault_decrypt_failed': 'Échec du déchiffrement : {error}',
    'vault_decrypt_success': 'Déchiffrement réussi', 'vault_encrypt_failed': 'Échec du chiffrement : {error}',
    'vault_encrypt_files': '+ Chiffrer des fichiers', 'vault_encrypting': 'Chiffrement...',
    'vault_encrypting_desc': 'Chiffrement des fichiers/dossiers sélectionnés, veuillez patienter...',
    'vault_export_backup_confirm': 'La sauvegarde sera enregistrée à l\'emplacement suivant :',
    'vault_go_set_password': 'Définir le mot de passe',
    'vault_import_only_zip': 'Seuls les fichiers de sauvegarde .zip sont pris en charge',
    'vault_import_password_hint': 'Cette sauvegarde utilise un mot de passe différent. Déverrouillez à nouveau le coffre avec le mot de passe utilisé lors de sa création',
    'vault_inplace_encrypt': 'Chiffrement sur place',
    'vault_inplace_encrypt_desc': 'Les fichiers restent dans le dossier d\'origine, les noms sont chiffrés après chiffrement, badge 🔐 affiché dans le navigateur',
    'vault_inplace_encrypt_done': 'Chiffrement sur place terminé, {count} fichiers/dossiers chiffrés',
    'vault_inplace_section': 'Chiffrement sur place', 'vault_need_set_password': "Définir d'abord le mot de passe maître",
    'vault_need_set_password_desc': "Configurez d'abord le mot de passe maître et le sel dans les paramètres de chiffrement, puis vous pourrez effectuer un chiffrement sur place.",
    'vault_open_backup_location': 'Ouvrir le dossier où la sauvegarde est enregistrée ?', 'vault_open_location': "Ouvrir l'emplacement",
    'vault_sandbox_encrypt': 'Chiffrement en sandbox',
    'vault_sandbox_encrypt_desc': 'Les fichiers sont déplacés dans le dossier privé du coffre, les noms sont masqués, visibles uniquement sur la page du coffre',
    'vault_select_encryption_method': 'Sélectionner la méthode de chiffrement',
}

ES_FIX = {
    'crypt_action_browse': 'Explorar', 'crypt_action_decrypt': 'Descifrar', 'crypt_action_encrypt': 'Cifrar ahora',
    'crypt_action_share': 'Compartir', 'crypt_add_mount': 'Añadir carpeta cifrada',
    'crypt_advanced_toggle': 'Mostrar opciones de cifrado avanzadas', 'crypt_decrypt_failed': 'Error al descifrar: {error}',
    'crypt_decrypt_message': 'Se descifrarán todos los archivos y subcarpetas y volverán a su estado normal. ¿Continuar?',
    'crypt_decrypt_success': 'Descifrado completado', 'crypt_decrypt_title': 'Confirmar descifrado',
    'crypt_decrypting': 'Descifrando...', 'crypt_delete_message': '¿Eliminar la configuración de cifrado de «{name}»? Los archivos no se eliminarán.',
    'crypt_delete_title': 'Eliminar carpeta cifrada', 'crypt_dirname_enc_no': 'No', 'crypt_dirname_enc_yes': 'Sí',
    'crypt_edit_mount': 'Editar carpeta cifrada', 'crypt_encrypt_failed': 'Error al cifrar: {error}',
    'crypt_encrypt_message': 'Se cifrarán todos los archivos y subcarpetas. Otros exploradores no podrán ver su contenido ni sus nombres. ¿Continuar?',
    'crypt_encrypt_success': 'Cifrado completado', 'crypt_encrypt_title': 'Confirmar cifrado',
    'crypt_encrypting': 'Cifrando...', 'crypt_error_password_mismatch': 'Las contraseñas no coinciden',
    'crypt_error_password_required': 'Introduce una contraseña',
    'crypt_error_password_short': 'La contraseña debe tener al menos 4 caracteres',
    'crypt_error_path_required': 'Selecciona una ruta de carpeta', 'crypt_field_confirm_password': 'Confirmar contraseña',
    'crypt_field_dirname_enc': 'Cifrar nombres de carpetas', 'crypt_field_filename_enc': 'Cifrado de nombres de archivo',
    'crypt_field_filename_encoding': 'Codificación de nombres de archivo', 'crypt_field_name': 'Nombre',
    'crypt_field_name_hint': 'Opcional; se usa el nombre de la carpeta si se deja vacío', 'crypt_field_password': 'Contraseña',
    'crypt_field_path': 'Ruta de la carpeta', 'crypt_field_path_hint': 'Selecciona la carpeta a cifrar',
    'crypt_field_salt': 'Sal (opcional)', 'crypt_field_salt_hint': 'Se genera automáticamente si se deja vacío',
    'crypt_field_suffix': 'Sufijo cifrado', 'crypt_filename_enc': 'Nombres de archivo',
    'crypt_filename_enc_off': 'Desactivado', 'crypt_filename_enc_obfuscate': 'Ofuscar', 'crypt_filename_enc_standard': 'Estándar',
    'crypt_mode_inplace': 'Cifrado in situ',
    'crypt_mode_inplace_desc': 'Los archivos permanecen en su sitio; se cifran nombres y contenido',
    'crypt_mode_sandbox': 'Cifrado en sandbox',
    'crypt_mode_sandbox_desc': 'Los archivos se mueven al sandbox; más seguro pero algo más lento',
    'crypt_no_mounts_subtitle': 'Toca el botón de abajo para añadir tu primera carpeta cifrada',
    'crypt_no_mounts_title': 'Sin carpetas cifradas', 'crypt_section_advanced': 'Opciones avanzadas',
    'crypt_section_mode': 'Modo de cifrado', 'crypt_set_master_password': 'Establecer contraseña maestra de cifrado',
    'crypt_settings_subtitle': 'Gestionar carpetas cifradas y puntos de montaje', 'crypt_settings_title': 'Cifrado',
    'crypt_share_hint': 'Escanea el código QR para importar la configuración de cifrado. Se necesita la contraseña para descifrar archivos.',
    'crypt_share_password_note': 'La contraseña NO está incluida en el código QR. Compártela aparte por un canal seguro.',
    'crypt_share_title': 'Compartir carpeta cifrada', 'vault_decrypt_action': 'Descifrar',
    'vault_decrypt_confirm_desc': '¿Seguro que quieres descifrar «{name}»? El archivo volverá a la normalidad tras el descifrado.',
    'vault_decrypt_confirm_title': 'Descifrar archivo', 'vault_decrypt_failed': 'Error al descifrar: {error}',
    'vault_decrypt_success': 'Descifrado correcto', 'vault_encrypt_failed': 'Error al cifrar: {error}',
    'vault_encrypt_files': '+ Cifrar archivos', 'vault_encrypting': 'Cifrando...',
    'vault_encrypting_desc': 'Cifrando archivos/carpetas seleccionados, espera...',
    'vault_export_backup_confirm': 'La copia de seguridad se guardará en la siguiente ubicación:',
    'vault_go_set_password': 'Establecer contraseña', 'vault_import_only_zip': 'Solo se admiten copias de seguridad .zip',
    'vault_import_password_hint': 'Esta copia usa una contraseña distinta. Desbloquea la bóveda con la contraseña usada al crearla',
    'vault_inplace_encrypt': 'Cifrado in situ',
    'vault_inplace_encrypt_desc': 'Los archivos permanecen en la carpeta original, los nombres se cifran tras el cifrado, insignia 🔐 en el explorador',
    'vault_inplace_encrypt_done': 'Cifrado in situ completado, {count} archivos/carpetas cifrados',
    'vault_inplace_section': 'Cifrado in situ', 'vault_need_set_password': 'Primero establece la contraseña maestra',
    'vault_need_set_password_desc': 'Configura primero la contraseña maestra y la sal en los ajustes de cifrado; después podrás cifrar in situ.',
    'vault_open_backup_location': '¿Abrir la carpeta donde se guardó la copia?', 'vault_open_location': 'Abrir ubicación',
    'vault_sandbox_encrypt': 'Cifrado en sandbox',
    'vault_sandbox_encrypt_desc': 'Los archivos se mueven al directorio privado de la bóveda, nombres ocultos, visibles solo en la página de la bóveda',
    'vault_select_encryption_method': 'Seleccionar método de cifrado',
}

DE_FIX = {
    'crypt_action_browse': 'Durchsehen', 'crypt_action_decrypt': 'Entschlüsseln', 'crypt_action_encrypt': 'Jetzt verschlüsseln',
    'crypt_action_share': 'Teilen', 'crypt_add_mount': 'Verschlüsselten Ordner hinzufügen',
    'crypt_advanced_toggle': 'Erweiterte Verschlüsselungsoptionen anzeigen',
    'crypt_decrypt_failed': 'Entschlüsselung fehlgeschlagen: {error}',
    'crypt_decrypt_message': 'Alle Dateien und Unterordner werden entschlüsselt und danach wieder normal angezeigt. Fortfahren?',
    'crypt_decrypt_success': 'Entschlüsselung abgeschlossen', 'crypt_decrypt_title': 'Entschlüsselung bestätigen',
    'crypt_decrypting': 'Wird entschlüsselt...',
    'crypt_delete_message': 'Verschlüsselungskonfiguration für „{name}" löschen? Dateien werden nicht gelöscht.',
    'crypt_delete_title': 'Verschlüsselten Ordner löschen', 'crypt_dirname_enc_no': 'Nein', 'crypt_dirname_enc_yes': 'Ja',
    'crypt_edit_mount': 'Verschlüsselten Ordner bearbeiten', 'crypt_encrypt_failed': 'Verschlüsselung fehlgeschlagen: {error}',
    'crypt_encrypt_message': 'Alle Dateien und Unterordner werden verschlüsselt. Andere Dateimanager können Inhalte und Namen danach nicht sehen. Fortfahren?',
    'crypt_encrypt_success': 'Verschlüsselung abgeschlossen', 'crypt_encrypt_title': 'Verschlüsselung bestätigen',
    'crypt_encrypting': 'Wird verschlüsselt...', 'crypt_error_password_mismatch': 'Passwörter stimmen nicht überein',
    'crypt_error_password_required': 'Bitte Passwort eingeben',
    'crypt_error_password_short': 'Das Passwort muss mindestens 4 Zeichen lang sein',
    'crypt_error_path_required': 'Bitte Ordnerpfad auswählen', 'crypt_field_confirm_password': 'Passwort bestätigen',
    'crypt_field_dirname_enc': 'Ordnernamen verschlüsseln', 'crypt_field_filename_enc': 'Dateinamen-Verschlüsselung',
    'crypt_field_filename_encoding': 'Dateinamen-Kodierung', 'crypt_field_name': 'Name',
    'crypt_field_name_hint': 'Optional; bei leer wird der Ordnername verwendet', 'crypt_field_password': 'Passwort',
    'crypt_field_path': 'Ordnerpfad', 'crypt_field_path_hint': 'Zu verschlüsselnden Ordner auswählen',
    'crypt_field_salt': 'Salt (optional)', 'crypt_field_salt_hint': 'Bei leer automatisch erzeugt',
    'crypt_field_suffix': 'Verschlüsselungs-Suffix', 'crypt_filename_enc': 'Dateinamen',
    'crypt_filename_enc_off': 'Aus', 'crypt_filename_enc_obfuscate': 'Verschleiert', 'crypt_filename_enc_standard': 'Standard',
    'crypt_mode_inplace': 'Vor-Ort-Verschlüsselung',
    'crypt_mode_inplace_desc': 'Dateien bleiben an ihrem Platz; Namen und Inhalt werden verschlüsselt',
    'crypt_mode_sandbox': 'Sandbox-Verschlüsselung',
    'crypt_mode_sandbox_desc': 'Dateien werden in die Sandbox verschoben; sicherer, aber etwas langsamer',
    'crypt_no_mounts_subtitle': 'Tippe auf die Schaltfläche unten, um deinen ersten verschlüsselten Ordner hinzuzufügen',
    'crypt_no_mounts_title': 'Keine verschlüsselten Ordner', 'crypt_section_advanced': 'Erweiterte Optionen',
    'crypt_section_mode': 'Verschlüsselungsmodus', 'crypt_set_master_password': 'Verschlüsselungs-Masterpasswort festlegen',
    'crypt_settings_subtitle': 'Verschlüsselte Ordner und Mount-Punkte verwalten', 'crypt_settings_title': 'Verschlüsselung',
    'crypt_share_hint': 'Scanne den QR-Code, um die Verschlüsselungskonfiguration zu importieren. Zum Entschlüsseln wird das Passwort benötigt.',
    'crypt_share_password_note': 'Das Passwort ist NICHT im QR-Code enthalten. Teile es separat über einen sicheren Kanal.',
    'crypt_share_title': 'Verschlüsselten Ordner teilen', 'vault_decrypt_action': 'Entschlüsseln',
    'vault_decrypt_confirm_desc': '„{name}" wirklich entschlüsseln? Die Datei ist danach wieder normal.',
    'vault_decrypt_confirm_title': 'Datei entschlüsseln', 'vault_decrypt_failed': 'Entschlüsselung fehlgeschlagen: {error}',
    'vault_decrypt_success': 'Erfolgreich entschlüsselt', 'vault_encrypt_failed': 'Verschlüsselung fehlgeschlagen: {error}',
    'vault_encrypt_files': '+ Dateien verschlüsseln', 'vault_encrypting': 'Wird verschlüsselt...',
    'vault_encrypting_desc': 'Ausgewählte Dateien/Ordner werden verschlüsselt, bitte warten...',
    'vault_export_backup_confirm': 'Die Sicherungsdatei wird am folgenden Ort gespeichert:',
    'vault_go_set_password': 'Passwort festlegen', 'vault_import_only_zip': 'Nur .zip-Sicherungsdateien werden unterstützt',
    'vault_import_password_hint': 'Diese Sicherung verwendet ein anderes Passwort. Entsperre den Tresor mit dem Passwort, das beim Erstellen der Sicherung verwendet wurde',
    'vault_inplace_encrypt': 'Vor-Ort-Verschlüsselung',
    'vault_inplace_encrypt_desc': 'Dateien bleiben im ursprünglichen Ordner, Namen werden verschlüsselt, 🔐-Abzeichen im Browser',
    'vault_inplace_encrypt_done': 'Vor-Ort-Verschlüsselung abgeschlossen, {count} Dateien/Ordner verschlüsselt',
    'vault_inplace_section': 'Vor-Ort-Verschlüsselung', 'vault_need_set_password': 'Zuerst Masterpasswort festlegen',
    'vault_need_set_password_desc': 'Bitte zuerst in den Verschlüsselungseinstellungen Masterpasswort und Salz festlegen, dann kann die Vor-Ort-Verschlüsselung genutzt werden.',
    'vault_open_backup_location': 'Ordner öffnen, in dem die Sicherung gespeichert ist?', 'vault_open_location': 'Ort öffnen',
    'vault_sandbox_encrypt': 'Sandbox-Verschlüsselung',
    'vault_sandbox_encrypt_desc': 'Dateien werden in den privaten Tresor-Ordner verschoben, Namen versteckt, nur auf der Tresor-Seite sichtbar',
    'vault_select_encryption_method': 'Verschlüsselungsmethode wählen',
}

AR_FIX = {
    'crypt_action_browse': 'تصفح', 'crypt_action_decrypt': 'فك التشفير', 'crypt_action_encrypt': 'تشفير الآن',
    'crypt_action_share': 'مشاركة', 'crypt_add_mount': 'إضافة مجلد مشفر',
    'crypt_advanced_toggle': 'إظهار خيارات التشفير المتقدمة', 'crypt_decrypt_failed': 'فشل فك التشفير: {error}',
    'crypt_decrypt_message': 'سيتم فك تشفير جميع الملفات والمجلدات الفرعية وستعود إلى حالتها الطبيعية. المتابعة؟',
    'crypt_decrypt_success': 'اكتمل فك التشفير', 'crypt_decrypt_title': 'تأكيد فك التشفير', 'crypt_decrypting': 'جارٍ فك التشفير...',
    'crypt_delete_message': 'حذف إعدادات التشفير لـ«{name}»؟ لن يتم حذف الملفات.', 'crypt_delete_title': 'حذف المجلد المشفر',
    'crypt_dirname_enc_no': 'لا', 'crypt_dirname_enc_yes': 'نعم', 'crypt_edit_mount': 'تعديل المجلد المشفر',
    'crypt_encrypt_failed': 'فشل التشفير: {error}',
    'crypt_encrypt_message': 'سيتم تشفير جميع الملفات والمجلدات الفرعية. لن تتمكن أدوات إدارة الملفات الأخرى من رؤية المحتوى أو الأسماء. المتابعة؟',
    'crypt_encrypt_success': 'اكتمل التشفير', 'crypt_encrypt_title': 'تأكيد التشفير', 'crypt_encrypting': 'جارٍ التشفير...',
    'crypt_error_password_mismatch': 'كلمتا المرور غير متطابقتين', 'crypt_error_password_required': 'يرجى إدخال كلمة المرور',
    'crypt_error_password_short': 'يجب ألا تقل كلمة المرور عن 4 أحرف', 'crypt_error_path_required': 'يرجى اختيار مسار المجلد',
    'crypt_field_confirm_password': 'تأكيد كلمة المرور', 'crypt_field_dirname_enc': 'تشفير أسماء المجلدات',
    'crypt_field_filename_enc': 'تشفير أسماء الملفات', 'crypt_field_filename_encoding': 'ترميز أسماء الملفات',
    'crypt_field_name': 'الاسم', 'crypt_field_name_hint': 'اختياري؛ يُستخدم اسم المجلد إذا تُرك فارغاً',
    'crypt_field_password': 'كلمة المرور', 'crypt_field_path': 'مسار المجلد', 'crypt_field_path_hint': 'اختر المجلد لتشفيره',
    'crypt_field_salt': 'الملح (اختياري)', 'crypt_field_salt_hint': 'يُنشأ تلقائياً إذا تُرك فارغاً',
    'crypt_field_suffix': 'لاحقة التشفير', 'crypt_filename_enc': 'أسماء الملفات', 'crypt_filename_enc_off': 'إيقاف',
    'crypt_filename_enc_obfuscate': 'تشويش', 'crypt_filename_enc_standard': 'قياسي',
    'crypt_mode_inplace': 'التشفير في المكان',
    'crypt_mode_inplace_desc': 'تبقى الملفات في مكانها؛ تُشفَّر الأسماء والمحتويات',
    'crypt_mode_sandbox': 'تشفير صندوق الحماية',
    'crypt_mode_sandbox_desc': 'تُنقل الملفات إلى صندوق الحماية؛ أكثر أماناً لكن أبطأ قليلاً',
    'crypt_no_mounts_subtitle': 'اضغط الزر أدناه لإضافة أول مجلد مشفر', 'crypt_no_mounts_title': 'لا توجد مجلدات مشفرة',
    'crypt_section_advanced': 'خيارات متقدمة', 'crypt_section_mode': 'وضع التشفير',
    'crypt_set_master_password': 'تعيين كلمة المرور الرئيسية للتشفير',
    'crypt_settings_subtitle': 'إدارة المجلدات المشفرة ونقاط التثبيت', 'crypt_settings_title': 'التشفير',
    'crypt_share_hint': 'امسح رمز QR لاستيراد إعدادات التشفير. كلمة المرور مطلوبة لفك تشفير الملفات.',
    'crypt_share_password_note': 'كلمة المرور غير مضمَّنة في رمز QR. شاركها بشكل منفصل عبر قناة آمنة.',
    'crypt_share_title': 'مشاركة المجلد المشفر', 'vault_decrypt_action': 'فك التشفير',
    'vault_decrypt_confirm_desc': 'هل تريد فك تشفير «{name}»؟ سيعود الملف إلى حالته الطبيعية بعد فك التشفير.',
    'vault_decrypt_confirm_title': 'فك تشفير الملف', 'vault_decrypt_failed': 'فشل فك التشفير: {error}',
    'vault_decrypt_success': 'تم فك التشفير بنجاح', 'vault_encrypt_failed': 'فشل التشفير: {error}',
    'vault_encrypt_files': '+ تشفير الملفات', 'vault_encrypting': 'جارٍ التشفير...',
    'vault_encrypting_desc': 'جارٍ تشفير الملفات/المجلدات المحددة، يرجى الانتظار...',
    'vault_export_backup_confirm': 'سيتم حفظ ملف النسخة الاحتياطية في الموقع التالي:', 'vault_go_set_password': 'تعيين كلمة المرور',
    'vault_import_only_zip': 'تدعم ملفات النسخ الاحتياطي .zip فقط',
    'vault_import_password_hint': 'تستخدم هذه النسخة كلمة مرور مختلفة. أعد فتح قفل الخزنة بكلمة المرور المستخدمة عند إنشائها',
    'vault_inplace_encrypt': 'التشفير في المكان',
    'vault_inplace_encrypt_desc': 'تبقى الملفات في المجلد الأصلي، وتُشفَّر أسماؤها بعد التشفير، مع شعار 🔐 في المتصفح',
    'vault_inplace_encrypt_done': 'اكتمل التشفير في المكان، تم تشفير {count} ملف/مجلد',
    'vault_inplace_section': 'التشفير في المكان', 'vault_need_set_password': 'يجب تعيين كلمة المرور الرئيسية أولاً',
    'vault_need_set_password_desc': 'يرجى أولاً إعداد كلمة المرور الرئيسية والملح في إعدادات التشفير، ثم يمكنك التشفير في المكان.',
    'vault_open_backup_location': 'فتح المجلد الذي حُفظت فيه النسخة الاحتياطية؟', 'vault_open_location': 'فتح الموقع',
    'vault_sandbox_encrypt': 'تشفير صندوق الحماية',
    'vault_sandbox_encrypt_desc': 'تُنقل الملفات إلى مجلد الخزنة الخاص، وتُخفى الأسماء، وتظهر فقط في صفحة الخزنة',
    'vault_select_encryption_method': 'اختر طريقة التشفير',
}

FIX_TABLES = {'ko': KO_FIX, 'ja': JA_FIX, 'ru': RU_FIX, 'fr': FR_FIX, 'es': ES_FIX, 'de': DE_FIX, 'ar': AR_FIX}

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


# ─────────── A1) 插入新 key 到 ARB ───────────
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
    print('ARB  %-8s +%d keys' % (lang, len(NEW_KEYS)))


# ─────────── A2) 插入新 key 到基类 ───────────
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
        param = PLACEHOLDER_PARAMS.get(key)
        lines.append('')
        lines.append('  /// No description provided for @%s.' % key)
        if param:
            lines.append('  String %s(Object %s);' % (key, param))
        else:
            lines.append('  String get %s;' % key)
    block = nl.join(lines)
    text = text[:end] + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    print('BASE +%d keys' % len(NEW_KEYS))


# ─────────── A3) 插入新 key 到 locale dart ───────────
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
    tables = [LANGS[lang]] if len(occurrences) == 1 else [ZH_NEW, ZH_TW_NEW]
    if len(occurrences) > 2:
        raise SystemExit('unexpected %d occurrences in %s' % (len(occurrences), path))
    for i in range(len(occurrences) - 1, -1, -1):
        start = occurrences[i]
        end = text.find("';", start) + len("';")
        table = tables[i]
        lines = []
        for key in NEW_KEYS:
            param = PLACEHOLDER_PARAMS.get(key)
            lines.append('')
            lines.append('  @override')
            if param:
                lines.append('  String %s(Object %s) {' % (key, param))
                lines.append("    return '%s';" % esc(table[key]))
                lines.append('  }')
            else:
                lines.append("  String get %s => '%s';" % (key, esc(table[key])))
        block = nl.join(lines)
        text = text[:end] + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    print('DART %-8s +%d keys (x%d)' % (lang, len(NEW_KEYS), len(occurrences)))


# ─────────── B1) 替换 82 个英文占位 key：ARB ───────────
def fix_arb(lang, table):
    path = os.path.join(ARB_DIR, 'app_%s.arb' % lang)
    data = read_bytes(path)
    text = data.decode('utf-8')
    count = 0
    for key, val in table.items():
        if key in TECH_KEYS:
            continue
        pat = re.compile(r'("%s": )"(?:[^"\\]|\\.)*"' % re.escape(key))
        new_val = val.replace('\\', '\\\\').replace('"', '\\"')
        text, n = pat.subn(lambda m: m.group(1) + '"%s"' % new_val, text, count=1)
        count += n
    write_bytes(path, text.encode('utf-8'))
    print('ARB-FIX %-6s %d keys' % (lang, count))


# ─────────── B2) 替换 82 个英文占位 key：locale dart ───────────
def fix_dart(lang, table):
    path = os.path.join(GEN_DIR, 'app_localizations_%s.dart' % lang)
    data = read_bytes(path)
    text = data.decode('utf-8')
    count = 0
    for key, val in table.items():
        if key in TECH_KEYS:
            continue
        esc_val = esc(val)
        # getter 形式：String get key => '...';
        pat_get = re.compile(r"(String get %s => ').*?(';)" % re.escape(key))
        text, n = pat_get.subn(lambda m: m.group(1) + esc_val + m.group(2), text, count=1)
        # 方法形式：String key(Object x) {\n    return '...';
        if n == 0:
            pat_m = re.compile(r"(String %s\(Object \w+\) \{\s*return ').*?(';)" % re.escape(key))
            text, n = pat_m.subn(lambda m: m.group(1) + esc_val + m.group(2), text, count=1)
        if n == 0:
            print('  !! not found: %s in %s' % (key, lang))
        count += n
    write_bytes(path, text.encode('utf-8'))
    print('DART-FIX %-6s %d keys' % (lang, count))


def main():
    for lang in sorted(LANGS.keys()):
        insert_arb(lang, LANGS[lang])
    insert_base()
    for lang in DART_LOCALES:
        insert_locale(lang)
    for lang, table in FIX_TABLES.items():
        fix_arb(lang, table)
        fix_dart(lang, table)
    print('done')


if __name__ == '__main__':
    sys.exit(main())
