#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""应用图标「添加到桌面」双通道 l10n 补齐（2026-09-16）：
新增 10 个 key（设置—外观与主题—应用图标：选图后弹出的 快捷方式 / 桌面小组件 / 更换图片
面板，以及取消/不受支持的结果提示）→ 插入 10 ARB + 基类 dart + 9 locale dart。

铁律（同 add_crypt_result_l10n.py）：
- app_*.arb 为 CRLF，generated/*.dart 为 LF → 全程二进制读写；
- 按锚点插入，绝不重跑 gen-l10n（会覆盖手工合并的 L10nZh/L10nZhTw）；
- zh.dart 双类：第一处 L10nZh 用 zh 值，第二处 L10nZhTw 用 zh_TW 值；
- 本批 key 全部无占位符，故 PLACEHOLDER_PARAMS 为空。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

# ───────────────────────── 新 key ─────────────────────────
PLACEHOLDER_PARAMS = {}

NEW_KEYS = [
    'app_icon_add_title',
    'app_icon_add_body',
    'app_icon_add_shortcut',
    'app_icon_add_shortcut_desc',
    'app_icon_add_widget',
    'app_icon_add_widget_desc',
    'app_icon_add_change_image',
    'app_icon_add_change_image_desc',
    'app_icon_add_cancelled',
    'app_icon_add_unsupported',
]

EN_NEW = {
    'app_icon_add_title': 'Add to home screen',
    'app_icon_add_body': 'Android does not allow replacing the app icon with an external image. Use one of the options below to place your custom image on the home screen:',
    'app_icon_add_shortcut': 'Shortcut',
    'app_icon_add_shortcut_desc': 'Adds a launch icon using your custom image',
    'app_icon_add_widget': 'Home screen widget',
    'app_icon_add_widget_desc': 'A 1×1 widget, works with every launcher',
    'app_icon_add_change_image': 'Change image',
    'app_icon_add_change_image_desc': 'Pick another image to use as the icon',
    'app_icon_add_cancelled': 'Not added: cancelled',
    'app_icon_add_unsupported': 'Your launcher does not support adding automatically — long-press the home screen to add it manually',
}

ZH_NEW = {
    'app_icon_add_title': '添加到桌面',
    'app_icon_add_body': 'Android 不允许用外部图片直接替换应用主图标。可用下面的方式把自定义图片放到桌面：',
    'app_icon_add_shortcut': '快捷方式',
    'app_icon_add_shortcut_desc': '在桌面新增一个带自定义图片的启动图标',
    'app_icon_add_widget': '桌面小组件',
    'app_icon_add_widget_desc': '1×1 小组件，兼容所有启动器',
    'app_icon_add_change_image': '更换图片',
    'app_icon_add_change_image_desc': '重新选择一张图片作为图标',
    'app_icon_add_cancelled': '未添加：操作已取消',
    'app_icon_add_unsupported': '当前启动器不支持自动添加，请长按桌面手动添加',
}

ZH_TW_NEW = {
    'app_icon_add_title': '新增到桌面',
    'app_icon_add_body': 'Android 不允許用外部圖片直接替換應用程式主圖示。可用以下方式把自訂圖片放到桌面：',
    'app_icon_add_shortcut': '捷徑',
    'app_icon_add_shortcut_desc': '在桌面新增一個帶自訂圖片的啟動圖示',
    'app_icon_add_widget': '桌面小工具',
    'app_icon_add_widget_desc': '1×1 小工具，相容所有啟動器',
    'app_icon_add_change_image': '更換圖片',
    'app_icon_add_change_image_desc': '重新選擇一張圖片作為圖示',
    'app_icon_add_cancelled': '未新增：操作已取消',
    'app_icon_add_unsupported': '目前啟動器不支援自動新增，請長按桌面手動新增',
}

JA_NEW = {
    'app_icon_add_title': 'ホーム画面に追加',
    'app_icon_add_body': 'Android では外部画像でアプリのメインアイコンを直接置き換えることはできません。以下の方法でカスタム画像をホーム画面に配置できます：',
    'app_icon_add_shortcut': 'ショートカット',
    'app_icon_add_shortcut_desc': 'カスタム画像を使った起動アイコンをホーム画面に追加します',
    'app_icon_add_widget': 'ホーム画面ウィジェット',
    'app_icon_add_widget_desc': '1×1 ウィジェット、すべてのランチャーに対応',
    'app_icon_add_change_image': '画像を変更',
    'app_icon_add_change_image_desc': 'アイコンに使う画像を選び直す',
    'app_icon_add_cancelled': '追加されませんでした：キャンセルされました',
    'app_icon_add_unsupported': '現在のランチャーは自動追加に対応していません。ホーム画面を長押しして手動で追加してください',
}

KO_NEW = {
    'app_icon_add_title': '홈 화면에 추가',
    'app_icon_add_body': 'Android는 외부 이미지로 앱 기본 아이콘을 직접 교체할 수 없습니다. 아래 방법으로 사용자 이미지를 홈 화면에 배치할 수 있습니다:',
    'app_icon_add_shortcut': '바로가기',
    'app_icon_add_shortcut_desc': '사용자 이미지를 사용한 실행 아이콘을 홈 화면에 추가합니다',
    'app_icon_add_widget': '홈 화면 위젯',
    'app_icon_add_widget_desc': '1×1 위젯, 모든 런처 지원',
    'app_icon_add_change_image': '이미지 변경',
    'app_icon_add_change_image_desc': '아이콘으로 사용할 이미지를 다시 선택',
    'app_icon_add_cancelled': '추가되지 않음: 취소되었습니다',
    'app_icon_add_unsupported': '현재 런처는 자동 추가를 지원하지 않습니다. 홈 화면을 길게 눌러 직접 추가하세요',
}

DE_NEW = {
    'app_icon_add_title': 'Zum Startbildschirm hinzufügen',
    'app_icon_add_body': 'Android erlaubt es nicht, das App-Symbol durch ein externes Bild zu ersetzen. Nutze eine der folgenden Optionen, um dein eigenes Bild auf den Startbildschirm zu legen:',
    'app_icon_add_shortcut': 'Verknüpfung',
    'app_icon_add_shortcut_desc': 'Fügt ein Start-Symbol mit deinem eigenen Bild hinzu',
    'app_icon_add_widget': 'Startbildschirm-Widget',
    'app_icon_add_widget_desc': 'Ein 1×1-Widget, funktioniert mit jedem Launcher',
    'app_icon_add_change_image': 'Bild ändern',
    'app_icon_add_change_image_desc': 'Wähle ein anderes Bild als Symbol',
    'app_icon_add_cancelled': 'Nicht hinzugefügt: abgebrochen',
    'app_icon_add_unsupported': 'Dein Launcher unterstützt das automatische Hinzufügen nicht – halte den Startbildschirm gedrückt, um es manuell hinzuzufügen',
}

ES_NEW = {
    'app_icon_add_title': 'Añadir a la pantalla de inicio',
    'app_icon_add_body': 'Android no permite sustituir el icono de la app por una imagen externa. Usa una de las opciones siguientes para poner tu imagen en la pantalla de inicio:',
    'app_icon_add_shortcut': 'Acceso directo',
    'app_icon_add_shortcut_desc': 'Añade un icono de inicio con tu imagen personalizada',
    'app_icon_add_widget': 'Widget de pantalla de inicio',
    'app_icon_add_widget_desc': 'Un widget 1×1, compatible con todos los lanzadores',
    'app_icon_add_change_image': 'Cambiar imagen',
    'app_icon_add_change_image_desc': 'Elige otra imagen como icono',
    'app_icon_add_cancelled': 'No añadido: cancelado',
    'app_icon_add_unsupported': 'Tu lanzador no admite añadirlo automáticamente; mantén pulsada la pantalla de inicio para añadirlo manualmente',
}

FR_NEW = {
    'app_icon_add_title': "Ajouter à l'écran d'accueil",
    'app_icon_add_body': "Android n'autorise pas le remplacement de l'icône de l'application par une image externe. Utilisez l'une des options ci-dessous pour placer votre image sur l'écran d'accueil :",
    'app_icon_add_shortcut': 'Raccourci',
    'app_icon_add_shortcut_desc': 'Ajoute une icône de lancement avec votre image',
    'app_icon_add_widget': "Widget d'écran d'accueil",
    'app_icon_add_widget_desc': 'Un widget 1×1, compatible avec tous les lanceurs',
    'app_icon_add_change_image': "Changer d'image",
    'app_icon_add_change_image_desc': "Choisir une autre image comme icône",
    'app_icon_add_cancelled': 'Non ajouté : annulé',
    'app_icon_add_unsupported': "Votre lanceur ne prend pas en charge l'ajout automatique — appuyez longuement sur l'écran d'accueil pour l'ajouter manuellement",
}

RU_NEW = {
    'app_icon_add_title': 'Добавить на главный экран',
    'app_icon_add_body': 'Android не позволяет заменить значок приложения внешним изображением. Используйте один из способов ниже, чтобы разместить своё изображение на главном экране:',
    'app_icon_add_shortcut': 'Ярлык',
    'app_icon_add_shortcut_desc': 'Добавляет значок запуска с вашим изображением',
    'app_icon_add_widget': 'Виджет главного экрана',
    'app_icon_add_widget_desc': 'Виджет 1×1, работает с любым лаунчером',
    'app_icon_add_change_image': 'Изменить изображение',
    'app_icon_add_change_image_desc': 'Выбрать другое изображение для значка',
    'app_icon_add_cancelled': 'Не добавлено: отменено',
    'app_icon_add_unsupported': 'Ваш лаунчер не поддерживает автоматическое добавление — удерживайте главный экран, чтобы добавить вручную',
}

AR_NEW = {
    'app_icon_add_title': 'إضافة إلى الشاشة الرئيسية',
    'app_icon_add_body': '‏لا يسمح Android باستبدال أيقونة التطبيق بصورة خارجية. استخدم أحد الخيارات التالية لوضع صورتك المخصصة على الشاشة الرئيسية:',
    'app_icon_add_shortcut': 'اختصار',
    'app_icon_add_shortcut_desc': 'يضيف أيقونة تشغيل بصورتك المخصصة',
    'app_icon_add_widget': 'أداة الشاشة الرئيسية',
    'app_icon_add_widget_desc': '‏أداة بحجم 1×1، متوافقة مع جميع المشغّلات',
    'app_icon_add_change_image': 'تغيير الصورة',
    'app_icon_add_change_image_desc': 'اختيار صورة أخرى لتكون الأيقونة',
    'app_icon_add_cancelled': 'لم تتم الإضافة: تم الإلغاء',
    'app_icon_add_unsupported': '‏لا يدعم مشغّل الشاشة الإضافة التلقائية — اضغط مطولاً على الشاشة الرئيسية للإضافة يدويًا',
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
        lines.append('    "description": "app icon: %s"' % key)
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
