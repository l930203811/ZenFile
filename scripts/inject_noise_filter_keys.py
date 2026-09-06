#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json
import os

keys = {
    'ui_category_noise_filter_title': {
        'en': 'Category noise filter',
        'zh': '类别噪音过滤',
        'zh_TW': '類別噪音過濾',
        'es': 'Filtro de ruido por categoría',
        'fr': 'Filtre anti-bruit par catégorie',
        'de': 'Rauschfilter nach Kategorie',
        'ja': 'カテゴリごとのノイズフィルター',
        'ko': '카테고리별 노이즈 필터',
        'ru': 'Фильтр шума по категориям',
        'ar': 'مرشح الضوضاء حسب الفئة',
    },
    'ui_noise_filter_images_subtitle': {
        'en': 'Hide icons & tiny images (<30KB)',
        'zh': '隐藏图标/超小图片 (<30KB)',
        'zh_TW': '隱藏圖示/超小圖片 (<30KB)',
        'es': 'Ocultar iconos e imágenes diminutas (<30KB)',
        'fr': 'Masquer les icônes et mini-images (<30 Ko)',
        'de': 'Symbole und Mini-Bilder ausblenden (<30KB)',
        'ja': 'アイコンと極小画像を非表示 (<30KB)',
        'ko': '아이콘과 아주 작은 이미지 숨기기 (<30KB)',
        'ru': 'Скрыть значки и крошечные изображения (<30 КБ)',
        'ar': 'إخفاء الرموز والصور الصغيرة جدًا (<30 كيلوبايت)',
    },
    'ui_noise_filter_videos_subtitle': {
        'en': 'Hide short clips & fragments (<1MB)',
        'zh': '隐藏短视频/碎片 (<1MB)',
        'zh_TW': '隱藏短影片/碎片 (<1MB)',
        'es': 'Ocultar clips cortos y fragmentos (<1MB)',
        'fr': 'Masquer clips courts et fragments (<1 Mo)',
        'de': 'Kurze Clips und Fragmente ausblenden (<1MB)',
        'ja': '短いクリップと断片を非表示 (<1MB)',
        'ko': '짧은 클립과 조각 숨기기 (<1MB)',
        'ru': 'Скрыть короткие клипы и фрагменты (<1 МБ)',
        'ar': 'إخفاء المقاطع القصيرة والفتات (<1 ميغابايت)',
    },
    'ui_noise_filter_screenshots_subtitle': {
        'en': 'Hide notification & shortcut icons (<5KB)',
        'zh': '隐藏通知/快捷方式图标 (<5KB)',
        'zh_TW': '隱藏通知/捷徑圖示 (<5KB)',
        'es': 'Ocultar iconos de notificación/acceso directo (<5KB)',
        'fr': 'Masquer les icônes de notification/raccourci (<5 Ko)',
        'de': 'Benachrichtigungs-/Verknüpfungssymbole ausblenden (<5KB)',
        'ja': '通知/ショートカットアイコンを非表示 (<5KB)',
        'ko': '알림/바로가기 아이콘 숨기기 (<5KB)',
        'ru': 'Скрыть значки уведомлений/ярлыков (<5 КБ)',
        'ar': 'إخفاء أيقونات الإشعارات/الاختصارات (<5 كيلوبايت)',
    },
    'ui_noise_filter_audios_subtitle': {
        'en': 'Hide sound effects, alerts & recordings (<60s)',
        'zh': '隐藏音效/提示音/录音 (<60秒)',
        'zh_TW': '隱藏音效/提示音/錄音 (<60秒)',
        'es': 'Ocultar efectos, alertas y grabaciones (<60s)',
        'fr': 'Masquer effets, alertes et enregistrements (<60s)',
        'de': 'Soundeffekte, Hinweise und Aufnahmen ausblenden (<60s)',
        'ja': '効果音/アラート/録音を非表示 (<60秒)',
        'ko': '효과음/알림/녹음 숨기기 (<60초)',
        'ru': 'Скрыть эффекты, оповещения и записи (<60 с)',
        'ar': 'إخفاء المؤثرات والتنبيهات والتسجيلات (<60 ثانية)',
    },
    'ui_noise_filter_documents_subtitle': {
        'en': 'Hide broken/empty documents (0KB)',
        'zh': '隐藏损坏/空文档 (0KB)',
        'zh_TW': '隱藏損壞/空文件 (0KB)',
        'es': 'Ocultar documentos vacíos o dañados (0KB)',
        'fr': 'Masquer les documents vides ou endommagés (0 Ko)',
        'de': 'Beschädigte/leere Dokumente ausblenden (0KB)',
        'ja': '破損/空のドキュメントを非表示 (0KB)',
        'ko': '손상/빈 문서 숨기기 (0KB)',
        'ru': 'Скрыть пустые/повреждённые документы (0 КБ)',
        'ar': 'إخفاء المستندات التالفة/الفارغة (0 كيلوبايت)',
    },
    'ui_noise_filter_archives_subtitle': {
        'en': 'Hide broken/empty archives (<100B)',
        'zh': '隐藏损坏/空压缩包 (<100B)',
        'zh_TW': '隱藏損壞/空壓縮檔 (<100B)',
        'es': 'Ocultar archivos comprimidos vacíos o dañados (<100B)',
        'fr': 'Masquer archives vides ou endommagées (<100 o)',
        'de': 'Beschädigte/leere Archive ausblenden (<100B)',
        'ja': '破損/空のアーカイブを非表示 (<100B)',
        'ko': '손상/빈 압축 파일 숨기기 (<100B)',
        'ru': 'Скрыть пустые/повреждённые архивы (<100 Б)',
        'ar': 'إخفاء الأرشيفات التالفة/الفارغة (<100 بايت)',
    },
    'ui_noise_filter_downloads_subtitle': {
        'en': 'Hide broken/empty downloads (0KB)',
        'zh': '隐藏损坏/空下载 (0KB)',
        'zh_TW': '隱藏損壞/空下載 (0KB)',
        'es': 'Ocultar descargas vacías o dañadas (0KB)',
        'fr': 'Masquer téléchargements vides ou endommagés (0 Ko)',
        'de': 'Beschädigte/leere Downloads ausblenden (0KB)',
        'ja': '破損/空のダウンロードを非表示 (0KB)',
        'ko': '손상/빈 다운로드 숨기기 (0KB)',
        'ru': 'Скрыть пустые/повреждённые загрузки (0 КБ)',
        'ar': 'إخفاء التنزيلات التالفة/الفارغة (0 كيلوبايت)',
    },
    'ui_noise_filter_apks_subtitle': {
        'en': 'Hide broken/tiny APKs (<100KB)',
        'zh': '隐藏损坏/极小安装包 (<100KB)',
        'zh_TW': '隱藏損壞/極小安裝包 (<100KB)',
        'es': 'Ocultar APKs dañados o diminutos (<100KB)',
        'fr': 'Masquer les APK endommagés ou trop petits (<100 Ko)',
        'de': 'Beschädigte/zu kleine APKs ausblenden (<100KB)',
        'ja': '破損/極小のAPKを非表示 (<100KB)',
        'ko': '손상/아주 작은 APK 숨기기 (<100KB)',
        'ru': 'Скрыть повреждённые/крошечные APK (<100 КБ)',
        'ar': 'إخفاء حزم APK التالفة/الصغيرة (<100 كيلوبايت)',
    },
}

