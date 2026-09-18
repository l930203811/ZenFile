#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2.1.3 更新日志 l10n 补齐（第 2 批，2026-09-19）：
新增 5 个 key（cl213_fixes / cl213_feat_2 / cl213_fix_1..3）插入 10 ARB + 基类 dart + 9 locale dart（zh 双类）；
并把已有的 cl213_features 小节标题改写为更宽的「远程浏览与错误提示」（10 语言）。
内容来源：WORKLOG 中「远程文件打开方式持久化 + 远程图片左右滑动浏览修复」（Doubao）
与「远程客户端错误提示本地化 / l10n 中文占位修复 / zh_TW 简转繁」（WorkBuddy）。
铁律：ARB=CRLF、generated=LF，二进制读写；按锚点插入；绝不重跑 gen-l10n。
"""
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

PLACEHOLDER_PARAMS = {}

NEW_KEYS = ['cl213_fixes', 'cl213_feat_2', 'cl213_fix_1', 'cl213_fix_2', 'cl213_fix_3']

# 更新已有小节标题
TITLE = {
 'en': 'Remote browsing & error messages',
 'zh': '远程浏览与错误提示',
 'zh_TW': '遠端瀏覽與錯誤提示',
 'ja': 'リモート閲覧とエラー表示',
 'ko': '원격 탐색 및 오류 표시',
 'ru': 'Удалённый просмотр и сообщения об ошибках',
 'fr': 'Navigation distante et messages d’erreur',
 'es': 'Exploración remota y mensajes de error',
 'de': 'Remote-Browsing und Fehlermeldungen',
 'ar': 'التصفح عن بُعد ورسائل الخطأ',
}

FIXES = {
 'en': 'Bug fixes', 'zh': '问题修复', 'zh_TW': '問題修復', 'ja': '不具合の修正',
 'ko': '버그 수정', 'ru': 'Исправления', 'fr': 'Corrections de bugs',
 'es': 'Corrección de errores', 'de': 'Fehlerbehebungen', 'ar': 'إصلاحات',
}

FEAT2 = {
 'en': 'Remote “always open with” choice is now remembered: once you choose to always open remote files with this app or an external app, files of the same type open directly without asking again.',
 'zh': '远程文件「打开方式」可持久化：选择「始终用本应用 / 外部应用打开」后，同类型文件直接打开，不再重复弹窗询问。',
 'zh_TW': '遠端檔案「開啟方式」可持久化：選擇「一律使用本應用程式 / 外部應用程式開啟」後，同類型檔案直接開啟，不再重複跳出視窗詢問。',
 'ja': 'リモートファイルの「開き方」が記憶されます：「常にこのアプリ / 外部アプリで開く」を選ぶと、同じ種類のファイルは確認なしで直接開きます。',
 'ko': '원격 파일「열기 방식」이 저장됩니다: 「항상 이 앱 / 외부 앱으로 열기」를 선택하면 같은 종류의 파일은 다시 묻지 않고 바로 열립니다.',
 'ru': 'Способ открытия удалённых файлов теперь запоминается: после выбора «всегда открывать в этом приложении» или внешним приложением файлы того же типа открываются сразу, без повторного запроса.',
 'fr': 'Le choix « toujours ouvrir avec » est désormais mémorisé pour les fichiers distants : après avoir choisi cette application ou une application externe, les fichiers du même type s’ouvrent directement sans redemander.',
 'es': 'El método de apertura de archivos remotos ahora se recuerda: tras elegir «abrir siempre con esta aplicación» o una aplicación externa, los archivos del mismo tipo se abren directamente sin volver a preguntar.',
 'de': 'Die Auswahl „Immer öffnen mit“ wird für Remote-Dateien gespeichert: Nach der Wahl dieser App oder einer externen App öffnen Dateien gleichen Typs direkt ohne Rückfrage.',
 'ar': 'تُحفظ طريقة فتح الملفات البعيدة الآن: بعد اختيار «الفتح دائماً بهذا التطبيق» أو بتطبيق خارجي، تُفتح الملفات من النوع نفسه مباشرة دون تكرار السؤال.',
}

FIX1 = {
 'en': 'Fixed: swiping left/right in the remote image viewer only cycled through already downloaded images. It now browses the other images of the current remote folder and downloads them on demand.',
 'zh': '修复：远程图片查看器左右滑动只在已下载的图片之间循环，现可翻页浏览远程目录中的其它图片并按需下载。',
 'zh_TW': '修復：遠端圖片檢視器左右滑動只在已下載的圖片之間循環，現可翻頁瀏覽遠端目錄中的其他圖片並按需下載。',
 'ja': '修正：リモート画像ビューアーで左右にスワイプしても、以前ダウンロードした画像しか切り替わらなかった問題を修正しました。現在はリモートフォルダー内の他の画像をスワイプで閲覧し、必要に応じてダウンロードします。',
 'ko': '수정: 원격 이미지 뷰어에서 좌우 스와이프가 이미 다운로드된 이미지만 반복하던 문제를 수정했습니다. 이제 원격 폴더의 다른 이미지를 넘겨 보며 필요할 때 다운로드합니다.',
 'ru': 'Исправлено: при прокрутке в просмотрщике удалённых изображений перебирались только уже загруженные файлы. Теперь можно листать другие изображения текущей удалённой папки с загрузкой по требованию.',
 'fr': 'Corrigé : dans la visionneuse d’images distantes, le balayage ne parcourait que les images déjà téléchargées. Il parcourt désormais les autres images du dossier distant et les télécharge à la demande.',
 'es': 'Corregido: en el visor de imágenes remotas, el deslizamiento solo recorría las imágenes ya descargadas. Ahora recorre las demás imágenes de la carpeta remota y las descarga cuando es necesario.',
 'de': 'Behoben: Beim Wischen im Remote-Bildbetrachter wurden nur bereits heruntergeladene Bilder durchlaufen. Jetzt werden die weiteren Bilder des Remote-Ordners durchgeblättert und bei Bedarf geladen.',
 'ar': 'تم الإصلاح: في عارض الصور البعيد، كان التمرير ينتقل فقط بين الصور التي تم تنزيلها مسبقاً. أصبح الآن يتنقل بين بقية صور المجلد البعيد وينزلها عند الحاجة.',
}

FIX2 = {
 'en': 'Fixed: some screens (e.g. the connection test dialog) showed Chinese text in Korean, Japanese, German and other languages because those values were never translated. All are now translated.',
 'zh': '修复：连接测试弹窗等界面在韩语、日语、德语等语言下误显示中文（历史占位值未翻译），现已补全各语言译文。',
 'zh_TW': '修復：連線測試視窗等介面在韓語、日語、德語等語言下誤顯示中文（歷史佔位值未翻譯），現已補齊各語言譯文。',
 'ja': '修正：接続テストのダイアログなどが韓国語・日本語・ドイツ語などの画面で中国語を表示していた問題（未翻訳のプレースホルダー値）を修正し、各言語の訳文を追加しました。',
 'ko': '수정: 연결 테스트 창 등 일부 화면이 한국어·일본어·독일어 등에서 중국어로 표시되던 문제(미번역 placeholder)를 수정하고 각 언어 번역을 보완했습니다.',
 'ru': 'Исправлено: на некоторых экранах (например, в диалоге проверки подключения) в корейском, японском, немецком и других языках отображался китайский текст — эти значения не были переведены. Теперь всё переведено.',
 'fr': 'Corrigé : certains écrans (par ex. la boîte de dialogue de test de connexion) affichaient du chinois en coréen, japonais, allemand, etc. — ces valeurs n’avaient jamais été traduites. Tout est désormais traduit.',
 'es': 'Corregido: algunas pantallas (por ejemplo, el diálogo de prueba de conexión) mostraban chino en coreano, japonés, alemán, etc., ya que esos valores nunca se tradujeron. Ahora están traducidos.',
 'de': 'Behoben: Einige Bildschirme (z. B. der Verbindungstest-Dialog) zeigten auf Koreanisch, Japanisch, Deutsch usw. chinesischen Text, da diese Werte nie übersetzt wurden. Alle sind nun übersetzt.',
 'ar': 'تم الإصلاح: كانت بعض الشاشات (مثل نافذة اختبار الاتصال) تعرض نصاً صينياً بالكورية واليابانية والألمانية وغيرها لأن هذه القيم لم تُترجم قط. تمت ترجمتها الآن.',
}

FIX3 = {
 'en': 'Fixed: Traditional Chinese (Taiwan) displayed Simplified Chinese for many texts.',
 'zh': '修复：繁体中文（台湾）界面此前有部分文案显示为简体。',
 'zh_TW': '修復：繁體中文（台灣）介面先前有部分文案顯示為簡體。',
 'ja': '修正：繁体字中国語（台湾）で一部のテキストが簡体字で表示されていた問題を修正しました。',
 'ko': '수정: 번체 중국어(대만)에서 일부 문구가 간체로 표시되던 문제를 수정했습니다.',
 'ru': 'Исправлено: в традиционном китайском (Тайвань) многие тексты отображались упрощёнными иероглифами.',
 'fr': 'Corrigé : en chinois traditionnel (Taïwan), de nombreux textes s’affichaient en chinois simplifié.',
 'es': 'Corregido: en chino tradicional (Taiwán), muchos textos se mostraban en chino simplificado.',
 'de': 'Behoben: Im traditionellen Chinesisch (Taiwan) wurden viele Texte in Kurzzeichen angezeigt.',
 'ar': 'تم الإصلاح: في الصينية التقليدية (تايوان)، كانت العديد من النصوص تظهر بالصينية المبسطة.',
}

LANGS = {lang: {
    'cl213_fixes': FIXES[lang], 'cl213_feat_2': FEAT2[lang],
    'cl213_fix_1': FIX1[lang], 'cl213_fix_2': FIX2[lang], 'cl213_fix_3': FIX3[lang],
} for lang in FIXES}
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
    nl = '\r\n' if b'\r\n' in data else '\n'
    text = data.decode('utf-8')
    if '"%s"' % NEW_KEYS[0] in text:
        print('ARB  %-8s skip' % lang)
    else:
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
            lines.append('    "description": "v2.1.3 changelog: %s"' % key)
            lines.append('  },')
        block = nl.join(lines)
        text = text[:end] + nl + block + text[end:]
        print('ARB  %-8s +%d keys' % (lang, len(NEW_KEYS)))
    # 改写小节标题
    pat = re.compile(r'("cl213_features":\s*")((?:[^"\\]|\\.)*)(")')
    m = pat.search(text)
    if not m:
        raise SystemExit('cl213_features not found in %s' % path)
    text = pat.sub(lambda mm: mm.group(1) + TITLE[lang].replace('"', '\\"') + mm.group(3), text, count=1)
    write_bytes(path, text.encode('utf-8'))
    json.loads(text)
    print('ARB  %-8s title updated' % lang)


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
        lines.append('')
        lines.append('  /// No description provided for @%s.' % key)
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
    anchor = "  String get cl212_fix_3 =>"
    occurrences = []
    pos = text.find(anchor)
    while pos >= 0:
        occurrences.append(pos)
        pos = text.find(anchor, pos + 1)
    if not occurrences:
        raise SystemExit('anchor not found in %s' % path)
    tables = [LANGS[lang]] if len(occurrences) == 1 else [LANGS['zh'], LANGS['zh_TW']]
    if 'String get cl213_fixes =>' not in text:
        for i in range(len(occurrences) - 1, -1, -1):
            start = occurrences[i]
            idx = text.find("';", start)
            end = -1
            while idx >= 0:
                if idx == 0 or text[idx - 1] != '\\':
                    end = idx + 2
                    break
                idx = text.find("';", idx + 1)
            if end < 0:
                raise SystemExit('no getter terminator in %s' % path)
            table = tables[i]
            lines = []
            for key in NEW_KEYS:
                lines.append('')
                lines.append('  @override')
                lines.append("  String get %s => '%s';" % (key, esc(table[key])))
            block = nl.join(lines)
            text = text[:end] + block + text[end:]
        print('DART %-8s +%d keys (x%d)' % (lang, len(NEW_KEYS), len(occurrences)))
    else:
        print('DART %-8s skip keys' % lang)
    # 改写小节标题（每个 occurrence 对应各自语言）
    pat = re.compile(r"(String get cl213_features =>\s*')((?:[^'\\]|\\.)*)(';)")
    ms = list(pat.finditer(text))
    if not ms:
        raise SystemExit('cl213_features getter not found in %s' % path)
    if len(ms) == len(tables):
        for i in range(len(ms) - 1, -1, -1):
            m = ms[i]
            text = text[:m.start(2)] + esc(TITLE[('zh' if i == 0 and len(tables) > 1 else ('zh_TW' if i == 1 else lang))]) + text[m.end(2):]
    else:
        text = pat.sub(lambda mm: mm.group(1) + esc(TITLE[lang]) + mm.group(3), text, count=1)
    write_bytes(path, text.encode('utf-8'))
    print('DART %-8s title updated' % lang)


def main():
    for lang in sorted(LANGS.keys()):
        insert_arb(lang, LANGS[lang])
    insert_base()
    for lang in DART_LOCALES:
        insert_locale(lang)
    print('done')


if __name__ == '__main__':
    sys.exit(main())
