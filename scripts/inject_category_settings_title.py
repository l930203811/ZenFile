import glob

# 在「过滤设置」相关 key 之后注入「类别设置」页面标题 key。
# 兼容两种情形：① 该 key 位于文件中部（其 @块以 "}," 结尾）；
#                ② 该 key 位于文件末尾（其 @块以 "}" 结尾，紧接文件收尾 "}"）。
BLOCK_MID = (
    '\n'
    '  "ui_category_settings_title": "类别设置",\n'
    '  "@ui_category_settings_title": {\n'
    '    "description": "category settings screen (ui_category_settings_title)"\n'
    '  },'
)
BLOCK_END = (
    ',\n'
    '  "ui_category_settings_title": "类别设置",\n'
    '  "@ui_category_settings_title": {\n'
    '    "description": "category settings screen (ui_category_settings_title)"\n'
    '  }'
)

for path in sorted(glob.glob('lib/l10n/app_*.arb')):
    with open(path, encoding='utf-8') as f:
        text = f.read()
    marker = '"@ui_media_filter_restore_default": {'
    idx = text.find(marker)
    if idx < 0:
        print('SKIP (marker not found):', path)
        continue
    end = text.find('\n  }', idx)
    if end < 0:
        print('SKIP (no close brace):', path)
        continue
    close_pos = end + len('\n  }')
    after = text[close_pos:]
    if after.startswith(','):
        # 中部：原 "}," 后的逗号已存在，去掉新块末尾逗号
        text = text[:close_pos + 1] + BLOCK_MID + text[close_pos + 1:]
    else:
        # 文件末尾：需补逗号
        text = text[:close_pos] + BLOCK_END + text[close_pos:]
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)
    print('UPDATED', path)