files = {
    'lib/l10n/app_en.arb': 'en',
    'lib/l10n/app_zh.arb': 'zh',
    'lib/l10n/app_zh_TW.arb': 'zh_TW',
    'lib/l10n/app_es.arb': 'es',
    'lib/l10n/app_fr.arb': 'fr',
    'lib/l10n/app_de.arb': 'de',
    'lib/l10n/app_ja.arb': 'ja',
    'lib/l10n/app_ko.arb': 'ko',
    'lib/l10n/app_ru.arb': 'ru',
    'lib/l10n/app_ar.arb': 'ar',
}

for path, loc in files.items():
    with open(path, 'r', encoding='utf-8') as fh:
        src = fh.read()
    depth = 0
    top_idx = -1
    for i, ch in enumerate(src):
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                top_idx = i
                break
    blocks = []
    for key, lang_map in keys.items():
        val = lang_map[loc]
        blocks.append('  "' + key + '": ' + json.dumps(val, ensure_ascii=False) + ',')
        blocks.append('  "@' + key + '": {')
        blocks.append('    "description": "category noise filter (' + key + ')"')
        blocks.append('  },')
    block_str = '\n'.join(blocks) + '\n'
    new_src = src[:top_idx] + block_str + src[top_idx:]
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(new_src)
    print('Updated', path)
print('Done')
