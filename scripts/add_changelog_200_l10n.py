#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""插入「v2.0.0 更新日志」所需的 l10n key。

铁律（与 add_vault_help_l10n.py 一致）：
- lib/l10n/app_*.arb 用 CRLF，lib/l10n/generated/*.dart 用 LF → 全程二进制读写。
- 按锚点（crypt_settings_title）插入，不重跑 gen-l10n
  （会覆盖手工合并的 L10nZh / L10nZhTw）。
- zh.dart 里锚点出现两次（L10nZh、L10nZhTw）：第一次用 zh，第二次用 zh_TW。
- 全部为**无占位符**的纯字符串 getter（dart 侧 `String get xxx => '...';`）。
- 文案风格：避免在 FR/EN 里使用会与 dart 单引号冲突的字符（esc 已处理，但保持整洁）。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

KEYS = [
    'cl200_notice',
    'cl200_notice_1', 'cl200_notice_2', 'cl200_notice_3',
    'cl200_notice_4', 'cl200_notice_5',
    'cl200_vault',
    'cl200_vault_1', 'cl200_vault_2', 'cl200_vault_3', 'cl200_vault_4',
    'cl200_settings',
    'cl200_settings_1',
    'cl200_fixes',
    'cl200_fix_1', 'cl200_fix_2', 'cl200_fix_3', 'cl200_fix_4',
]

ZH = {
    'cl200_notice': '版本与包名变更（务必阅读）',
    'cl200_notice_1': '版本号升级至 2.0.0，包名（应用 ID）由 com.sequl.zenfile 变更为 com.sequl.zenfile2。2.0 会作为独立应用安装，不会覆盖旧的 1.x 版本。',
    'cl200_notice_2': '变更原因：保险箱的加密架构在本版本大改，已不再兼容旧版保险箱数据。改用新包名可让新旧两版并存，避免覆盖安装导致旧版保险箱数据丢失。',
    'cl200_notice_3': '请先自行备份：在旧版中打开「保险箱 → 备份/恢复 → 导出备份」，再在新版中打开「保险箱 → 备份/恢复 → 导入备份」。',
    'cl200_notice_4': '确认新版数据完整无误后再卸载旧版。沙盒加密文件存放在应用私有目录，卸载应用会一并清除，切勿先卸载。',
    'cl200_notice_5': '包名变更后，Shizuku 等按包名授予的权限需要在新版中重新授权一次。',
    'cl200_vault': '保险箱',
    'cl200_vault_1': '多密码档案：可为不同目录绑定不同的密码档案，加解密全部在本机完成，主密码与加盐只保存在本机。',
    'cl200_vault_2': '远程加密目录：可直接关联网盘上的 rclone crypt 加密目录，客户端解密后以明文列出，音视频支持流式播放，无需整体下载。',
    'cl200_vault_3': '原地加密：把文件「就地」加密，位置与目录结构保持不变，浏览页会加上🔐徽标，其它应用只能看到密文文件名。',
    'cl200_vault_4': '帮助页：保险箱首页右上角的「已激活」已换成「帮助」入口，里面有功能亮点、基本操作与兼容性说明。',
    'cl200_settings': '设置调整',
    'cl200_settings_1': '原保险箱首页的「安全设置」已迁移到「设置」页面，入口更统一。',
    'cl200_fixes': '修复与优化',
    'cl200_fix_1': '修复浏览页远程加密目录的文件图标全部显示为未知格式的问题。',
    'cl200_fix_2': '修复远程加密音视频无法流式播放、图片无法渲染的问题（部分网盘不返回文件大小，会导致解密大小为 0）。',
    'cl200_fix_3': '修复远程加密目录缩略图无法加载的问题。',
    'cl200_fix_4': '优化流式传输性能：去掉每块的冗余网络请求，远程加密媒体的播放与拖动体验大幅提升。',
}

ZH_TW = {
    'cl200_notice': '版本與套件名稱變更（請務必閱讀）',
    'cl200_notice_1': '版本號升級至 2.0.0，套件名稱（應用程式 ID）由 com.sequl.zenfile 變更為 com.sequl.zenfile2。2.0 會以獨立應用程式安裝，不會覆蓋舊的 1.x 版本。',
    'cl200_notice_2': '變更原因：保險箱的加密架構在本版本大幅調整，已不再相容舊版保險箱資料。改用新套件名稱可讓新舊兩版並存，避免覆蓋安裝造成舊版保險箱資料遺失。',
    'cl200_notice_3': '請先自行備份：在舊版開啟「保險箱 → 備份/還原 → 匯出備份」，再到新版開啟「保險箱 → 備份/還原 → 匯入備份」。',
    'cl200_notice_4': '確認新版資料完整無誤後再移除舊版。沙盒加密檔案存放於應用程式私有目錄，移除應用程式時會一併清除，切勿先移除。',
    'cl200_notice_5': '套件名稱變更後，Shizuku 等依套件名稱授予的權限需要在新版重新授權一次。',
    'cl200_vault': '保險箱',
    'cl200_vault_1': '多組密碼設定：可為不同目錄綁定不同的密碼設定，加解密全部在本機完成，主密碼與加鹽只儲存在本機。',
    'cl200_vault_2': '遠端加密目錄：可直接關聯雲端上的 rclone crypt 加密目錄，由用戶端解密後以明文列出，影音支援串流播放，無須整包下載。',
    'cl200_vault_3': '原地加密：把檔案「就地」加密，位置與目錄結構維持不變，瀏覽頁會加上🔐徽標，其他應用程式只會看到密文檔名。',
    'cl200_vault_4': '說明頁：保險箱首頁右上角的「已啟用」已改成「說明」入口，內含功能亮點、基本操作與相容性說明。',
    'cl200_settings': '設定調整',
    'cl200_settings_1': '原保險箱首頁的「安全性設定」已移至「設定」頁面，入口更統一。',
    'cl200_fixes': '修復與最佳化',
    'cl200_fix_1': '修復瀏覽頁遠端加密目錄的檔案圖示全部顯示為未知格式的問題。',
    'cl200_fix_2': '修復遠端加密影音無法串流播放、圖片無法顯示的問題（部分雲端不回傳檔案大小，會導致解密大小為 0）。',
    'cl200_fix_3': '修復遠端加密目錄縮圖無法載入的問題。',
    'cl200_fix_4': '最佳化串流效能：移除每個分塊多餘的網路請求，遠端加密媒體的播放與拖曳體驗大幅提升。',
}

EN = {
    'cl200_notice': 'Version and package name change (please read)',
    'cl200_notice_1': 'This release is 2.0.0 and the package name (application ID) changes from com.sequl.zenfile to com.sequl.zenfile2. Version 2.0 installs as a separate app and will not overwrite 1.x.',
    'cl200_notice_2': 'Why: the vault encryption architecture has been reworked and is no longer compatible with vault data from older versions. A new package name lets both versions coexist, so an overwriting install cannot destroy your old vault data.',
    'cl200_notice_3': 'Back up first: in the old version open Vault, then Backup / Restore, then Export backup; then in the new version open Vault, then Backup / Restore, then Import backup.',
    'cl200_notice_4': 'Uninstall the old version only after you have confirmed the new one is complete. Sandbox-encrypted files live in the private app directory and are erased when the app is uninstalled, so never uninstall first.',
    'cl200_notice_5': 'Because the package name changed, permissions granted per package such as Shizuku must be granted again in the new version.',
    'cl200_vault': 'Vault',
    'cl200_vault_1': 'Multiple password profiles: bind a different password profile to each folder. Encryption and decryption happen entirely on this device, and the master password and salt never leave it.',
    'cl200_vault_2': 'Remote encrypted folders: link an rclone crypt folder on your cloud drive and browse it with plain names, with streaming playback for audio and video and no need to download the whole file.',
    'cl200_vault_3': 'In-place encryption: files are encrypted where they are, so the location and folder structure stay unchanged. The browser adds a lock badge and other apps only see ciphertext names.',
    'cl200_vault_4': 'Help page: the "Activated" badge in the top-right corner of the vault is replaced by a "Help" button that explains the highlights, basic operations and compatibility.',
    'cl200_settings': 'Settings changes',
    'cl200_settings_1': 'Security settings has moved from the vault home page to the Settings page, so every entry is now in one place.',
    'cl200_fixes': 'Fixes and improvements',
    'cl200_fix_1': 'Fixed all files in a remote encrypted folder showing the unknown-format icon in the browser.',
    'cl200_fix_2': 'Fixed remote encrypted audio and video failing to stream and images failing to render, which happened when a cloud drive does not report the file size and the decrypted size became 0.',
    'cl200_fix_3': 'Fixed thumbnails never loading in remote encrypted folders.',
    'cl200_fix_4': 'Improved streaming performance by removing a redundant network request per chunk, making playback and seeking of remote encrypted media much smoother.',
}

JA = {
    'cl200_notice': 'バージョンとパッケージ名の変更（必ずお読みください）',
    'cl200_notice_1': 'バージョンが 2.0.0 になり、パッケージ名（アプリケーション ID）が com.sequl.zenfile から com.sequl.zenfile2 に変わります。2.0 は独立したアプリとしてインストールされ、1.x を上書きしません。',
    'cl200_notice_2': '変更の理由：金庫の暗号化アーキテクチャを大幅に刷新したため、旧版の金庫データとは互換性がありません。パッケージ名を変えることで両バージョンを共存させ、上書きインストールによる旧データの消失を防ぎます。',
    'cl200_notice_3': '必ずご自身でバックアップしてください：旧版で「金庫 → バックアップ/復元 → 書き出し」を実行し、新版で「金庫 → バックアップ/復元 → 読み込み」を実行してください。',
    'cl200_notice_4': '新版でデータがそろっていることを確認してから旧版をアンインストールしてください。サンドボックス暗号化のファイルはアプリ専用ディレクトリにあり、アンインストールすると消去されます。先にアンインストールしないでください。',
    'cl200_notice_5': 'パッケージ名が変わったため、Shizuku などパッケージ単位で付与される権限は新版で再許可が必要です。',
    'cl200_vault': '金庫',
    'cl200_vault_1': '複数のパスワード設定：フォルダごとに異なるパスワード設定を割り当てできます。暗号化と復号はすべて端末内で行われ、マスターパスワードとソルトは端末外に出ません。',
    'cl200_vault_2': 'リモート暗号化フォルダ：クラウド上の rclone crypt フォルダを直接関連付け、端末で復号して平文の名前で一覧表示します。音声と動画はストリーミング再生に対応し、全体をダウンロードする必要はありません。',
    'cl200_vault_3': 'その場で暗号化：ファイルを元の場所で暗号化するため、位置とフォルダ構成は変わりません。ブラウザでは🔐マークが付き、他のアプリには暗号文の名前しか見えません。',
    'cl200_vault_4': 'ヘルプ：金庫ホーム右上の「有効」バッジを「ヘルプ」ボタンに変更しました。主な特長、基本操作、互換性を説明しています。',
    'cl200_settings': '設定の変更',
    'cl200_settings_1': '金庫ホームにあった「セキュリティ設定」は「設定」ページに移動しました。',
    'cl200_fixes': '修正と改善',
    'cl200_fix_1': 'ブラウザのリモート暗号化フォルダで、すべてのファイルアイコンが不明な形式として表示される問題を修正しました。',
    'cl200_fix_2': 'リモート暗号化の音声・動画をストリーミング再生できない、画像が表示されない問題を修正しました（クラウドがファイルサイズを返さないと復号サイズが 0 になるのが原因でした）。',
    'cl200_fix_3': 'リモート暗号化フォルダでサムネイルが読み込まれない問題を修正しました。',
    'cl200_fix_4': 'チャンクごとの不要なネットワーク要求をなくし、ストリーミング性能を改善しました。リモート暗号化メディアの再生とシークが大幅に快適になります。',
}

KO = {
    'cl200_notice': '버전 및 패키지 이름 변경 (반드시 읽어주세요)',
    'cl200_notice_1': '버전이 2.0.0으로 올라가고 패키지 이름(애플리케이션 ID)이 com.sequl.zenfile에서 com.sequl.zenfile2로 바뀝니다. 2.0은 별도 앱으로 설치되며 1.x를 덮어쓰지 않습니다.',
    'cl200_notice_2': '변경 이유: 금고의 암호화 구조가 크게 개편되어 이전 버전의 금고 데이터와 호환되지 않습니다. 패키지 이름을 바꾸면 두 버전을 함께 둘 수 있어, 덮어쓰기 설치로 인한 기존 금고 데이터 손실을 막을 수 있습니다.',
    'cl200_notice_3': '먼저 직접 백업하세요: 이전 버전에서 「금고 → 백업/복원 → 백업 내보내기」를 실행한 뒤, 새 버전에서 「금고 → 백업/복원 → 백업 가져오기」를 실행하세요.',
    'cl200_notice_4': '새 버전에서 데이터가 모두 확인된 뒤에야 이전 버전을 삭제하세요. 샌드박스 암호화 파일은 앱 전용 디렉터리에 있어 앱을 삭제하면 함께 지워지므로, 먼저 삭제하지 마세요.',
    'cl200_notice_5': '패키지 이름이 바뀌었으므로 Shizuku처럼 패키지 단위로 부여되는 권한은 새 버전에서 다시 허용해야 합니다.',
    'cl200_vault': '금고',
    'cl200_vault_1': '여러 비밀번호 프로필: 폴더마다 다른 비밀번호 프로필을 지정할 수 있습니다. 암호화와 복호화는 모두 기기에서 이루어지며 마스터 비밀번호와 솔트는 기기 밖으로 나가지 않습니다.',
    'cl200_vault_2': '원격 암호 폴더: 클라우드의 rclone crypt 폴더를 바로 연결해 클라이언트에서 복호화하여 일반 이름으로 표시합니다. 오디오와 비디오는 스트리밍 재생을 지원하므로 전체를 내려받을 필요가 없습니다.',
    'cl200_vault_3': '원위치 암호화: 파일을 있던 자리에서 암호화하므로 위치와 폴더 구조가 그대로 유지됩니다. 브라우저에는 🔐 배지가 표시되고 다른 앱에는 암호문 이름만 보입니다.',
    'cl200_vault_4': '도움말: 금고 홈 오른쪽 위의 「활성화됨」 배지가 「도움말」 버튼으로 바뀌었습니다. 주요 기능, 기본 조작, 호환성을 설명합니다.',
    'cl200_settings': '설정 변경',
    'cl200_settings_1': '금고 홈에 있던 「보안 설정」이 「설정」 페이지로 이동했습니다.',
    'cl200_fixes': '수정 및 개선',
    'cl200_fix_1': '브라우저의 원격 암호 폴더에서 모든 파일 아이콘이 알 수 없는 형식으로 표시되던 문제를 수정했습니다.',
    'cl200_fix_2': '원격 암호 오디오·비디오를 스트리밍 재생할 수 없고 이미지가 표시되지 않던 문제를 수정했습니다(클라우드가 파일 크기를 반환하지 않아 복호화 크기가 0이 되는 경우였습니다).',
    'cl200_fix_3': '원격 암호 폴더에서 썸네일이 불러와지지 않던 문제를 수정했습니다.',
    'cl200_fix_4': '청크마다 불필요한 네트워크 요청을 없애 스트리밍 성능을 개선했습니다. 원격 암호 미디어의 재생과 탐색이 훨씬 부드러워집니다.',
}

DE = {
    'cl200_notice': 'Änderung von Version und Paketnamen (bitte lesen)',
    'cl200_notice_1': 'Die Version steigt auf 2.0.0 und der Paketname (Anwendungs-ID) wechselt von com.sequl.zenfile zu com.sequl.zenfile2. Version 2.0 wird als eigenständige App installiert und überschreibt 1.x nicht.',
    'cl200_notice_2': 'Grund: Die Verschlüsselungsarchitektur des Tresors wurde überarbeitet und ist nicht mehr kompatibel mit Tresordaten aus älteren Versionen. Der neue Paketname lässt beide Versionen nebeneinander bestehen, damit eine überschreibende Installation keine alten Daten vernichtet.',
    'cl200_notice_3': 'Sichere zuerst selbst: Öffne in der alten Version „Tresor → Sichern/Wiederherstellen → Backup exportieren" und danach in der neuen Version „Tresor → Sichern/Wiederherstellen → Backup importieren".',
    'cl200_notice_4': 'Deinstalliere die alte Version erst, wenn du dich vergewissert hast, dass in der neuen alles vollständig ist. In der Sandbox verschlüsselte Dateien liegen im privaten App-Verzeichnis und werden beim Deinstallieren gelöscht, also niemals zuerst deinstallieren.',
    'cl200_notice_5': 'Wegen des neuen Paketnamens müssen pro Paket erteilte Berechtigungen wie Shizuku in der neuen Version erneut erteilt werden.',
    'cl200_vault': 'Tresor',
    'cl200_vault_1': 'Mehrere Passwortprofile: Für jeden Ordner kann ein eigenes Passwortprofil gebunden werden. Ver- und Entschlüsselung laufen ausschließlich auf dem Gerät, Hauptpasswort und Salt bleiben dort.',
    'cl200_vault_2': 'Entfernte verschlüsselte Ordner: Verknüpfe einen rclone-crypt-Ordner in der Cloud direkt; er wird auf dem Gerät entschlüsselt und mit Klarnamen gelistet. Audio und Video werden gestreamt, ein kompletter Download ist nicht nötig.',
    'cl200_vault_3': 'Direkt am Ort verschlüsseln: Dateien werden an ihrem Platz verschlüsselt, Ort und Ordnerstruktur bleiben unverändert. Der Browser zeigt ein Schloss-Symbol, andere Apps sehen nur Chiffrenamen.',
    'cl200_vault_4': 'Hilfeseite: Das Aktiviert-Abzeichen oben rechts im Tresor wurde durch einen Hilfe-Button ersetzt, der Funktionen, Bedienung und Kompatibilität erklärt.',
    'cl200_settings': 'Änderungen in den Einstellungen',
    'cl200_settings_1': 'Die Sicherheitseinstellungen der Tresor-Startseite sind in die Seite Einstellungen umgezogen.',
    'cl200_fixes': 'Fehlerbehebungen und Verbesserungen',
    'cl200_fix_1': 'Behoben: Im Browser wurden alle Dateien eines entfernten verschlüsselten Ordners mit dem Symbol für unbekanntes Format angezeigt.',
    'cl200_fix_2': 'Behoben: Entfernt verschlüsselte Audio- und Videodateien ließen sich nicht streamen und Bilder nicht anzeigen, wenn ein Cloud-Dienst die Dateigröße nicht meldet und die entschlüsselte Größe dadurch 0 wurde.',
    'cl200_fix_3': 'Behoben: In entfernten verschlüsselten Ordnern wurden keine Miniaturansichten geladen.',
    'cl200_fix_4': 'Die Streaming-Leistung wurde verbessert, indem eine überflüssige Netzwerkanfrage pro Datenblock entfällt; Wiedergabe und Spulen von entfernt verschlüsselten Medien laufen deutlich flüssiger.',
}

ES = {
    'cl200_notice': 'Cambio de versión y de nombre de paquete (lee esto)',
    'cl200_notice_1': 'La versión pasa a 2.0.0 y el nombre del paquete (ID de aplicación) cambia de com.sequl.zenfile a com.sequl.zenfile2. La versión 2.0 se instala como una aplicación independiente y no sobrescribirá la 1.x.',
    'cl200_notice_2': 'Motivo: la arquitectura de cifrado de la caja fuerte se ha rediseñado y ya no es compatible con los datos de versiones anteriores. Un nombre de paquete nuevo permite que ambas versiones convivan y evita que una instalación por encima destruya tus datos antiguos.',
    'cl200_notice_3': 'Haz primero tu propia copia: en la versión antigua abre «Caja fuerte → Copia/Restaurar → Exportar copia» y después en la nueva «Caja fuerte → Copia/Restaurar → Importar copia».',
    'cl200_notice_4': 'Desinstala la versión antigua solo cuando hayas comprobado que en la nueva está todo completo. Los archivos cifrados en zona aislada están en el directorio privado de la app y se borran al desinstalarla; nunca la desinstales primero.',
    'cl200_notice_5': 'Al cambiar el nombre del paquete, los permisos concedidos por paquete como Shizuku deben volver a concederse en la versión nueva.',
    'cl200_vault': 'Caja fuerte',
    'cl200_vault_1': 'Varios perfiles de contraseña: puedes asignar un perfil distinto a cada carpeta. El cifrado y descifrado ocurren por completo en el dispositivo y la contraseña maestra y la sal nunca salen de él.',
    'cl200_vault_2': 'Carpetas cifradas remotas: enlaza directamente una carpeta rclone crypt de tu nube; se descifra en el cliente y se lista con nombres normales, con reproducción en streaming de audio y vídeo y sin descargar el archivo completo.',
    'cl200_vault_3': 'Cifrado en el lugar: los archivos se cifran donde están, así que la ubicación y la estructura de carpetas no cambian. El navegador muestra un icono de candado y otras aplicaciones solo ven nombres cifrados.',
    'cl200_vault_4': 'Página de ayuda: el distintivo «Activada» de la esquina superior derecha se ha sustituido por un botón «Ayuda» que explica las funciones destacadas, el uso básico y la compatibilidad.',
    'cl200_settings': 'Cambios en los ajustes',
    'cl200_settings_1': 'Los ajustes de seguridad que estaban en la portada de la caja fuerte se han trasladado a la página «Ajustes».',
    'cl200_fixes': 'Correcciones y mejoras',
    'cl200_fix_1': 'Corregido: en el navegador, todos los archivos de una carpeta cifrada remota mostraban el icono de formato desconocido.',
    'cl200_fix_2': 'Corregido: el audio y el vídeo cifrados remotos no se reproducían en streaming y las imágenes no se mostraban, lo que ocurría cuando un servicio en la nube no informa del tamaño y el tamaño descifrado quedaba en 0.',
    'cl200_fix_3': 'Corregido: las miniaturas nunca se cargaban en las carpetas cifradas remotas.',
    'cl200_fix_4': 'Mejorado el rendimiento del streaming eliminando una petición de red innecesaria por bloque; la reproducción y el desplazamiento de medios cifrados remotos son mucho más fluidos.',
}

FR = {
    'cl200_notice': 'Changement de version et de nom de paquet (à lire)',
    'cl200_notice_1': 'La version passe à 2.0.0 et le nom du paquet (ID d application) change de com.sequl.zenfile à com.sequl.zenfile2. La version 2.0 s installe comme une application distincte et n écrase pas la 1.x.',
    'cl200_notice_2': 'Raison : l architecture de chiffrement du coffre a été repensée et n est plus compatible avec les données des anciennes versions. Un nouveau nom de paquet permet aux deux versions de cohabiter et évite qu une installation par-dessus ne détruise vos anciennes données.',
    'cl200_notice_3': 'Faites d abord votre propre sauvegarde : dans l ancienne version ouvrez « Coffre → Sauvegarde / Restauration → Exporter », puis dans la nouvelle « Coffre → Sauvegarde / Restauration → Importer ».',
    'cl200_notice_4': 'Ne désinstallez l ancienne version qu après avoir vérifié que tout est complet dans la nouvelle. Les fichiers chiffrés en bac à sable se trouvent dans le répertoire privé de l application et sont supprimés à la désinstallation : ne désinstallez jamais en premier.',
    'cl200_notice_5': 'Le nom du paquet ayant changé, les autorisations accordées par paquet comme Shizuku doivent être accordées à nouveau dans la nouvelle version.',
    'cl200_vault': 'Coffre-fort',
    'cl200_vault_1': 'Plusieurs profils de mot de passe : vous pouvez associer un profil différent à chaque dossier. Le chiffrement et le déchiffrement ont lieu entièrement sur l appareil et le mot de passe principal ainsi que le sel n en sortent jamais.',
    'cl200_vault_2': 'Dossiers chiffrés distants : associez directement un dossier rclone crypt de votre cloud ; il est déchiffré sur l appareil et listé avec des noms lisibles, avec lecture en continu de l audio et de la vidéo et sans télécharger le fichier entier.',
    'cl200_vault_3': 'Chiffrement sur place : les fichiers sont chiffrés là où ils se trouvent, l emplacement et la structure des dossiers ne changent pas. Le navigateur affiche un badge cadenas et les autres applications ne voient que des noms chiffrés.',
    'cl200_vault_4': 'Page d aide : le badge « Activé » en haut à droite du coffre est remplacé par un bouton « Aide » qui présente les points forts, les opérations de base et la compatibilité.',
    'cl200_settings': 'Changements dans les paramètres',
    'cl200_settings_1': 'Les paramètres de sécurité qui se trouvaient sur la page d accueil du coffre ont été déplacés vers la page « Paramètres ».',
    'cl200_fixes': 'Corrections et améliorations',
    'cl200_fix_1': 'Corrigé : dans le navigateur, tous les fichiers d un dossier chiffré distant affichaient l icône de format inconnu.',
    'cl200_fix_2': 'Corrigé : l audio et la vidéo chiffrés à distance ne pouvaient pas être lus en continu et les images ne s affichaient pas, ce qui se produisait lorsqu un service cloud n indique pas la taille et que la taille déchiffrée tombait à 0.',
    'cl200_fix_3': 'Corrigé : les miniatures ne se chargeaient jamais dans les dossiers chiffrés distants.',
    'cl200_fix_4': 'Performances de lecture en continu améliorées grâce à la suppression d une requête réseau inutile par bloc : la lecture et le déplacement dans les médias chiffrés à distance sont bien plus fluides.',
}

RU = {
    'cl200_notice': 'Изменение версии и имени пакета (обязательно к прочтению)',
    'cl200_notice_1': 'Версия повышается до 2.0.0, а имя пакета (идентификатор приложения) меняется с com.sequl.zenfile на com.sequl.zenfile2. Версия 2.0 устанавливается как отдельное приложение и не затирает 1.x.',
    'cl200_notice_2': 'Причина: архитектура шифрования сейфа переработана и больше не совместима с данными сейфа из старых версий. Новое имя пакета позволяет обоим версиям сосуществовать и не даёт установке поверх уничтожить старые данные.',
    'cl200_notice_3': 'Сначала сделайте резервную копию сами: в старой версии откройте «Сейф → Резервное копирование → Экспорт», затем в новой — «Сейф → Резервное копирование → Импорт».',
    'cl200_notice_4': 'Удаляйте старую версию только убедившись, что в новой всё на месте. Файлы, зашифрованные в песочнице, находятся в приватном каталоге приложения и удаляются вместе с ним, поэтому никогда не удаляйте приложение первым.',
    'cl200_notice_5': 'Из-за смены имени пакета разрешения, выдаваемые по пакету, например Shizuku, нужно выдать заново в новой версии.',
    'cl200_vault': 'Сейф',
    'cl200_vault_1': 'Несколько профилей паролей: для каждой папки можно закрепить свой профиль. Шифрование и расшифровка выполняются только на устройстве, мастер-пароль и соль никогда его не покидают.',
    'cl200_vault_2': 'Удалённые зашифрованные папки: можно напрямую связать папку rclone crypt в облаке; она расшифровывается на устройстве и показывается обычными именами, аудио и видео воспроизводятся потоком без полной загрузки.',
    'cl200_vault_3': 'Шифрование на месте: файлы шифруются там, где лежат, поэтому расположение и структура папок не меняются. В браузере появляется значок замка, а другие приложения видят только зашифрованные имена.',
    'cl200_vault_4': 'Справка: значок «Активировано» в правом верхнем углу сейфа заменён кнопкой «Справка», где описаны возможности, основные действия и совместимость.',
    'cl200_settings': 'Изменения в настройках',
    'cl200_settings_1': 'Раздел «Настройки безопасности», раньше находившийся на главной странице сейфа, перенесён на страницу «Настройки».',
    'cl200_fixes': 'Исправления и улучшения',
    'cl200_fix_1': 'Исправлено: в браузере все файлы удалённой зашифрованной папки отображались значком неизвестного формата.',
    'cl200_fix_2': 'Исправлено: удалённые зашифрованные аудио и видео не воспроизводились потоком, а изображения не отображались; это происходило, когда облако не сообщает размер файла и расшифрованный размер становится равен 0.',
    'cl200_fix_3': 'Исправлено: миниатюры не загружались в удалённых зашифрованных папках.',
    'cl200_fix_4': 'Улучшена производительность потоковой передачи: убран лишний сетевой запрос на каждый блок, воспроизведение и перемотка удалённых зашифрованных медиафайлов стали заметно плавнее.',
}

AR = {
    'cl200_notice': 'تغيير الإصدار واسم الحزمة (يُرجى القراءة)',
    'cl200_notice_1': 'تمت ترقية الإصدار إلى 2.0.0، وتغيّر اسم الحزمة (معرّف التطبيق) من com.sequl.zenfile إلى com.sequl.zenfile2. يُثبَّت الإصدار 2.0 كتطبيق مستقل ولا يستبدل الإصدار 1.x.',
    'cl200_notice_2': 'السبب: أُعيد تصميم بنية تشفير الخزنة ولم تعد متوافقة مع بيانات الخزنة في الإصدارات القديمة. اسم الحزمة الجديد يسمح بوجود الإصدارين معًا ويمنع التثبيت فوق الإصدار القديم من إتلاف بياناتك.',
    'cl200_notice_3': 'قم بالنسخ الاحتياطي بنفسك أولًا: في الإصدار القديم افتح «الخزنة → النسخ الاحتياطي / الاستعادة → تصدير نسخة»، ثم في الإصدار الجديد افتح «الخزنة → النسخ الاحتياطي / الاستعادة → استيراد نسخة».',
    'cl200_notice_4': 'لا تُزِل الإصدار القديم إلا بعد التأكد من اكتمال البيانات في الإصدار الجديد. الملفات المشفَّرة في وضع الحماية موجودة في مجلد التطبيق الخاص وتُمحى عند إزالة التطبيق، فلا تُزِله أولًا أبدًا.',
    'cl200_notice_5': 'بسبب تغيّر اسم الحزمة، يجب منح الأذونات الممنوحة لكل حزمة مثل Shizuku من جديد في الإصدار الجديد.',
    'cl200_vault': 'الخزنة',
    'cl200_vault_1': 'ملفات كلمات مرور متعددة: يمكنك ربط ملف كلمة مرور مختلف بكل مجلد. يتم التشفير وفك التشفير بالكامل على الجهاز، ولا تخرج كلمة المرور الرئيسية والملح منه أبدًا.',
    'cl200_vault_2': 'المجلدات المشفَّرة عن بُعد: اربط مجلد rclone crypt في السحابة مباشرة، فيُفك تشفيره على الجهاز ويُعرض بأسماء واضحة، مع تشغيل الصوت والفيديو بالبث المباشر دون تنزيل الملف كاملًا.',
    'cl200_vault_3': 'التشفير في مكانه: تُشفَّر الملفات حيث توجد، فيبقى الموقع وهيكل المجلدات كما هو. يعرض المتصفح شارة قفل، ولا ترى التطبيقات الأخرى سوى أسماء مشفَّرة.',
    'cl200_vault_4': 'صفحة المساعدة: استُبدلت شارة «مفعّل» أعلى يمين الخزنة بزر «مساعدة» يشرح أبرز المزايا والعمليات الأساسية والتوافق.',
    'cl200_settings': 'تغييرات في الإعدادات',
    'cl200_settings_1': 'نُقلت «إعدادات الأمان» التي كانت في الصفحة الرئيسية للخزنة إلى صفحة «الإعدادات».',
    'cl200_fixes': 'إصلاحات وتحسينات',
    'cl200_fix_1': 'تم الإصلاح: في المتصفح كانت جميع ملفات المجلد المشفَّر عن بُعد تظهر بأيقونة تنسيق غير معروف.',
    'cl200_fix_2': 'تم الإصلاح: تعذّر تشغيل الصوت والفيديو المشفَّرين عن بُعد بالبث وعرض الصور، ويحدث ذلك عندما لا تُبلّغ الخدمة السحابية عن حجم الملف فيصبح الحجم بعد فك التشفير صفرًا.',
    'cl200_fix_3': 'تم الإصلاح: لم تكن الصور المصغّرة تُحمَّل في المجلدات المشفَّرة عن بُعد.',
    'cl200_fix_4': 'تحسين أداء البث بإزالة طلب شبكة غير ضروري لكل كتلة، ما يجعل تشغيل الوسائط المشفَّرة عن بُعد والتنقل فيها أكثر سلاسة.',
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
        lines.append('    "description": "changelog 2.0.0: %s"' % key)
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
