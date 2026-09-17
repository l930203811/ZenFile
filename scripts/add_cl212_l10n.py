#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.1.2 更新日志 l10n 补齐（2026-09-17）：
新增 9 个 key（cl212_features / cl212_feat_1 / cl212_ui / cl212_ui_1..2 /
cl212_fixes / cl212_fix_1..3）插入 10 ARB + 基类 dart + 9 locale dart（zh 双类）。

铁律（同 add_cl211_l10n.py / add_apkopen_l10n.py）：
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

NEW_KEYS = ['cl212_features', 'cl212_feat_1', 'cl212_ui', 'cl212_ui_1',
            'cl212_ui_2', 'cl212_fixes', 'cl212_fix_1', 'cl212_fix_2', 'cl212_fix_3']

EN_NEW = {
    'cl212_features': 'New',
    'cl212_feat_1': 'Switchable APK open method: Settings -> APK Install Settings gains an "APK open method" option to choose between the built-in installer and the system chooser. With the system chooser, ZenFile no longer intercepts APK opens, so Shizuku-based third-party installers such as InstallerX and InstallWithOptions can take over - no more long-pressing each file to pick "Open with" when installing in bulk.',
    'cl212_ui': 'UI & Interaction',
    'cl212_ui_1': 'Wider "Size & Spacing" range: the card spacing slider now goes down to -50% (previously 40% minimum). At 0% card borders touch; negative values overlap adjacent card borders into a single line. The default is now 0% (new installs start flush; existing settings are kept).',
    'cl212_ui_2': 'Custom shortcut dialog: "Icon shape" and "Columns per row" are now dropdowns instead of side-by-side buttons, for a more compact layout.',
    'cl212_fixes': 'Fixes',
    'cl212_fix_1': 'Fingerprint unlock now defaults to off: after install, fingerprint unlock under Settings -> Security is off until you turn it on, so biometric unlock is no longer enabled automatically.',
    'cl212_fix_2': 'Fixed being unable to reconfigure the APK security-scan API key: previously, once a key was saved, turning the switch off then on would not reopen the config page. The config page now opens both from the switch and by tapping the card.',
    'cl212_fix_3': 'Fixed "permission denied" from silent install even with Shizuku authorized: the Shizuku path now installs through a system PackageInstaller session instead of the shell install command that some systems block; the root path no longer passes an unnecessary downgrade flag.',
}
ZH_NEW = {
    'cl212_features': '新增功能',
    'cl212_feat_1': 'APK 打开方式可切换：设置 → APK 安装设置新增「APK 打开方式」，可在「内置安装器」与「系统选择器」之间切换。选择系统选择器后，ZenFile 不再强制拦截 APK 打开，InstallerX、InstallWithOptions 等第三方安装器可正常接管，批量安装无需再长按逐个选择「打开方式」。',
    'cl212_ui': '界面与交互',
    'cl212_ui_1': '「大小和间距」可调范围扩大：卡片间距滑块下限由 40% 放宽到 -50%，0% 时卡片边框紧贴、负值可让相邻卡片边框重叠成一条线；同时默认值改为 0%（新用户首次启动即贴边，已调整过的用户保持原值）。',
    'cl212_ui_2': '自定义快捷方式弹窗：「图标形状」与「每行显示」由并排按钮改为下拉选择，布局更紧凑统一。',
    'cl212_fixes': '问题修复',
    'cl212_fix_1': '指纹解锁改为默认关闭：安装后「设置 → 安全设置」中的指纹解锁默认处于关闭状态，需主动开启，避免新装或升级后自动启用生物识别解锁。',
    'cl212_fix_2': '修复 APK 安全扫描配置好 API Key 后、关闭再打开开关无法再次进入配置页重新配置 Key 的问题；现在开关打开与点击卡片均可进入配置页修改 Key。',
    'cl212_fix_3': '修复「静默安装」在已授权 Shizuku 的情况下仍提示「权限不足」无法安装的问题：Shizuku 路径改用系统 PackageInstaller 会话安装，不再依赖被部分系统禁止的 shell 安装命令。',
}
ZH_TW_NEW = {
    'cl212_features': '新增功能',
    'cl212_feat_1': 'APK 開啟方式可切換：設定 → APK 安裝設定新增「APK 開啟方式」，可在「內建安裝器」與「系統選擇器」之間切換。選擇系統選擇器後，ZenFile 不再強制攔截 APK 開啟，InstallerX、InstallWithOptions 等第三方安裝器可正常接管，批次安裝無需再長按逐個選擇「開啟方式」。',
    'cl212_ui': '介面與互動',
    'cl212_ui_1': '「大小與間距」可調範圍擴大：卡片間距滑桿下限由 40% 放寬到 -50%，0% 時卡片邊框緊貼、負值可讓相鄰卡片邊框重疊成一條線；同時預設值改為 0%（新安裝首次啟動即貼邊，已調整過的使用者保持原值）。',
    'cl212_ui_2': '自訂捷徑彈窗：「圖示形狀」與「每行顯示」由並排按鈕改為下拉選擇，版面更緊湊統一。',
    'cl212_fixes': '問題修復',
    'cl212_fix_1': '指紋解鎖改為預設關閉：安裝後「設定 → 安全設定」中的指紋解鎖預設處於關閉狀態，需主動開啟，避免新安裝或升級後自動啟用生物辨識解鎖。',
    'cl212_fix_2': '修復 APK 安全掃描設定好 API Key 後、關閉再打開開關無法再次進入設定頁重新設定的問題；現在開關打開與點擊卡片均可進入設定頁修改 Key。',
    'cl212_fix_3': '修復「靜默安裝」在已授權 Shizuku 的情況下仍提示「權限不足」無法安裝的問題：Shizuku 路徑改為系統 PackageInstaller 會話安裝，不再依賴部分系統禁止的 shell 安裝指令。',
}
JA_NEW = {
    'cl212_features': '新機能',
    'cl212_feat_1': 'APK の開き方を切り替え可能に：設定 → APK インストール設定に「APK の開き方」が追加され、内蔵インストーラーとシステムの選択画面を切り替えられます。システムの選択画面を選ぶと、ZenFile は APK の開き方を強制しなくなるため、InstallerX や InstallWithOptions などのサードパーティ製インストーラーが正常に処理でき、一括インストール時に毎回「開き方」を長押しして選ぶ必要がなくなります。',
    'cl212_ui': 'UI と操作',
    'cl212_ui_1': '「サイズと間隔」の調整範囲を拡大：カード間隔スライダーの下限を 40% から -50% に緩和しました。0% でカードの境界線が詰まり、負の値で隣接するカードの境界線が 1 本の線に重なります。また既定値を 0% に変更しました（新規インストールは最初から詰まり、既に設定した方は従来の値を保持）。',
    'cl212_ui_2': 'カスタムショートカットのダイアログ：「アイコンの形」と「1 行あたりの列数」が並べられたボタンからドロップダウンに変わり、レイアウトがよりコンパクトになりました。',
    'cl212_fixes': '不具合修正',
    'cl212_fix_1': '指紋ロックを既定でオフに：インストール後、設定 → セキュリティの指紋ロックは既定でオフになり、自分でオンにするまで生物認証ロックが自動で有効にならなくなりました。',
    'cl212_fix_2': 'APK セキュリティスキャンの API キーを再設定できない問題を修正：以前はキーを保存すると、スイッチをオフにしてからオンにしても設定画面が再表示されませんでした。現在はスイッチとカードのタップの両方から設定画面が開きます。',
    'cl212_fix_3': 'Shizuku を許可しても「権限がありません」と表示されてサイレントインストールできない問題を修正：Shizuku 経路はシステムの PackageInstaller セッションを使ってインストールするようになり、一部のシステムで禁止されている shell のインストールコマンドに依存しなくなりました。',
}
KO_NEW = {
    'cl212_features': '새로운 기능',
    'cl212_feat_1': 'APK 열기 방식 전환 가능: 설정 → APK 설치 설정에 "APK 열기 방식"이 추가되어 내장 설치기와 시스템 선택기를 전환할 수 있습니다. 시스템 선택기를 사용하면 ZenFile이 APK 열기를 강제로 가로채지 않으므로 InstallerX, InstallWithOptions 같은 서드파티 설치기가 정상적으로 처리할 수 있고, 일괄 설치 시 매번 길게 눌러 "열기 방식"을 고를 필요가 없습니다.',
    'cl212_ui': 'UI 및 상호작용',
    'cl212_ui_1': '"크기 및 간격" 조정 범위 확대: 카드 간격 슬라이더 하한을 40%에서 -50%로 완화했습니다. 0%에서는 카드 테두리가 붙고, 음수값은 인접 카드 테두리가 한 줄로 겹칩니다. 또한 기본값을 0%로 변경했습니다(새 설치는 처음부터 붙고, 이미 설정한 경우 기존 값 유지).',
    'cl212_ui_2': '사용자 지정 바로가기 대화상자: "아이콘 모양"과 "한 줄당 열 수"가 나란히 배치된 버튼에서 드롭다운으로 바뀌어 레이아웃이 더 컴팩트해졌습니다.',
    'cl212_fixes': '버그 수정',
    'cl212_fix_1': '지문 잠금 기본값을 끄기로 변경: 설치 후 설정 → 보안의 지문 잠금은 기본적으로 꺼져 있으며 직접 켜야 하므로, 새 설치나 업데이트 후 생체 인식 잠금이 자동으로 켜지지 않습니다.',
    'cl212_fix_2': 'APK 보안 검사 API 키를 다시 설정할 수 없던 문제 수정: 이전에는 키를 저장한 후 스위치를 끄고 다시 켜도 설정 화면이 다시 열리지 않았습니다. 이제 스위치와 카드 탭 모두에서 설정 화면이 열립니다.',
    'cl212_fix_3': 'Shizuku 권한을 부여했음에도 "권한 부족"이 표시되어 무음 설치가 안 되던 문제 수정: Shizuku 경로는 시스템 PackageInstaller 세션으로 설치하도록 변경되어, 일부 시스템에서 금지된 shell 설치 명령에 의존하지 않습니다.',
}
RU_NEW = {
    'cl212_features': 'Новое',
    'cl212_feat_1': 'Переключаемый способ открытия APK: в Настройки → Настройки установки APK добавлен «Способ открытия APK» для выбора между встроенным установщиком и системным выборщиком. При выборе системного выборщика ZenFile больше не перехватывает открытие APK, поэтому сторонние установщики вроде InstallerX и InstallWithOptions могут их обрабатывать — при пакетной установке больше не нужно долго нажимать и выбирать «Открыть с помощью» для каждого файла.',
    'cl212_ui': 'Интерфейс и взаимодействие',
    'cl212_ui_1': 'Шире диапазон «Размер и интервал»: нижняя граница ползунка интервала между карточками расширена с 40% до -50%. При 0% границы карточек соприкасаются, а при отрицательных значениях границы соседних карточек накладываются в одну линию. Значение по умолчанию также изменено на 0% (новые установки сразу прижаты; у уже настроенных пользователей сохраняется прежнее значение).',
    'cl212_ui_2': 'Диалог пользовательских ярлыков: «Форма значка» и «Столбцов в строке» теперь выбираются из выпадающего списка вместо кнопок бок о бок, что делает раскладку компактнее.',
    'cl212_fixes': 'Исправления',
    'cl212_fix_1': 'Разблокировка по отпечатку теперь выключена по умолчанию: после установки разблокировка по отпечатку в Настройки → Безопасность выключена, пока вы не включите её — биометрическая разблокировка больше не включается автоматически.',
    'cl212_fix_2': 'Исправлена невозможность повторно настроить API-ключ проверки APK: раньше после сохранения ключа выключение и повторное включение переключателя не открывало страницу настроек. Теперь страница открывается и по переключателю, и по нажатию на карточку.',
    'cl212_fix_3': 'Исправлена ошибка «недостаточно прав» при тихой установке даже при авторизованном Shizuku: путь Shizuku теперь устанавливает через системную сессию PackageInstaller вместо команды shell, которую некоторые системы запрещают; путь root больше не передаёт лишний флаг понижения версии.',
}
FR_NEW = {
    'cl212_features': 'Nouveautés',
    'cl212_feat_1': "Méthode d'ouverture des APK commutables : les Paramètres → Paramètres d'installation APK ajoutent une « Méthode d'ouverture des APK » pour choisir entre l'installateur intégré et le sélecteur système. Avec le sélecteur système, ZenFile n'intercepte plus l'ouverture des APK, donc des installateurs tiers comme InstallerX et InstallWithOptions peuvent les prendre en charge — plus besoin d'appuyer longuement sur chaque fichier pour choisir « Ouvrir avec » lors des installations par lot.",
    'cl212_ui': 'Interface et interaction',
    'cl212_ui_1': "Plage « Taille et espacement » élargie : la limite basse du curseur d'espacement entre cartes passe de 40 % à -50 % ; à 0 % les bordures des cartes se touchent, et les valeurs négatives font chevaucher les bordures des cartes adjacentes en une seule ligne. La valeur par défaut passe aussi à 0 % (les nouvelles installations sont d'emblée collées ; les réglages existants sont conservés).",
    'cl212_ui_2': "Boîte de dialogue des raccourcis personnalisés : « Forme de l'icône » et « Colonnes par ligne » sont désormais des listes déroulantes au lieu de boutons côte à côte, pour une disposition plus compacte.",
    'cl212_fixes': 'Corrections',
    'cl212_fix_1': "Le déverrouillage par empreinte est maintenant désactivé par défaut : après l'installation, le déverrouillage par empreinte dans Paramètres → Sécurité reste désactivé jusqu'à ce que vous l'activiez, le déverrouillage biométrique n'étant plus activé automatiquement.",
    'cl212_fix_2': "Correction de l'impossibilité de reconfigurer la clé API de l'analyse de sécurité APK : auparavant, une fois la clé enregistrée, désactiver puis réactiver le commutateur ne rouvrait pas la page de configuration. La page s'ouvre désormais au niveau du commutateur et en appuyant sur la carte.",
    'cl212_fix_3': "Correction de l'erreur « permission refusée » lors de l'installation silencieuse même avec Shizuku autorisé : le chemin Shizuku installe désormais via une session PackageInstaller système au lieu de la commande shell interdite sur certains systèmes ; le chemin root ne passe plus de drapeau de rétrogradation inutile.",
}
ES_NEW = {
    'cl212_features': 'Novedades',
    'cl212_feat_1': 'Método de apertura de APK conmutable: en Ajustes → Ajustes de instalación de APK se añade «Método de apertura de APK» para elegir entre el instalador integrado y el selector del sistema. Con el selector del sistema, ZenFile ya no intercepta la apertura de APK, por lo que instaladores de terceros como InstallerX e InstallWithOptions pueden gestionarlos: ya no hay que pulsar prolongadamente cada archivo para elegir «Abrir con» al instalar por lotes.',
    'cl212_ui': 'Interfaz e interacción',
    'cl212_ui_1': 'Rango de «Tamaño y espaciado» ampliado: el límite inferior del control de espaciado entre tarjetas pasa de 40 % a -50 %; al 0 % los bordes de las tarjetas se tocan, y los valores negativos hacen que los bordes de tarjetas adyacentes se solapen en una sola línea. El valor predeterminado también cambia a 0 % (las nuevas instalaciones quedan pegadas; los ajustes existentes se conservan).',
    'cl212_ui_2': 'Diálogo de atajos personalizados: «Forma del icono» y «Columnas por fila» son ahora listas desplegables en lugar de botones uno al lado del otro, con un diseño más compacto.',
    'cl212_fixes': 'Correcciones',
    'cl212_fix_1': 'El desbloqueo por huella ahora está desactivado por defecto: tras la instalación, el desbloqueo por huella en Ajustes → Seguridad permanece desactivado hasta que lo actives, por lo que el desbloqueo biométrico ya no se activa automáticamente.',
    'cl212_fix_2': 'Corregido que no se podía reconfigurar la clave de API del análisis de seguridad APK: antes, una vez guardada la clave, desactivar y volver a activar el interruptor no reabría la página de configuración. Ahora la página se abre tanto desde el interruptor como tocando la tarjeta.',
    'cl212_fix_3': 'Corregido el error «permiso denegado» en la instalación silenciosa incluso con Shizuku autorizado: la ruta Shizuku ahora instala mediante una sesión de PackageInstaller del sistema en lugar del comando shell que algunos sistemas bloquean; la ruta root ya no usa una bandera de downgrade innecesaria.',
}
DE_NEW = {
    'cl212_features': 'Neu',
    'cl212_feat_1': 'Umschaltbare APK-Öffnungsart: Unter Einstellungen → APK-Installationsoptionen gibt es neu „APK-Öffnen“ zum Wechseln zwischen dem eingebauten Installer und dem Systemauswähler. Mit dem Systemauswähler fängt ZenFile das Öffnen von APK nicht mehr ab, sodass Drittanbieter-Installer wie InstallerX und InstallWithOptions sie übernehmen können — beim Masseninstallieren muss nicht mehr lange auf jede Datei gedrückt werden, um „Öffnen mit“ zu wählen.',
    'cl212_ui': 'Oberfläche & Interaktion',
    'cl212_ui_1': 'Weiterer Bereich „Größe & Abstand“: die untere Grenze des Abstandsreglers zwischen Karten wurde von 40 % auf -50 % gesenkt; bei 0 % berühren sich die Kartenränder, und negative Werte lassen angrenzende Kartenränder zu einer Linie verschmelzen. Der Standardwert ist ebenfalls 0 % (neue Installationen sind direkt bündig; bestehende Einstellungen bleiben erhalten).',
    'cl212_ui_2': 'Dialog für benutzerdefinierte Verknüpfungen: „Symbolform“ und „Spalten pro Zeile“ sind nun Dropdowns statt nebeneinanderliegender Buttons, was das Layout kompakter macht.',
    'cl212_fixes': 'Fehlerbehebungen',
    'cl212_fix_1': 'Entsperren per Fingerabdruck ist jetzt standardmäßig aus: nach der Installation bleibt die Fingerabdruck-Entsperrung unter Einstellungen → Sicherheit aus, bis du sie aktivierst — die biometrische Entsperrung wird nicht mehr automatisch aktiviert.',
    'cl212_fix_2': 'Behoben, dass sich der API-Schlüssel der APK-Sicherheitsprüfung nicht neu konfigurieren ließ: früher öffnete das Aus- und Wiedereinschalten des Schalters nach dem Speichern des Schlüssels die Konfigurationsseite nicht erneut. Sie öffnet sich nun sowohl über den Schalter als auch durch Tippen auf die Karte.',
    'cl212_fix_3': 'Behoben „Zugriff verweigert“ bei stiller Installation trotz autorisiertem Shizuku: der Shizuku-Pfad installiert nun über eine System-PackageInstaller-Sitzung statt dem auf manchen Systemen gesperrten Shell-Befehl; der Root-Pfad übergibt kein unnötiges Downgrade-Flag mehr.',
}
AR_NEW = {
    'cl212_features': 'ميزات جديدة',
    'cl212_feat_1': 'طريقة فتح APK قابلة للتبديل: الإعدادات ← إعدادات تثبيت APK تضيف «طريقة فتح APK» للاختيار بين المثبّت المدمج ومنتقي النظام. عند استخدام منتقي النظام، لا يعترض ZenFile فتح ملفات APK، ما يتيح لأدوات تثبيت خارجية مثل InstallerX وInstallWithOptions معالجتها — دون الحاجة للضغط مطولاً على كل ملف لاختيار «فتح باستخدام» عند التثبيت بالجملة.',
    'cl212_ui': 'الواجهة والتفاعل',
    'cl212_ui_1': 'نطاق أوسع لـ «الحجم والمسافات»: خُفّض الحد الأدنى لمنزلق المسافة بين البطاقات من 40% إلى -50%؛ عند 0% تلتصق حدود البطاقات، والقيم السالبة تجعل حدود البطاقات المتجاورة تتداخل في خط واحد. كما أصبحت القيمة الافتراضية 0% (التثبيتات الجديدة متلاصقة من البداية؛ وتبقى الإعدادات الحالية كما هي).',
    'cl212_ui_2': 'مربع حوار الاختصارات المخصصة: أصبح «شكل الأيقونة» و«الأعمدة لكل صف» قوائم منسدلة بدلاً من أزرار متجاورة، لتصميم أكثر إحكاماً.',
    'cl212_fixes': 'إصلاحات',
    'cl212_fix_1': 'أصبح فتح بصمة الإصبع معطلاً افتراضياً: بعد التثبيت يبقى فتح البصمة في الإعدادات ← الأمان معطلاً حتى تقوم بتفعيله، فلا يُفعّل فتح البصمة تلقائياً بعد التثبيت أو الترقية.',
    'cl212_fix_2': 'إصلاح عدم إمكانية إعادة ضبط مفتاح API لفحص أمان APK: سابقاً، بعد حفظ المفتاح، كان إطفاء المفتاح وتشغيله مجدداً لا يفتح صفحة الإعدادات. الآن تُفتح الصفحة من المفتاح ومن النقر على البطاقة.',
    'cl212_fix_3': 'إصلاح خطأ «صلاحية غير كافية» في التثبيت الصامت رغم السماح بـ Shizuku: مسار Shizuku يثبّت الآن عبر جلسة PackageInstaller للنظام بدلاً من أمر shell المحظور على بعض الأنظمة؛ ولا يمرّ مسار root بعلامة تخفيض إصدار غير ضرورية.',
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
    anchor = '"@cl211_fix_7"'
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
        lines.append('    "description": "v2.1.2 changelog: %s"' % key)
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
    anchor = '  String get cl211_fix_7;'
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
    anchor = "  String get cl211_fixes =>"
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
        # 定位 getter 的真正结束（'），避免值内含 ASCII ';'（如 de/en 的 cl211_fix_7）时插入到字符串中间。
        # 结束标志是 '; 且 ' 前面不是转义反斜杠（排除值内的 \' + ;）。
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
