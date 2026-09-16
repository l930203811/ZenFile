#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.1.1 更新日志 l10n 补齐（2026-09-16）：
新增 15 个 key（cl211_*）插入 10 ARB + 基类 dart + 9 locale dart（zh 双类）。

铁律（同 add_icon_widget_l10n.py）：
- app_*.arb 为 CRLF，generated/*.dart 为 LF → 全程二进制读写；
- 按锚点插入，绝不重跑 gen-l10n；
- zh.dart 双类：第一处 L10nZh 用 zh 值，第二处 L10nZhTw 用 zh_TW 值；
- 分区标题键（cl211_features / cl211_ui / cl211_fixes）只存纯文字，emoji 由 about_screen 的
  section() 在前面拼接（与 cl210_* 一致）。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

PLACEHOLDER_PARAMS = {}

# 15 个 key，顺序即插入顺序
NEW_KEYS = [
    'cl211_features',
    'cl211_feat_1',
    'cl211_feat_2',
    'cl211_ui',
    'cl211_ui_1',
    'cl211_ui_2',
    'cl211_ui_3',
    'cl211_fixes',
    'cl211_fix_1',
    'cl211_fix_2',
    'cl211_fix_3',
    'cl211_fix_4',
    'cl211_fix_5',
    'cl211_fix_6',
    'cl211_fix_7',
]

EN_NEW = {
    'cl211_features': 'New',
    'cl211_feat_1': 'Custom app icon from your own image: Settings → Appearance & Theme → App Icon. After picking an image you can add it to the home screen as a shortcut or as a 1x1 widget. Also fixed the case where it reported "added" without actually adding anything; if your launcher blocks shortcuts, use the widget instead.',
    'cl211_feat_2': 'Delete confirmation can now be disabled: the delete dialog has a "Don\'t ask again" checkbox, and Settings → File Operations & Viewers has a "Confirm before deleting" switch.',
    'cl211_ui': 'UI & Interaction',
    'cl211_ui_1': 'All progress dialogs now use a dual ring: outer ring for overall progress, inner green ring for the current file. Covers copy/cut, compress/extract, encrypt/decrypt, vault import & restore, and category backup.',
    'cl211_ui_2': 'Video playback controls are smaller and moved down just above the progress bar, so they no longer cover the center of the picture.',
    'cl211_ui_3': 'Vault in-place encryption list gains a "Remove" action — it only hides the entry, the encrypted file on disk is untouched.',
    'cl211_fixes': 'Fixes',
    'cl211_fix_1': 'Fixed black screen (audio only, no picture) on some devices, caused by a renderer compatibility issue introduced in 1.1.42. Rendering now uses the universally compatible path, and playback automatically falls back to software decoding when hardware decoding misbehaves.',
    'cl211_fix_2': 'Fixed remote video playback over SMB / FTP / SFTP that stalled every few seconds, and the progress bar jumping back to the start after seeking.',
    'cl211_fix_3': 'Fixed FTP occasionally taking a very long time to open or go up a directory.',
    'cl211_fix_4': 'Fixed compression of large or many files hanging at 100%: ZIP compression is now streamed file by file, greatly reducing memory use while progress keeps advancing.',
    'cl211_fix_5': 'Fixed the music player showing every track as "FLAC x 24-bit"; the real format is shown now, plus actual bit depth for lossless formats.',
    'cl211_fix_6': 'Fixed plain (unencrypted) files wrongly asking for the vault password after configuring the vault or encrypting in place.',
    'cl211_fix_7': 'Fixed two vault messages: a wrong password used to say "please set the master password first"; encrypt/decrypt result toasts were still Chinese in non-Chinese locales.',
}

ZH_NEW = {
    'cl211_features': '新增功能',
    'cl211_feat_1': '应用图标支持导入自定义图片：设置 → 外观与主题 → 应用图标，选择图片后可在桌面添加为快捷方式或 1×1 小组件。同时修复了此前点击提示「已添加」但桌面没有图标的问题；部分系统限制快捷方式时，可改用桌面小组件。',
    'cl211_feat_2': '删除文件的二次确认可按需关闭：删除弹窗新增「删除不再提示」复选框，设置 → 文件操作与查看器新增「删除文件确认」开关，关闭后删除不再弹出确认。',
    'cl211_ui': '界面与交互',
    'cl211_ui_1': '所有进度弹窗统一为双层圆环：外圈显示整体进度、内圈（绿色）显示当前文件进度，已覆盖复制/剪切、压缩/解压、加密/解密、保险箱导入加密与恢复解密、类别备份等场景。',
    'cl211_ui_2': '视频播放控制按钮整体缩小并下移，贴近进度条上方，不再遮挡画面中心。',
    'cl211_ui_3': '保险箱原地加密列表新增「移除」：仅从列表移除，磁盘上的加密文件不受影响。',
    'cl211_fixes': '问题修复',
    'cl211_fix_1': '修复部分机型播放视频黑屏（只有声音没有画面）的问题：由 1.1.42 引入的渲染兼容问题导致，现已改为通用渲染；并新增自动检测，硬解异常时自动切换软解续播，无需手动设置。',
    'cl211_fix_2': '修复 SMB / FTP / SFTP 播放远程视频「播几秒卡几秒」、拖动进度条又跳回开头的问题。',
    'cl211_fix_3': '修复 FTP 打开目录、返回上一级偶尔需要等待很久的问题。',
    'cl211_fix_4': '修复压缩大文件或多文件时进度停在 100% 长时间不动的问题：改为流式逐文件压缩，内存占用大幅降低，进度持续推进。',
    'cl211_fix_5': '修复音乐播放器把所有音频都显示为「FLAC • 24-bit」的问题，现在按真实格式显示，无损格式还会显示实际位深。',
    'cl211_fix_6': '修复配置保险箱密码或原地加密后，打开任意未加密文件都会要求验证保险箱密码的问题。',
    'cl211_fix_7': '修复保险箱提示的两处错误：解密密码输入错误时误提示「请先设置主密码」；加密/解密的结果提示在非中文界面下仍显示中文。',
}

ZH_TW_NEW = {
    'cl211_features': '新增功能',
    'cl211_feat_1': '應用程式圖示支援匯入自訂圖片：設定 → 外觀與主題 → 應用程式圖示，選擇圖片後可在桌面新增為捷徑或 1×1 小工具。同時修復了先前點擊提示「已新增」但桌面沒有圖示的問題；部分系統限制捷徑時，可改用桌面小工具。',
    'cl211_feat_2': '刪除檔案的二次確認可視需要關閉：刪除彈窗新增「刪除不再提示」核取方塊，設定 → 檔案操作與檢視器新增「刪除檔案確認」開關，關閉後刪除不再彈出確認。',
    'cl211_ui': '介面與互動',
    'cl211_ui_1': '所有進度彈窗統一為雙層圓環：外圈顯示整體進度、內圈（綠色）顯示目前檔案進度，已涵蓋複製/剪下、壓縮/解壓縮、加密/解密、保險箱匯入加密與復原解密、類別備份等場景。',
    'cl211_ui_2': '影片播放控制按鈕整體縮小並下移，貼近進度條上方，不再遮擋畫面中心。',
    'cl211_ui_3': '保險箱原地加密清單新增「移除」：僅從清單移除，磁碟上的加密檔案不受影響。',
    'cl211_fixes': '問題修復',
    'cl211_fix_1': '修復部分機型播放影片黑屏（只有聲音沒有畫面）的問題：由 1.1.42 引入的渲染相容問題導致，現已改為通用渲染；並新增自動偵測，硬體解碼異常時自動切換軟體解碼續播，無需手動設定。',
    'cl211_fix_2': '修復 SMB / FTP / SFTP 播放遠端影片「播幾秒卡幾秒」、拖動進度條又跳回開頭的問題。',
    'cl211_fix_3': '修復 FTP 開啟目錄、返回上一層偶爾需要等待很久的問題。',
    'cl211_fix_4': '修復壓縮大檔案或多檔案時進度停在 100% 長時間不動的問題：改為串流式逐檔壓縮，記憶體佔用大幅降低，進度持續推進。',
    'cl211_fix_5': '修復音樂播放器把所有音訊都顯示為「FLAC • 24-bit」的問題，現在按真實格式顯示，無損格式還會顯示實際位深。',
    'cl211_fix_6': '修復設定保險箱密碼或原地加密後，開啟任意未加密檔案都會要求驗證保險箱密碼的問題。',
    'cl211_fix_7': '修復保險箱提示的兩處錯誤：解密密碼輸入錯誤時誤提示「請先設定主密碼」；加密/解密的結果提示在非中文介面下仍顯示中文。',
}

JA_NEW = {
    'cl211_features': '新機能',
    'cl211_feat_1': '独自の画像によるカスタムアプリアイコン：設定 → 外観とテーマ → アプリアイコン。画像を選ぶと、ホーム画面にショートカットまたは 1×1 ウィジェットとして追加できます。また、以前「追加しました」と表示されたのに実際には追加されていなかった問題を修正しました。ランチャーがショートカットをブロックする場合は、ウィジェットをお使いください。',
    'cl211_feat_2': '削除の確認を無効にできるようになりました：削除ダイアログに「次回から確認しない」チェックボックスが追加され、設定 → ファイル操作とビューアに「削除前に確認」スイッチが追加されました。',
    'cl211_ui': 'UIと操作性',
    'cl211_ui_1': 'すべての進捗ダイアログが二重リングになりました：外側のリングが全体の進捗、内側の緑のリングが現在のファイルの進捗を示します。コピー/切り取り、圧縮/展開、暗号化/復号、保護区のインポートと復元、カテゴリバックアップに対応しています。',
    'cl211_ui_2': '動画再生のコントロールが小さくなり、プログレスバーのすぐ上に下へ移動したため、画面の中心を隠さなくなりました。',
    'cl211_ui_3': '保護区のその場暗号化リストに「削除」アクションが追加されました — リストからのみ削除され、ディスク上の暗号化ファイルには影響しません。',
    'cl211_fixes': '修正',
    'cl211_fix_1': '一部の端末で動画再生時に黒屏（音声のみで映像なし）になっていた問題を修正しました。これは 1.1.42 で導入されたレンダラーの互換性問題が原因です。描画は現在すべての端末で互換性のある方式を使用し、ハードウェアデコードで異常が発生した場合は自動的にソフトウェアデコードに切り替えて再生を続けます。',
    'cl211_fix_2': 'SMB / FTP / SFTP 経由のリモート動画再生が数秒ごとに止まり、シーク後にプログレスバーが最初に戻る問題を修正しました。',
    'cl211_fix_3': 'FTPでディレクトリを開く、または上位へ戻る際に時々非常に時間がかかっていた問題を修正しました。',
    'cl211_fix_4': '大きなファイルや多数のファイルを圧縮する際に進捗が 100% で長時間止まっていた問題を修正しました。ZIP 圧縮は現在ファイルごとにストリーミングされ、メモリ使用量が大幅に削減されながら進捗が進み続けます。',
    'cl211_fix_5': '音楽プレーヤーがすべての曲を「FLAC • 24-bit」と表示していた問題を修正しました。現在は実際の形式が表示され、ロスレス形式では実際のビット深度も表示されます。',
    'cl211_fix_6': '保護区のパスワード設定やその場暗号化後に、暗号化されていないファイルを開くと誤って保護区のパスワードを求められていた問題を修正しました。',
    'cl211_fix_7': '保護区のメッセージの2つの誤りを修正しました：パスワードを間違えた際に「先にマスターパスワードを設定してください」と誤表示されていたこと、および暗号化/復号の結果トーストが非中国語環境でも中国語のままだったことです。',
}

KO_NEW = {
    'cl211_features': '새 기능',
    'cl211_feat_1': '자신의 이미지로 사용자 지정 앱 아이콘: 설정 → 화면 및 테마 → 앱 아이콘. 이미지를 선택하면 홈 화면에 바로가기나 1×1 위젯으로 추가할 수 있습니다. 또한 이전에 "추가됨"이라고 표시됐지만 실제로 추가되지 않던 문제를 수정했습니다. 실행기가 바로가기를 차단하면 위젯을 사용하세요.',
    'cl211_feat_2': '삭제 확인을 끌 수 있게 되었습니다: 삭제 대화상자에 "다시 묻지 않음" 체크박스가 추가되고, 설정 → 파일 작업 및 뷰어에 "삭제 전 확인" 스위치가 추가되었습니다.',
    'cl211_ui': 'UI 및 조작',
    'cl211_ui_1': '모든 진행 대화상자가 이중 링으로 통일되었습니다: 바깥쪽 링은 전체 진행률, 안쪽 녹색 링은 현재 파일 진행률을 표시하며 복사/이동, 압축/해제, 암호화/복호화, 보관함 가져오기 및 복원, 카테고리 백업을 포함합니다.',
    'cl211_ui_2': '동영상 재생 컨트롤이 작아지고 진행 표시줄 바로 위로 아래로 이동하여 화면 중앙을 가리지 않습니다.',
    'cl211_ui_3': '보관함 내부 암호화 목록에 "제거" 동작이 추가되었습니다 — 목록에서만 제거되며 디스크의 암호화 파일에는 영향을 주지 않습니다.',
    'cl211_fixes': '수정',
    'cl211_fix_1': '일부 기기에서 동영상 재생 시 검은 화면(소리만 있고 영상 없음)이 발생하던 문제를 수정했습니다. 1.1.42에서 도입된 렌더러 호환성 문제가 원인이며, 이제 범용 렌더링을 사용하고 하드웨어 디코딩 이상 시 자동으로 소프트웨어 디코딩으로 전환하여 재생을 이어갑니다.',
    'cl211_fix_2': 'SMB / FTP / SFTP를 통한 원격 동영상 재생이 몇 초마다 멈추고, 탐색 후 진행 표시줄이 처음으로 돌아가던 문제를 수정했습니다.',
    'cl211_fix_3': 'FTP에서 디렉터리를 열거나 상위로 이동할 때 가끔 매우 오래 걸리던 문제를 수정했습니다.',
    'cl211_fix_4': '큰 파일이나 여러 파일 압축 시 진행률이 100%에서 오래 멈추던 문제를 수정했습니다. ZIP 압축은 이제 파일 단위로 스트리밍되어 메모리 사용량이 크게 줄어들면서도 진행률이 계속 나아갑니다.',
    'cl211_fix_5': '음악 플레이어가 모든 곡을 "FLAC • 24-bit"로 표시하던 문제를 수정했습니다. 이제 실제 형식이 표시되며, 무손실 형식은 실제 비트 심도도 표시됩니다.',
    'cl211_fix_6': '보관함 암호 설정이나 내부 암호화 후, 암호화되지 않은 파일을 열 때 보관함 암호를 잘못 요구하던 문제를 수정했습니다.',
    'cl211_fix_7': '보관함 메시지의 두 가지 오류를 수정했습니다: 암호를 틀렸을 때 "먼저 마스터 암호를 설정하세요"라고 잘못 표시되던 것, 그리고 암호화/복호화 결과 토스트가 비중국어 환경에서도 중국어로 표시되던 것입니다.',
}

DE_NEW = {
    'cl211_features': 'Neu',
    'cl211_feat_1': 'Eigenes Bild als App-Symbol: Einstellungen → Erscheinungsbild & Design → App-Symbol. Nach dem Auswählen eines Bildes kannst du es als Verknüpfung oder als 1×1-Widget auf den Startbildschirm legen. Behoben wurde zudem der Fall, dass "hinzugefügt" gemeldet wurde, ohne dass etwas passierte; falls dein Launcher Verknüpfungen blockiert, nutze das Widget.',
    'cl211_feat_2': 'Die Löschbestätigung kann nun deaktiviert werden: Der Löschdialog hat ein Kontrollkästchen "Nicht mehr fragen", und unter Einstellungen → Dateioperationen & Betrachter gibt es den Schalter "Vor dem Löschen bestätigen".',
    'cl211_ui': 'Oberfläche & Bedienung',
    'cl211_ui_1': 'Alle Fortschrittsdialoge nutzen nun einen Doppelring: der äußere Ring zeigt den Gesamtfortschritt, der innere grüne Ring den Fortschritt der aktuellen Datei. Abgedeckt sind Kopieren/Ausschneiden, Komprimieren/Entpacken, Verschlüsseln/Entschlüsseln, Tresor-Import & -Wiederherstellung und Kategorie-Backup.',
    'cl211_ui_2': 'Die Videosteuerungen sind kleiner und nach unten direkt über die Fortschrittsleiste verschoben, sodass sie die Bildmitte nicht mehr verdecken.',
    'cl211_ui_3': 'Die Liste der direkten Verschlüsselung im Tresor erhält eine Aktion "Entfernen" — sie blendet nur den Eintrag aus, die verschlüsselte Datei auf der Festplatte bleibt unberührt.',
    'cl211_fixes': 'Fehlerbehebungen',
    'cl211_fix_1': 'Schwarzer Bildschirm (nur Ton, kein Bild) bei der Videowiedergabe auf einigen Geräten behoben, verursacht durch ein mit 1.1.42 eingeführtes Renderer-Kompatibilitätsproblem. Die Darstellung nutzt nun den universell kompatiblen Pfad, und bei Problemen mit der Hardware-Dekodierung wird automatisch auf Software-Dekodierung umgeschaltet.',
    'cl211_fix_2': 'Behoben: Remote-Videowiedergabe über SMB / FTP / SFTP blieb alle paar Sekunden hängen, und die Fortschrittsleiste sprang nach dem Suchen wieder an den Anfang.',
    'cl211_fix_3': 'Behoben: FTP brauchte beim Öffnen eines Verzeichnisses oder beim Zurückgehen manchmal sehr lange.',
    'cl211_fix_4': 'Behoben: Komprimierung großer oder vieler Dateien blieb bei 100 % hängen. Die ZIP-Komprimierung erfolgt nun dateiweise im Stream, was den Speicherverbrauch stark senkt, während der Fortschritt weiterläuft.',
    'cl211_fix_5': 'Behoben, dass der Musikplayer jeden Titel als "FLAC • 24-bit" anzeigte; nun wird das echte Format angezeigt, plus die tatsächliche Bit-Tiefe bei verlustfreien Formaten.',
    'cl211_fix_6': 'Behoben: Nach dem Konfigurieren des Tresors oder dem Verschlüsseln am Ort verlangten unverschlüsselte Dateien fälschlicherweise das Tresor-Passwort.',
    'cl211_fix_7': 'Zwei Tresor-Meldungen behoben: bei falschem Passwort erschien fälschlicherweise "bitte zuerst das Master-Passwort festlegen"; Ergebnis-Toasts für Verschlüsseln/Entschlüsseln waren in nicht-chinesischen Sprachen weiterhin auf Chinesisch.',
}

ES_NEW = {
    'cl211_features': 'Novedades',
    'cl211_feat_1': 'Icono de app con tu propia imagen: Ajustes → Apariencia y tema → Icono de app. Tras elegir una imagen puedes añadirla a la pantalla de inicio como acceso directo o como widget 1×1. También se corrigió el caso en que decía "añadido" sin añadir nada; si tu lanzador bloquea los accesos directos, usa el widget.',
    'cl211_feat_2': 'La confirmación de eliminación ahora se puede desactivar: el diálogo de eliminación tiene una casilla "No volver a preguntar", y en Ajustes → Operaciones de archivos y visores hay un interruptor "Confirmar antes de eliminar".',
    'cl211_ui': 'Interfaz e interacción',
    'cl211_ui_1': 'Todos los diálogos de progreso usan ahora un doble anillo: el exterior para el progreso total y el interior verde para el archivo actual. Cubre copiar/mover, comprimir/extraer, cifrar/descifrar, importar y restaurar la caja fuerte, y la copia de seguridad por categoría.',
    'cl211_ui_2': 'Los controles de reproducción de vídeo son más pequeños y se han movido abajo, justo encima de la barra de progreso, por lo que ya no tapa el centro de la imagen.',
    'cl211_ui_3': 'La lista de cifrado in situ de la caja fuerte tiene ahora una acción "Quitar": solo oculta la entrada, el archivo cifrado en disco no se ve afectado.',
    'cl211_fixes': 'Correcciones',
    'cl211_fix_1': 'Corregido el pantalla negra (solo audio, sin imagen) al reproducir vídeo en algunos dispositivos, causada por un problema de compatibilidad del renderizador introducido en 1.1.42. El renderizado usa ahora la ruta universalmente compatible y, si la decodificación de hardware falla, cambia automáticamente a decodificación por software.',
    'cl211_fix_2': 'Corregida la reproducción de vídeo remoto por SMB / FTP / SFTP que se detenía cada pocos segundos y la barra de progreso que volvía al inicio tras buscar.',
    'cl211_fix_3': 'Corregido que FTP tardara a veces mucho en abrir o retroceder un directorio.',
    'cl211_fix_4': 'Corregida la compresión de archivos grandes o numerosos que se quedaba en 100%: la compresión ZIP ahora se transmite archivo por archivo, reduciendo mucho el uso de memoria mientras el progreso avanza.',
    'cl211_fix_5': 'Corregido que el reproductor de música mostraba todas las canciones como "FLAC • 24-bit"; ahora se muestra el formato real, y la profundidad de bits real en formatos sin pérdida.',
    'cl211_fix_6': 'Corregido que los archivos sin cifrar pedían la contraseña de la caja fuerte tras configurarla o cifrar en sitio.',
    'cl211_fix_7': 'Corregidos dos mensajes de la caja fuerte: al introducir una contraseña errónea se decía "configure primero la contraseña maestra"; los avisos de resultado de cifrar/descifrar seguían en chino en idiomas no chinos.',
}

FR_NEW = {
    'cl211_features': 'Nouveautés',
    'cl211_feat_1': "Icône d'application avec votre propre image : Paramètres → Apparence et thème → Icône d'application. Après avoir choisi une image, vous pouvez l'ajouter à l'écran d'accueil en tant que raccourci ou widget 1×1. Correction également du cas où il indiquait « ajouté » sans rien ajouter ; si votre lanceur bloque les raccourcis, utilisez le widget.",
    'cl211_feat_2': 'La confirmation de suppression peut désormais être désactivée : la boîte de dialogue de suppression comporte une case « Ne plus demander », et dans Paramètres → Opérations et visionneuses de fichiers se trouve un interrupteur « Confirmer avant de supprimer ».',
    'cl211_ui': 'Interface et interaction',
    'cl211_ui_1': "Toutes les boîtes de progression utilisent désormais un double anneau : l'extérieur pour la progression globale, l'intérieur vert pour le fichier en cours. Couvre copier/couper, compresser/extraire, chiffrer/déchiffrer, import et restauration du coffre, et la sauvegarde par catégorie.",
    'cl211_ui_2': "Les commandes de lecture vidéo sont plus petites et déplacées vers le bas, juste au-dessus de la barre de progression, elles ne cachent donc plus le centre de l'image.",
    'cl211_ui_3': "La liste de chiffrement sur place du coffre dispose désormais d'une action « Retirer » : elle masque uniquement l'entrée, le fichier chiffré sur le disque reste intact.",
    'cl211_fixes': 'Corrections',
    'cl211_fix_1': "Correction de l'écran noir (son uniquement, pas d'image) lors de la lecture vidéo sur certains appareils, dû à un problème de compatibilité du moteur de rendu introduit en 1.1.42. Le rendu utilise désormais le chemin universellement compatible et bascule automatiquement en décodage logiciel si le décodage matériel échoue.",
    'cl211_fix_2': "Correction de la lecture vidéo distante via SMB / FTP / SFTP qui s'interrompait toutes les quelques secondes, et de la barre de progression qui revenait au début après un repérage.",
    'cl211_fix_3': "Correction du cas où FTP mettait parfois très longtemps à ouvrir un dossier ou à revenir en arrière.",
    'cl211_fix_4': "Correction de la compression de fichiers volumineux ou nombreux bloquée à 100 % : la compression ZIP est désormais diffusée fichier par fichier, réduisant fortement l'usage mémoire tout en faisant avancer la progression.",
    'cl211_fix_5': "Correction de l'affichage par le lecteur de musique de chaque piste comme « FLAC • 24-bit » ; le format réel s'affiche désormais, ainsi que la profondeur de bits réelle pour les formats sans perte.",
    'cl211_fix_6': "Correction : après la configuration du coffre ou le chiffrement sur place, les fichiers non chiffrés demandaient à tort le mot de passe du coffre.",
    'cl211_fix_7': "Correction de deux messages du coffre : un mot de passe erroné indiquait à tort « définissez d'abord le mot de passe principal » ; les notifications de résultat de chiffrement/déchiffrement restaient en chinois dans les langues non chinoises.",
}

RU_NEW = {
    'cl211_features': 'Новое',
    'cl211_feat_1': 'Собственное изображение как значок приложения: Настройки → Внешний вид и тема → Значок приложения. После выбора изображения его можно добавить на главный экран как ярлык или как виджет 1×1. Также исправлен случай, когда сообщалось «добавлено», но на деле ничего не добавлялось; если ваш лаунчер блокирует ярлыки, используйте виджет.',
    'cl211_feat_2': 'Подтверждение удаления теперь можно отключить: в диалоге удаления есть флажок «Больше не спрашивать», а в Настройки → Файловые операции и просмотр добавлён переключатель «Подтверждать перед удалением».',
    'cl211_ui': 'Интерфейс и взаимодействие',
    'cl211_ui_1': 'Все диалоги прогресса теперь используют двойное кольцо: внешнее — для общего прогресса, внутреннее зелёное — для текущего файла. Охватывает копирование/вырезание, сжатие/распаковку, шифрование/расшифровку, импорт и восстановление хранилища, и резервное копирование по категориям.',
    'cl211_ui_2': 'Элементы управления воспроизведением видео стали меньше и опущены вниз прямо над полосой прогресса, поэтому больше не закрывают центр кадра.',
    'cl211_ui_3': 'В списке шифрования на месте хранилища появилось действие «Удалить» — оно лишь скрывает запись, зашифрованный файл на диске не затрагивается.',
    'cl211_fixes': 'Исправления',
    'cl211_fix_1': 'Исправлен чёрный экран (только звук, нет изображения) при воспроизведении видео на некоторых устройствах, вызванный проблемой совместимости рендерера, появившейся в 1.1.42. Теперь используется универсально совместимый путь отрисовки, а при сбоях аппаратного декодирования воспроизведение автоматически переключается на программное.',
    'cl211_fix_2': 'Исправлено воспроизведение удалённого видео по SMB / FTP / SFTP, которое замирало каждые несколько секунд, и панель прогресса возвращалась в начало после перемотки.',
    'cl211_fix_3': 'Исправлено: FTP иногда очень долго открывал папку или возвращался на уровень вверх.',
    'cl211_fix_4': 'Исправлено зависание сжатия больших или многих файлов на 100 %: ZIP-сжатие теперь выполняется потоково по файлам, что резко снижает расход памяти, пока прогресс продолжается.',
    'cl211_fix_5': 'Исправлено отображение всех треков плеером как «FLAC • 24-bit»; теперь показывается реальный формат, а для lossless — фактическая битовая глубина.',
    'cl211_fix_6': 'Исправлено: после настройки хранилища или шифрования на месте незашифрованные файлы ошибочно запрашивали пароль хранилища.',
    'cl211_fix_7': 'Исправлены две ошибки сообщений хранилища: при неверном пароле ошибочно показывалось «сначала задайте мастер-пароль»; уведомления о результате шифрования/расшифровки оставались на китайском в некитайских локалях.',
}

AR_NEW = {
    'cl211_features': 'جديد',
    'cl211_feat_1': 'أيقونة تطبيق من صورتك الخاصة: الإعدادات → المظهر والسمة → أيقونة التطبيق. بعد اختيار صورة، يمكنك إضافتها إلى الشاشة الرئيسية كاختصار أو كأداة بحجم 1×1. وأصلحنا أيضاً حالة الإبلاغ بـ «تمت الإضافة» دون إضافة شيء؛ إن كان مشغّل الشاشة يمنع الاختصارات، استخدم الأداة.',
    'cl211_feat_2': 'أصبح بإمكانك تعطيل تأكيد الحذف: يوجد في نافذة الحذف خيار «لا تسأل مجدداً»، وفي الإعدادات → عمليات الملفات والعارضات يوجد مفتاح «تأكيد قبل الحذف».',
    'cl211_ui': 'الواجهة والتفاعل',
    'cl211_ui_1': 'كل نوافذ التقدّم تستخدم الآن حلقة مزدوجة: الحلقة الخارجية للتقدّم الكلي والداخلية الخضراء للملف الحالي. تشمل النسخ/القص، والضغط/الفك، والتشفير/فك التشفير، واستيراد واستعادة الخزنة، والنسخ الاحتياطي حسب الفئة.',
    'cl211_ui_2': 'أزرار تشغيل الفيديو أصغر حجماً وأُسقطت للأسفل فوق شريط التقدّم مباشرةً، فلم تعد تغطي مركز الصورة.',
    'cl211_ui_3': 'حصلت قائمة التشفير الموضعي في الخزنة على إجراء «إزالة» — يخفي الإدخال فقط، ولا يتأثر الملف المشفّر على القرص.',
    'cl211_fixes': 'إصلاحات',
    'cl211_fix_1': 'أصلحنا الشاشة السوداء (صوت فقط بلا صورة) عند تشغيل الفيديو على بعض الأجهزة، بسبب مشكلة توافق في العارض وُرِدت في 1.1.42. يستخدم العرض الآن المسار المتوافق عالمياً، ويتحول تلقائياً إلى فك التشفير البرمجي عند فشل فك التشفير العتادي.',
    'cl211_fix_2': 'أصلحنا تشغيل الفيديو عن بُعد عبر SMB / FTP / SFTP الذي كان يتوقف كل بضع ثوانٍ، وارتداد شريط التقدّم إلى البداية بعد السعي.',
    'cl211_fix_3': 'أصلحنا بطء FTP أحياناً عند فتح مجلد أو العودة لمجلد أعلى.',
    'cl211_fix_4': 'أصلحنا توقّف ضغط الملفات الكبيرة أو الكثيرة عند 100%: أصبح ضغط ZIP تدفقياً ملفاً بملف، ما يقلل استخدام الذاكرة كثيراً مع استمرار التقدّم.',
    'cl211_fix_5': 'أصلحنا عرض مشغّل الموسيقى لكل المسارات كـ «FLAC • 24-bit»؛ يظهر الآن التنسيق الفعلي، مع عمق البت الفعلي للتنسيقات غير المفقودة.',
    'cl211_fix_6': 'أصلحنا طلب ملفات غير مشفّرة لكلمة مرور الخزنة بشكل خاطئ بعد إعداد الخزنة أو التشفير الموضعي.',
    'cl211_fix_7': 'أصلحنا خطأين في رسائل الخزنة: عند إدخال كلمة مرور خاطئة كان يظهر «عيّن كلمة المرور الرئيسية أولاً»؛ وبقيت إشعارات نتيجة التشفير/فك التشفير بالصينية في اللغات غير الصينية.',
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
        lines.append('    "description": "changelog 2.1.1: %s"' % key)
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
