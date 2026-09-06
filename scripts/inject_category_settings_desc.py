import glob

# 在 ui_category_settings_title 块之后注入 ui_category_settings_description key。
BLOCK_MID = (
    '\n'
    '  "ui_category_settings_description": "管理该分类的过滤规则与扫描位置",\n'
    '  "@ui_category_settings_description": {\n'
    '    "description": "category settings screen description (ui_category_settings_description)"\n'
    '  },'
)
BLOCK_END = (
    ',\n'
    '  "ui_category_settings_description": "管理该分类的过滤规则与扫描位置",\n'
    '  "@ui_category_settings_description": {\n'
    '    "description": "category settings screen description (ui_category_settings_description)"\n'
    '  }'
)

for path in sorted(glob.glob('lib/l10n/app_*.arb')):
    with open(path, encoding='utf-8') as f:
        text = f.read()
    marker = '"@ui_category_settings_title": {'
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
        text = text[:close_pos + 1] + BLOCK_MID + text[close_pos + 1:]
    else:
        text = text[:close_pos] + BLOCK_END + text[close_pos:]
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)
    print('UPDATED', path)
