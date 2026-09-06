#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一次性脚本：为 MediaFilterScreen 注入 6 个新 l10n key 到 10 个 ARB 文件。
用法：python scripts/inject_filter_screen_keys.py
"""
import json
import os
import re

BASE = os.path.join(os.path.dirname(__file__), '..', 'lib', 'l10n')

# key: (zh, zh_TW, en, es, fr, de, ja, ko, ru, ar)
STRINGS = {
    "ui_media_filter_title": (
        "过滤设置", "過濾設定", "Filter Settings", "Configuración de Filtro",
        "Paramètres du Filtre", "Filtereinstellungen", "フィルター設定",
        "필터 설정", "Настройки Фильтра", "إعدادات التصفية"
    ),
    "ui_media_filter_description": (
        "自定义该分类下需要过滤的文件条件",
        "自訂該分類下需要過濾的檔案條件",
        "Customize file filtering conditions for this category",
        "Personalizar condiciones de filtrado de archivos para esta categoría",
        "Personnaliser les conditions de filtrage des fichiers pour cette catégorie",
        "Filterbedingungen für diese Kategorie anpassen",
        "このカテゴリのファイルフィルター条件をカスタマイズ",
        "이 카테고리의 파일 필터 조건을 사용자 지정",
        "Настроить условия фильтрации файлов для этой категории",
        "تخصيص شروج تصفية الملفات لهذه الفئة"
    ),
    "ui_media_filter_master_switch": (
        "启用智能过滤", "啟用智慧過濾", "Enable Smart Filter",
        "Habilitar Filtro Inteligente", "Activer le Filtre Intelligent",
        "Intelligenten Filter Aktivieren", "スマートフィルターを有効化",
        "스마트 필터 사용", "Включить Умный Фильтр", "تمكين الفلتر الذكي"
    ),
    "ui_media_filter_master_hint": (
        "开启后将按下方规则过滤小文件、短视频/音频等噪声",
        "開啟後將按下方規則過濾小檔案、短影片/音訊等雜訊",
        "When enabled, small files, short videos/audios and other noise will be filtered by the rules below",
        "Al activar, se filtrarán archivos pequeños, videos/audios cortos y otro ruido según las reglas siguientes",
        "Lorsqu'activé, les petits fichiers, courtes vidéos/audios et autres bruits seront filtrés selon les règles ci-dessous",
        "Bei Aktivierung werden kleine Dateien, kurze Videos/Audios und andere Störungen nach den untenstehenden Regeln gefiltert",
        "有効にすると、以下のルールに従って小さなファイル、短い動画/音楽などのノイズをフィルタリングします",
        "활성화되면 아래 규칙에 따라 작은 파일, 짧은 동영상/오디오 등의 노이즈가 필터링됩니다",
        "При включении мелкие файлы, короткие видео/аудио и прочий шум будут отфильтрованы по правилам ниже",
        "عند التمكين، سيتم تصفية الملفات الصغيرة ومقاطع الفيديو/الصوت القصيرة والضوضاء الأخرى حسب القواعد أدناه"
    ),
    "ui_media_filter_rules": (
        "过滤规则", "過濾規則", "Filter Rules", "Reglas de Filtro",
        "Règles de Filtre", "Filterregeln", "フィルタールール", "필터 규칙",
        "Правила Фильтра", "قواعد التصفية"
    ),
    "ui_media_filter_restore_default": (
        "恢复默认", "恢復預設", "Restore Default", "Restaurar Predeterminado",
        "Réinitialiser", "Standard Wiederherstellen", "デフォルトに戻す",
        "기본값 복원", "Восстановить По Умолчанию", "استعادة الافتراضي"
    ),
}

LANG_ORDER = ['zh', 'zh_TW', 'en', 'es', 'fr', 'de', 'ja', 'ko', 'ru', 'ar']

def inject(path, lang_idx):
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()

    # 找到顶层末尾的 "}"（忽略字符串和嵌套对象）
    depth = 0
    last_key_end = -1
    in_string = False
    escape = False
    for i, ch in enumerate(text):
        if escape:
            escape = False
            continue
        if ch == '\\':
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                last_key_end = i
                break

    if last_key_end == -1:
        print(f'WARN: could not find root closing brace in {path}')
        return

    # 在 last_key_end 之前插入新 key（注意前面是否已有逗号）
    insert_pos = last_key_end
    # 检查插入点前一个非空白字符
    before = text[:insert_pos].rstrip()
    needs_comma = not before.endswith(',')

    chunks = []
    if needs_comma:
        chunks.append(',')
    chunks.append('\n')

    for key, translations in STRINGS.items():
        value = translations[lang_idx]
        chunks.append(f'  "{key}": "{value}",\n')
        chunks.append(f'  "@{key}": {{\n')
        chunks.append(f'    "description": "media filter screen ({key})"\n')
        chunks.append('  }')
        # 最后一个 key 不加逗号，避免顶层末尾多逗号
        if key != list(STRINGS.keys())[-1]:
            chunks.append(',\n')
        else:
            chunks.append('\n')

    new_text = text[:insert_pos] + ''.join(chunks) + text[insert_pos:]

    with open(path, 'w', encoding='utf-8') as f:
        f.write(new_text)
    print(f'Updated {os.path.basename(path)}')


def main():
    for idx, lang in enumerate(LANG_ORDER):
        path = os.path.join(BASE, f'app_{lang}.arb')
        inject(path, idx)


if __name__ == '__main__':
    main()
