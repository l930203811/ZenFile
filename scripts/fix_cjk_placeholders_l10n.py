#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fix Chinese-placeholder l10n values in non-zh locales (ko/ja/de/fr/es/ru/ar + en 2 keys).
Edits ARB (CRLF, targeted regex, no reformat) AND generated dart (LF, getter values).
"""
import io, re, json, os

DIR = r'D:\Xiangmu\ZenFile-main\lib\l10n'
GEN = os.path.join(DIR, 'generated')

# ---------- translations ----------
UI = {
 'ui_auto_backup': {
  'ko':'자동 백업','ja':'自動バックアップ','de':'Automatisches Backup','fr':'Sauvegarde automatique',
  'es':'Copia de seguridad automática','ru':'Автоматическое резервное копирование','ar':'النسخ الاحتياطي التلقائي'},
 'ui_backup': {
  'ko':'백업','ja':'バックアップ','de':'Backup','fr':'Sauvegarde',
  'es':'Copia de seguridad','ru':'Резервная копия','ar':'نسخ احتياطي'},
 'ui_backup_now': {
  'ko':'지금 백업','ja':'今すぐバックアップ','de':'Jetzt sichern','fr':'Sauvegarder maintenant',
  'es':'Hacer copia ahora','ru':'Создать копию сейчас','ar':'نسخ احتياطي الآن'},
 'ui_local': {
  'ko':'로컬','ja':'ローカル','de':'Lokal','fr':'Local','es':'Local','ru':'Локально','ar':'محلي'},
 'ui_no_remote_path': {
  'ko':'사용자 지정 원격 경로가 없습니다','ja':'カスタムリモートパスが未追加です','de':'Kein benutzerdefinierter Remote-Pfad hinzugefügt',
  'fr':'Aucun chemin distant personnalisé ajouté','es':'No se ha añadido una ruta remota personalizada',
  'ru':'Пользовательский удалённый путь не добавлен','ar':'لم تتم إضافة مسار مخصص للخادم البعيد'},
 'ui_remote': {
  'ko':'원격','ja':'リモート','de':'Remote','fr':'Distant','es':'Remoto','ru':'Удалённое','ar':'بعيد'},
 'ui_sync_done': {
  'ko':'백업 완료','ja':'バックアップ完了','de':'Backup abgeschlossen','fr':'Sauvegarde terminée',
  'es':'Copia de seguridad completada','ru':'Резервное копирование завершено','ar':'اكتمل النسخ الاحتياطي'},
 'ui_syncing': {
  'ko':'백업 중...','ja':'バックアップ中...','de':'Backup läuft...','fr':'Sauvegarde en cours...',
  'es':'Realizando copia de seguridad...','ru':'Выполняется резервное копирование...','ar':'جارٍ النسخ الاحتياطي...'},
 'ui_test': {
  'ko':'테스트','ja':'テスト','de':'Testen','fr':'Tester','es':'Probar','ru':'Тест','ar':'اختبار'},
 'ui_test_failed': {
  'ko':'테스트 실패','ja':'テスト失敗','de':'Test fehlgeschlagen','fr':'Échec du test',
  'es':'Prueba fallida','ru':'Тест не пройден','ar':'فشل الاختبار'},
 'ui_test_failed_reason': {
  'ko':'실패 원인','ja':'失敗の原因','de':'Fehlerursache',"fr":"Raison de l'échec",
  'es':'Motivo del fallo','ru':'Причина сбоя','ar':'سبب الفشل'},
 'ui_test_success': {
  'ko':'테스트 성공','ja':'テスト成功','de':'Test erfolgreich','fr':'Test réussi',
  'es':'Prueba exitosa','ru':'Тест пройден','ar':'نجح الاختبار'},
 'ui_test_success_desc': {
  'ko':'연결 성공, 서버 설정이 올바릅니다','ja':'接続に成功しました。サーバー設定は正しいです',
  'de':'Verbindung erfolgreich, Serverkonfiguration korrekt','fr':'Connexion réussie, la configuration du serveur est correcte',
  'es':'Conexión correcta, la configuración del servidor es válida','ru':'Соединение успешно, конфигурация сервера верна',
  'ar':'تم الاتصال بنجاح، إعدادات الخادم صحيحة'},
 'ui_show_remote_files': {
  'ko':'원격 파일 표시','ja':'リモートファイルを表示','de':'Remote-Dateien anzeigen','fr':'Afficher les fichiers distants',
  'es':'Mostrar archivos remotos','ru':'Показать удалённые файлы','ar':'إظهار الملفات البعيدة'},
 'ui_hide_remote_files': {
  'ko':'원격 파일 숨기기','ja':'リモートファイルを非表示','de':'Remote-Dateien ausblenden','fr':'Masquer les fichiers distants',
  'es':'Ocultar archivos remotos','ru':'Скрыть удалённые файлы','ar':'إخفاء الملفات البعيدة'},
 'ui_category_settings_title': {
  'ko':'카테고리 설정','ja':'カテゴリ設定','de':'Kategorie-Einstellungen','fr':'Paramètres de catégorie',
  'es':'Ajustes de categoría','ru':'Настройки категории','ar':'إعدادات الفئة',
  'en':'Category settings'},
 'ui_category_settings_description': {
  'ko':'이 카테고리의 필터 규칙과 스캔 위치를 관리합니다','ja':'このカテゴリのフィルタルールとスキャン場所を管理します',
  'de':'Filterregeln und Scan-Speicherorte dieser Kategorie verwalten',
  'fr':"Gérer les règles de filtrage et les emplacements d'analyse de cette catégorie",
  'es':'Gestionar las reglas de filtrado y ubicaciones de escaneo de esta categoría',
  'ru':'Управление правилами фильтрации и местами сканирования этой категории',
  'ar':'إدارة قواعد التصفية ومواقع الفحص لهذه الفئة',
  'en':'Manage filter rules and scan locations for this category'},
}

CH = {
 'changelog_v1130_new_1': {
  'ko':'원격 보호 PIN: 4자리 PIN을 설정하면 저장된 원격 서버 접근, 편집 페이지 진입, 카테고리 페이지의 원격 범위 전환 시 먼저 잠금 해제가 필요하며 원격 데이터 프라이버시를 보호합니다',
  'ja':'リモート保護PIN：4桁のPINを設定すると、保存済みリモートサーバーへのアクセス・編集ページへの移動・カテゴリページのリモート範囲切替時にロック解除が必要になり、リモートデータのプライバシーを保護します',
  'de':'Remote-Schutz-PIN: Nach dem Festlegen einer 4-stelligen PIN muss beim Zugriff auf gespeicherte Remote-Server, beim Betreten der Bearbeitungsseite und beim Wechsel der Kategorieseite zum Remote-Bereich zuerst entsperrt werden, um die Privatsphäre entfernter Daten zu schützen',
  'fr':"PIN de protection à distance : après avoir défini un code à 4 chiffres, l'accès aux serveurs distants enregistrés, l'entrée dans la page d'édition et le passage d'une catégorie à la portée distante nécessitent d'abord un déverrouillage, protégeant la confidentialité des données distantes",
  'es':'PIN de protección remota: tras establecer un PIN de 4 dígitos, acceder a servidores remotos guardados, entrar en la página de edición o cambiar una categoría al ámbito remoto requiere desbloquear primero, protegiendo la privacidad de los datos remotos',
  'ru':'PIN защиты удалённых данных: после установки 4-значного PIN доступ к сохранённым удалённым серверам, вход на страницу редактирования и переключение категории на удалённую область требуют предварительной разблокировки, защищая конфиденциальность удалённых данных',
  'ar':'رمز حماية الاتصالات البعيدة: بعد تعيين رمز PIN من 4 أرقام، يتطلب الوصول إلى الخوادم البعيدة المحفوظة ودخول صفحة التحرير وتبديل الفئة إلى النطاق البعيد إلغاء القفل أولاً، حمايةً لخصوصية البيانات البعيدة'},
 'changelog_v1130_new_2': {
  'ko':'카테고리 페이지 로컬/원격 전환: 원격 디렉터리를 지원하는 모든 카테고리에서 로컬/원격 콘텐츠를 독립적으로 전환 가능',
  'ja':'カテゴリページの「ローカル/リモート」切替：リモートディレクトリ対応カテゴリはローカル/リモート内容を個別に切替可能',
  'de':'Umschaltung Lokal/Remote auf der Kategorieseite: Alle Kategorien mit Remote-Unterstützung können zwischen lokalem und Remote-Inhalt umschalten',
  'fr':'Bascule Local/Distant sur la page des catégories : toutes les catégories prenant en charge les répertoires distants peuvent basculer indépendamment entre contenu local et distant',
  'es':'Conmutación Local/Remoto en la página de categorías: todas las categorías con soporte de directorios remotos pueden alternar independientemente entre contenido local y remoto',
  'ru':'Переключатель «Локальное/Удалённое» на странице категорий: все категории с поддержкой удалённых каталогов могут независимо переключаться между локальным и удалённым содержимым',
  'ar':'مفتاح تبديل «محلي/بعيد» في صفحة الفئات: جميع الفئات التي تدعم المجلدات البعيدة يمكنها التبديل بشكل مستقل بين المحتوى المحلي والبعيد'},
 'changelog_v1130_new_3': {
  'ko':'백업 기능(로컬→원격): 자동 백업과 지금 백업 지원, 새 파일 감지가 자동 트리거되며 해당 카테고리 형식 파일만 백업',
  'ja':'バックアップ機能（ローカル→リモート）：「自動バックアップ」と「今すぐバックアップ」に対応、新規ファイル検出で自動トリガー、対象カテゴリ形式のファイルのみバックアップ',
  'de':'Backup-Funktion (lokal→remote): Unterstützt „Automatisches Backup“ und „Jetzt sichern“; Erkennung neuer Dateien löst automatisch aus, es werden nur Dateien des Kategorieformats gesichert',
  'fr':'Fonction de sauvegarde (local→distant) : prend en charge « Sauvegarde automatique » et « Sauvegarder maintenant » ; la détection de nouveaux fichiers se déclenche automatiquement, seuls les fichiers du format de la catégorie sont sauvegardés',
  'es':'Función de copia de seguridad (local→remoto): admite «Copia automática» y «Hacer copia ahora»; la detección de archivos nuevos se activa automáticamente y solo se copian archivos del formato de la categoría',
  'ru':'Функция резервного копирования (локальное→удалённое): поддерживаются «Автокопирование» и «Копировать сейчас»; обнаружение новых файлов срабатывает автоматически, копируются только файлы формата категории',
  'ar':'ميزة النسخ الاحتياطي (محلي→بعيد): تدعم «النسخ التلقائي» و«النسخ الآن»؛ يُفعَّل اكتشاف الملفات الجديدة تلقائياً، وتُنسخ ملفات الفئة نفسها فقط'},
 'changelog_v1130_new_4': {
  'ko':'원격 연결 마법사에 테스트 버튼 추가: 구성 저장 전 연결을 먼저 검증 가능',
  'ja':'リモート接続ウィザードに「テスト」ボタンを追加：設定保存前に接続を検証できます',
  'de':'Remote-Verbindungsassistent: neuer „Testen“-Button, um die Verbindung vor dem Speichern zu prüfen',
  'fr':"L'assistant de connexion distante ajoute un bouton « Tester » pour vérifier la connexion avant d'enregistrer la configuration",
  'es':'El asistente de conexión remota añade el botón «Probar» para verificar la conexión antes de guardar la configuración',
  'ru':'Мастер подключения добавил кнопку «Тест» для проверки соединения перед сохранением конфигурации',
  'ar':'معالج الاتصال البعيد يضيف زر «اختبار» للتحقق من الاتصال قبل حفظ الإعدادات'},
 'changelog_v1130_new_5': {
  'ko':'비디오/오디오 카테고리 메뉴에 플레이어 컨트롤러 표시 스위치 추가',
  'ja':'動画/オーディオカテゴリメニューに「プレーヤーコントロール表示」スイッチを追加',
  'de':'Video/Audio-Kategorienmenü: neuer Schalter „Player-Steuerung anzeigen“',
  'fr':'Menu des catégories vidéo/audio : ajout d’un interrupteur « Afficher les contrôles du lecteur »',
  'es':'Menú de categorías de vídeo/audio: nuevo interruptor «Mostrar controles del reproductor»',
  'ru':'Меню категорий видео/аудио: добавлен переключатель «Показывать контроллер плеера»',
  'ar':'قائمة فئات الفيديو/الصوت: مفتاح جديد «إظهار أدوات التحكم بالمشغل»'},
 'changelog_v1130_new_6': {
  'ko':'열기 방식 대화상자 통합: 브라우저/최근/카테고리 페이지의 점 3개 메뉴와 길게 누르기 메뉴 모두 앱 내 선택 대화상자 표시',
  'ja':'「開き方」ダイアログを統一：ブラウザ/最近/カテゴリページの3点メニューと長押しメニューからアプリ内選択ダイアログを表示',
  'de':'Vereinheitlichter „Öffnen mit“-Dialog: Browse/Letzte/Kategorie-Seiten zeigen aus 3-Punkt- und Langdruck-Menüs den In-App-Auswahl-Dialog',
  'fr':'Boîte de dialogue « Ouvrir avec » unifiée : les pages Parcourir/Récent/Catégories affichent le sélecteur intégré depuis les menus 3 points et appui long',
  'es':'Diálogo «Abrir con» unificado: las páginas Examinar/Recientes/Categorías muestran el selector integrado desde los menús de tres puntos y pulsación larga',
  'ru':'Единый диалог «Открыть с помощью»: страницы Обзор/Недавние/Категории открывают встроенный выбор из меню из трёх точек и долгого нажатия',
  'ar':'توحيد نافذة «فتح باستخدام»: تعرض صفحات التصفح/الأحدث/الفئات منتقي التطبيق المدمج من قوائم النقاط الثلاث والضغط الطويل'},
 'changelog_v1130_new_7': {
  'ko':'알 수 없는 형식 파일에서 이 앱으로 열기 선택 시 유형 선택기(텍스트/오디오/비디오/이미지) 표시 후 내장 뷰어로 열기',
  'ja':'不明な形式のファイルで「このアプリで開く」を選ぶとタイプセレクター（テキスト/オーディオ/動画/画像）を表示し内蔵ビューアで開く',
  'de':'Bei unbekannten Formaten erscheint nach „Mit dieser App öffnen“ ein Typ-Wähler (Text/Audio/Video/Bild) und öffnet im integrierten Betrachter',
  'fr':'Pour les fichiers de format inconnu, « Ouvrir avec cette app » affiche un sélecteur de type (texte/audio/vidéo/image) puis ouvre dans la visionneuse intégrée',
  'es':'Para archivos de formato desconocido, «Abrir con esta aplicación» muestra un selector de tipo (texto/audio/vídeo/imagen) y abre con el visor integrado',
  'ru':'Для файлов неизвестного формата пункт «Открыть в этом приложении» показывает выбор типа (текст/аудио/видео/изображение) и открывает во встроенном просмотрщике',
  'ar':'للملفات ذات التنسيق غير المعروف، يعرض «فتح بهذا التطبيق» منتقي نوع (نص/صوت/فيديو/صورة) ثم يفتح بالعارض المدمج'},
 'changelog_v1130_opt_1': {
  'ko':'카테고리/브라우저 페이지의 카테고리·탐색 버튼을 하나로 통합, 가운데 탭으로 전환',
  'ja':'カテゴリ/ブラウザページの「カテゴリ」「ブラウズ」ボタンを一つに統合、中央タップで切替',
  'de':'Die Schaltflächen „Kategorien“ und „Durchsuchen“ sind vereint; Umschalten durch Tippen in der Mitte',
  'fr':'Les boutons « Catégories » et « Parcourir » sont fusionnés ; bascule par appui central',
  'es':'Los botones «Categorías» y «Examinar» se unifican; se alterna pulsando el centro',
  'ru':'Кнопки «Категории» и «Обзор» объединены; переключение нажатием по центру',
  'ar':'تم دمج زرّي «الفئات» و«تصفح»؛ التبديل بالنقر على الوسط'},
 'changelog_v1130_opt_2': {
  'ko':'이름 바꾸기 시 파일 이름 본문(확장자 제외) 자동 선택, 커서는 확장자 앞에 위치',
  'ja':'名前変更時にファイル名本体（拡張子除く）を自動選択、カーソルは拡張子の前に',
  'de':'Umbenennen wählt automatisch den Dateinamen (ohne Erweiterung); Cursor steht vor der Erweiterung',
  'fr':'Le renommage sélectionne automatiquement le nom du fichier (sans extension) ; le curseur se place avant l’extension',
  'es':'Al renombrar se selecciona automáticamente el nombre del archivo (sin extensión); el cursor se sitúa antes de la extensión',
  'ru':'При переименовании автоматически выделяется имя файла (без расширения); курсор ставится перед расширением',
  'ar':'عند إعادة التسمية يُحدد اسم الملف تلقائياً (بدون الامتداد) ويوضع المؤشر قبل الامتداد'},
 'changelog_v1130_opt_3': {
  'ko':'그리드/목록 보기 전환을 정렬 메뉴에 통합',
  'ja':'グリッド/リスト表示切替を並べ替えメニューに統合',
  'de':'Umschaltung Raster/Liste in das Sortiermenü integriert',
  'fr':'La bascule grille/liste est intégrée au menu de tri',
  'es':'La alternancia cuadrícula/lista se integra en el menú de ordenación',
  'ru':'Переключатель сетка/список интегрирован в меню сортировки',
  'ar':'دمج مفتاح تبديل الشبكة/القائمة في قائمة الترتيب'},
 'changelog_v1130_opt_4': {
  'ko':'카테고리별로 폴더/전체 항목 보기 모드를 독립 기억, 비디오/오디오는 폴더 보기 기본',
  'ja':'カテゴリごとに「フォルダ/すべての項目」表示モードを記憶、動画/オーディオはフォルダ表示が既定',
  'de':'Jede Kategorie merkt sich einzeln den Modus „Ordner/Alle Elemente“; Video/Audio standardmäßig Ordneransicht',
  'fr':'Chaque catégorie mémorise séparément le mode « Dossiers/Tous les éléments » ; vidéo/audio en affichage dossiers par défaut',
  'es':'Cada categoría recuerda por separado el modo «Carpetas/Todos los elementos»; vídeo/audio por defecto en vista de carpetas',
  'ru':'Каждая категория отдельно запоминает режим «Папки/Все элементы»; для видео/аудио по умолчанию — папки',
  'ar':'تتذكر كل فئة على حدة وضع عرض «المجلدات/كل العناصر»؛ الفيديو/الصوت افتراضياً بعرض المجلدات'},
 'changelog_v1130_opt_5': {
  'ko':'다운로드 카테고리 원격 백업 지원',
  'ja':'ダウンロードカテゴリのリモートバックアップ対応',
  'de':'Download-Kategorie unterstützt Remote-Backup',
  'fr':'La catégorie Téléchargements prend en charge la sauvegarde distante',
  'es':'La categoría Descargas admite copia de seguridad remota',
  'ru':'Категория «Загрузки» поддерживает удалённое резервное копирование',
  'ar':'فئة التنزيلات تدعم النسخ الاحتياطي البعيد'},
 'changelog_v1130_opt_6': {
  'ko':'원격 이미지/비디오 썸네일 온디맨드 다운로드 표시',
  'ja':'リモート画像/動画サムネイルをオンデマンドでダウンロード表示',
  'de':'Remote-Vorschaubilder für Bilder/Videos werden bei Bedarf geladen',
  'fr':'Miniatures distantes des images/vidéos téléchargées à la demande',
  'es':'Las miniaturas remotas de imágenes/vídeos se descargan a demanda',
  'ru':'Удалённые миниатюры изображений/видео загружаются по требованию',
  'ar':'تحميل الصور المصغرة البعيدة للصور/الفيديو عند الحاجة'},
 'changelog_v1130_opt_7': {
  'ko':'로컬 스캔에서 앱 캐시 디렉터리 제외, 원격 썸네일 열람 후 로컬 이미지 중복 수정',
  'ja':'ローカルスキャンでアプリキャッシュディレクトリを除外、リモートサムネイル表示後のローカル画像重複を修正',
  'de':'Lokaler Scan schließt App-Cache-Verzeichnisse aus; Duplikate lokaler Bilder nach Remote-Vorschaubildern behoben',
  'fr':'Le scan local exclut les répertoires de cache de l’app ; corrige la duplication d’images locales après l’affichage de miniatures distantes',
  'es':'El escaneo local excluye los directorios de caché de la app; corrige la duplicación de imágenes locales tras ver miniaturas remotas',
  'ru':'Локальное сканирование исключает каталоги кэша приложения; исправлено дублирование локальных изображений после просмотра удалённых миниатюр',
  'ar':'يستثني الفحص المحلي مجلدات ذاكرة التخزين المؤقت؛ إصلاح تكرار الصور المحلية بعد عرض الصور المصغرة البعيدة'},
 'changelog_v1130_opt_8': {
  'ko':'원격 파일 점 3개 메뉴와 길게 누르기 일괄 삭제/이름 바꾸기/복사/잘라내기/위치 찾기 동작',
  'ja':'リモートファイルの3点メニューと長押しの一括削除/名前変更/コピー/切り取り/場所特定が動作',
  'de':'3-Punkt- und Langdruck-Menü für Remote-Dateien: Massen-Löschen/Umbenennen/Kopieren/Ausschneiden/Standort funktional',
  'fr':'Menu 3 points et appui long des fichiers distants : suppression/renommage/copie/couper/localiser par lots opérationnels',
  'es':'Menú de tres puntos y pulsación larga de archivos remotos: eliminar/renombrar/copiar/cortar/localizar por lotes operativos',
  'ru':'Меню из трёх точек и долгое нажатие для удалённых файлов: массовое удаление/переименование/копирование/вырезание/поиск работают',
  'ar':'قائمة النقاط الثلاث والضغط الطويل للملفات البعيدة: الحذف/إعادة التسمية/النسخ/القص/تحديد الموقع بالجملة تعمل'},
 'changelog_v1130_opt_9': {
  'ko':'원격 폴더 하위 이동 시 디렉터리 구조 유지(DCIM/Pictures 등 최상위 디렉터리)',
  'ja':'リモートフォルダの階層移動でディレクトリ構造を維持（DCIM/Pictures等のトップディレクトリ）',
  'de':'Beim Navigieren in Remote-Ordnern bleibt die Verzeichnisstruktur erhalten (Top-Verzeichnisse wie DCIM/Pictures)',
  'fr':'La navigation dans les dossiers distants préserve la structure (répertoires racine comme DCIM/Pictures)',
  'es':'La navegación por carpetas remotas conserva la estructura de directorios (carpetas raíz como DCIM/Pictures)',
  'ru':'Навигация по удалённым папкам сохраняет структуру каталогов (корневые каталоги вроде DCIM/Pictures)',
  'ar':'التنقل في المجلدات البعيدة يحافظ على هيكل المجلدات (المجلدات الجذر مثل DCIM/Pictures)'},
 'changelog_v1130_fix_1': {
  'ko':'MIUI 저장소 권한 오분류로 시작 대화상자 무한 반복되던 문제 수정',
  'ja':'MIUIのストレージ権限誤判定で起動ダイアログがループする問題を修正',
  'de':'Behoben: MIUI-Speicherberechtigung falsch erkannt → Startdialog-Schleife',
  'fr':'Corrigé : mauvaise évaluation des autorisations de stockage MIUI provoquant une boucle de dialogue au démarrage',
  'es':'Corregido: la mala detección de permisos de almacenamiento de MIUI provocaba un bucle de diálogo al inicio',
  'ru':'Исправлено: ошибочная оценка прав доступа к хранилищу MIUI приводила к зацикливанию диалога при запуске',
  'ar':'إصلاح: سوء تقييم أذونات التخزين في MIUI كان يسبب حلقة نافذة عند بدء التشغيل'},
 'changelog_v1130_fix_2': {
  'ko':'카테고리 페이지에서 길게 누른 채 드래그 시 아이콘이 좌우 페이지로 전환되던 문제 수정',
  'ja':'カテゴリページでの長押しドラッグ中にアイコンが左右ページを誤切替する問題を修正',
  'de':'Behoben: Langes Ziehen auf der Kategorieseite löste versehentlich Seitenwechsel aus',
  'fr':'Corrigé : le glisser par appui long sur la page des catégories changeait accidentellement de page',
  'es':'Corregido: arrastrar con pulsación larga en la página de categorías cambiaba de página por accidente',
  'ru':'Исправлено: длительное перетаскивание на странице категорий ошибочно переключало страницы',
  'ar':'إصلاح: السحب بالضغط الطويل في صفحة الفئات كان يبدل الصفحات دون قصد'},
 'changelog_v1130_fix_3': {
  'ko':'이미지 카테고리에서 폴더별 하위 이동 후 스크린샷이 사라지던 문제 수정',
  'ja':'画像カテゴリで「フォルダ別」階層移動後にスクリーンショットが消える問題を修正',
  'de':'Behoben: Screenshots verschwanden nach „Nach Ordner“-Navigation in der Bildkategorie',
  'fr':'Corrigé : les captures d’écran disparaissaient après la navigation « Par dossier » dans la catégorie images',
  'es':'Corregido: las capturas de pantalla desaparecían tras navegar «Por carpetas» en la categoría de imágenes',
  'ru':'Исправлено: скриншоты исчезали после навигации «По папкам» в категории изображений',
  'ar':'إصلاح: اختفاء لقطات الشاشة بعد التنقل «حسب المجلدات» في فئة الصور'},
}

EXTRA = {
 'ar': {'log_music_lyrics_fullscreen_removed': 'إزالة لوحة كلمات الأغاني الكاملة من قائمة مشغل الموسيقى'},
}
# 部分翻译残留「三点」：整词替换
THREE_DOT = {'ko': '점 3개', 'ja': '3点'}
THREE_DOT_KEYS = ['ui_action_menu_subtitle', 'changelog_v1127_new_3']

ALL = {}
for d in (UI, CH):
    for k, langs in d.items():
        ALL.setdefault(k, {}).update(langs)

def esc_dart(v):
    return v.replace('\\', '\\\\').replace("'", "\\'")

def fix_arb(lang, mapping, threedot):
    path = os.path.join(DIR, f'app_{lang}.arb')
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        raw = f.read()
    n = 0
    for key, val in mapping.items():
        pat = re.compile(r'("' + re.escape(key) + r'":\s*")([^"]*)(")')
        m = pat.search(raw)
        if not m:
            print(f'  [ARB {lang}] MISS {key}')
            continue
        raw = pat.sub(lambda mm: mm.group(1) + val.replace('\\', '\\\\').replace('"', '\\"') + mm.group(3), raw, count=1)
        n += 1
    for key in THREE_DOT_KEYS:
        if key in mapping:
            continue
        pat = re.compile(r'("' + re.escape(key) + r'":\s*")([^"]*)(")')
        m = pat.search(raw)
        if m and '三点' in m.group(2):
            raw = pat.sub(lambda mm: mm.group(1) + mm.group(2).replace('三点', threedot) + mm.group(3), raw, count=1)
            n += 1
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(raw)
    json.load(io.open(path, encoding='utf-8'))  # validate
    return n

def fix_dart(lang, mapping, threedot):
    path = os.path.join(GEN, f'app_localizations_{lang}.dart')
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        raw = f.read()
    n = 0
    for key, val in mapping.items():
        pat = re.compile(r"(String get " + re.escape(key) + r" =>\s*')([^']*)(';)", re.S)
        m = pat.search(raw)
        if not m:
            print(f'  [DART {lang}] MISS {key}')
            continue
        raw = pat.sub(lambda mm: mm.group(1) + esc_dart(val) + mm.group(3), raw, count=1)
        n += 1
    for key in THREE_DOT_KEYS:
        if key in mapping:
            continue
        pat = re.compile(r"(String get " + re.escape(key) + r" =>\s*')([^']*)(';)", re.S)
        m = pat.search(raw)
        if m and '三点' in m.group(2):
            raw = pat.sub(lambda mm: mm.group(1) + mm.group(2).replace('三点', threedot) + mm.group(3), raw, count=1)
            n += 1
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(raw)
    return n

total_a = total_d = 0
for lang in ['ko', 'ja', 'de', 'fr', 'es', 'ru', 'ar']:
    mapping = {k: v[lang] for k, v in ALL.items() if lang in v}
    if lang in EXTRA:
        mapping.update(EXTRA[lang])
    a = fix_arb(lang, mapping, THREE_DOT.get(lang, ''))
    d = fix_dart(lang, mapping, THREE_DOT.get(lang, ''))
    total_a += a; total_d += d
    print(f'{lang}: arb+{a} dart+{d}')

for key, val in UI['ui_category_settings_title'].items():
    if key == 'en':
        pass
en_map = {k: v['en'] for k, v in UI.items() if 'en' in v}
a = fix_arb('en', en_map, '')
d = fix_dart('en', en_map, '')
print(f'en: arb+{a} dart+{d}')

print(f'TOTAL arb={total_a + a} dart={total_d + d}')
