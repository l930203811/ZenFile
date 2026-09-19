import io, re, os

DIR = r'D:\Xiangmu\ZenFile-main\lib\l10n\generated'
FILES = [
    'app_localizations_ar.dart', 'app_localizations_de.dart', 'app_localizations_en.dart',
    'app_localizations_es.dart', 'app_localizations_fr.dart', 'app_localizations_ja.dart',
    'app_localizations_ko.dart', 'app_localizations_ru.dart', 'app_localizations_zh.dart',
]

# 只动 ui_share_scan_failed 方法体内的 \$error 转义 → $error 真插值
pat = re.compile(
    r"(String ui_share_scan_failed\(Object error\) \{\s*return '[^']*?)\\\$error(';)",
)

for fn in FILES:
    p = os.path.join(DIR, fn)
    t = io.open(p, encoding='utf-8', newline='').read()
    new, n = pat.subn(r"\1$error\2", t)
    # zh.dart 含 L10nZh + L10nZhTw 两个类
    print(fn, 'replaced:', n)
    if n:
        io.open(p, 'w', encoding='utf-8', newline='').write(new)
