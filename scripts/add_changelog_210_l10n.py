#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""插入「v2.1.0 更新日志」所需的 l10n key（cl210_*）。

复用 add_changelog_200_l10n.py 的全部铁律：
- lib/l10n/app_*.arb 用 CRLF，lib/l10n/generated/*.dart 用 LF → 全程二进制读写。
- 按锚点（crypt_settings_title）插入，不重跑 gen-l10n
  （会覆盖手工合并的 L10nZh / L10nZhTw）。
- zh.dart 里锚点出现两次（L10nZh、L10nZhTw）：第一次用 zh，第二次用 zh_TW。
- 全部为**无占位符**的纯字符串 getter（dart 侧 `String get xxx => '...';`）。
- 文案风格：FR/DE 等语言里的引号用当地排版引号（„ “ / « »），
  避免半角单引号（会被 dart esc 成 \\'）与未转义双引号。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

KEYS = [
    'cl210_features',
    'cl210_feat_1', 'cl210_feat_2', 'cl210_feat_3', 'cl210_feat_4', 'cl210_feat_5',
    'cl210_ui',
    'cl210_ui_1', 'cl210_ui_2', 'cl210_ui_3', 'cl210_ui_4', 'cl210_ui_5',
    'cl210_fixes',
    'cl210_fix_1', 'cl210_fix_2', 'cl210_fix_3', 'cl210_fix_4', 'cl210_fix_5',
]

ZH = {
    'cl210_features': '新增功能',
    'cl210_feat_1': '视频支持后台播放：菜单新增「后台播放」，关闭播放页后仍可在通知栏控制播放、暂停与进度。',
    'cl210_feat_2': '视频定时关闭：可设置 15 / 30 / 45 / 60 分钟后停止播放，已设置时可随时取消。',
    'cl210_feat_3': '文件夹新增「打开方式」：此前只有文件有该入口，网格、列表与双窗格视图均已支持。',
    'cl210_feat_4': '属性入口补全：浏览页、最近页与分类页的三点菜单均可查看文件或文件夹属性。',
    'cl210_feat_5': '设为首页支持取消：已设为首页的文件夹，菜单中会显示「取消设为首页」。',
    'cl210_ui': '界面与交互',
    'cl210_ui_1': '三点菜单改为图标宫格：图标在上、文字在下，长标题两行显示，并按项数自动排列为三列或四列。',
    'cl210_ui_2': '统一浏览页与分类页的菜单顺序，「设为首页」与「在位置中显示」位于同一位置。',
    'cl210_ui_3': '优化图标宫格对齐：多语言长标题换行时，同一排图标仍保持在同一水平线。',
    'cl210_ui_4': '文件与文件夹的三点按钮改为竖排样式，覆盖网格、列表与紧凑三种视图。',
    'cl210_ui_5': '视频播放优化：左右拖动快进快退不再中断播放；锁定按钮移至左侧中部并常驻显示。',
    'cl210_fixes': '问题修复',
    'cl210_fix_1': '修复在受限的 Android/data、Android/obb 目录中无法新建文件、文件夹与压缩包的问题：修正写入路径策略，并将授权方式改为按应用目录逐个授权。',
    'cl210_fix_2': '新建不再无提示地失败：失败时会显示具体原因；在 Android/data 根目录新建时会提示先进入具体应用目录。',
    'cl210_fix_3': '修复分类页多选「置顶」无效的问题（置顶已保存但列表未重新排序），并修正菜单文案为「取消置顶」。',
    'cl210_fix_4': '修复「取消设为首页」无效的问题：此前首页设置未被真正清除。',
    'cl210_fix_5': '修复部分页面「属性」点击无响应的问题。',
}

ZH_TW = {
    'cl210_features': '新增功能',
    'cl210_feat_1': '影片支援背景播放：選單新增「背景播放」，關閉播放頁後仍可從通知列控制播放、暫停與進度。',
    'cl210_feat_2': '影片定時關閉：可設定 15 / 30 / 45 / 60 分鐘後停止播放，已設定時可隨時取消。',
    'cl210_feat_3': '資料夾新增「開啟方式」：此前僅檔案有此項目，網格、清單與雙窗格檢視皆已支援。',
    'cl210_feat_4': '屬性入口補齊：瀏覽頁、最近頁與分類頁的三點選單皆可檢視檔案或資料夾的屬性。',
    'cl210_feat_5': '設為首頁支援取消：已設為首頁的資料夾，選單會顯示「取消設為首頁」。',
    'cl210_ui': '介面與操作',
    'cl210_ui_1': '三點選單改為圖示方格：圖示在上、文字在下，長標題以兩行顯示，並依項目數量自動排為三欄或四欄。',
    'cl210_ui_2': '統一瀏覽頁與分類頁的選單順序，「設為首頁」與「在位置中顯示」位於相同位置。',
    'cl210_ui_3': '最佳化圖示方格對齊：翻譯後長標題換行時，同一排圖示仍維持在同一水平線。',
    'cl210_ui_4': '檔案與資料夾的三點按鈕改為直向，涵蓋網格、清單與精簡三種檢視。',
    'cl210_ui_5': '影片播放最佳化：左右拖曳快轉與倒轉不再中斷播放；鎖定按鈕移至左側中央並常駐顯示。',
    'cl210_fixes': '問題修復',
    'cl210_fix_1': '修復在受限的 Android/data、Android/obb 目錄中無法建立檔案、資料夾與壓縮檔的問題：修正寫入路徑策略，並將授權方式改為依應用程式目錄逐個授權。',
    'cl210_fix_2': '建立失敗不再沒有回應：失敗時會顯示原因；在 Android/data 根目錄建立時會提示先進入應用程式目錄。',
    'cl210_fix_3': '修復分類頁多選選單「置頂」無效的問題（置頂已儲存但清單未重新排序），並修正選單文字為「取消置頂」。',
    'cl210_fix_4': '修復「取消設為首頁」無效的問題：首頁設定此前未被真正清除。',
    'cl210_fix_5': '修復部分頁面「屬性」點擊沒有回應的問題。',
}

EN = {
    'cl210_features': 'New features',
    'cl210_feat_1': 'Background video playback: a new "Play in background" entry keeps playback running after you leave the player, with play, pause and progress controls in the notification.',
    'cl210_feat_2': 'Video sleep timer: stop playback after 15, 30, 45 or 60 minutes; a set timer can be cancelled at any time.',
    'cl210_feat_3': 'Open with for folders: this entry used to appear for files only, and now works in grid, list and dual-pane views.',
    'cl210_feat_4': 'Properties everywhere: the three-dot menu in the browser, in Recents and in the category pages can all show the properties of a file or folder.',
    'cl210_feat_5': 'The home folder can be cleared: a folder already set as home shows "Cancel set as home" in its menu.',
    'cl210_ui': 'Interface and interaction',
    'cl210_ui_1': 'The three-dot menu is now an icon grid: the icon sits above the label, long labels wrap to two lines, and items are laid out in three or four columns depending on their number.',
    'cl210_ui_2': 'The browser and category menus now share one order, with "Set as home" sitting where "Show in location" is.',
    'cl210_ui_3': 'Better alignment in the icon grid: when long translated labels wrap, the icons in a row still stay on the same horizontal line.',
    'cl210_ui_4': 'The three-dot button on files and folders is now vertical, in grid, list and compact views.',
    'cl210_ui_5': 'Video playback: swiping to seek no longer interrupts playback, and the lock button moved to the middle of the left edge where it stays visible.',
    'cl210_fixes': 'Fixes',
    'cl210_fix_1': 'Fixed files, folders and archives not being created inside restricted Android/data and Android/obb folders: the write path strategy was corrected and permission is now granted per app folder.',
    'cl210_fix_2': 'Creation no longer fails silently: the reason is now shown, and creating directly in Android/data prompts you to open a specific app folder first.',
    'cl210_fix_3': 'Fixed "Pin to top" in the category page multi-select menu doing nothing (the pin was saved but the list was never re-ordered), and corrected the menu label to "Unpin".',
    'cl210_fix_4': 'Fixed "Cancel set as home" not working: the home setting was not actually cleared.',
    'cl210_fix_5': 'Fixed "Properties" not responding on some pages.',
}

JA = {
    'cl210_features': '新機能',
    'cl210_feat_1': '動画のバックグラウンド再生：メニューに「バックグラウンド再生」を追加しました。再生画面を閉じても通知から再生・一時停止・進行状況を操作できます。',
    'cl210_feat_2': '動画のタイマー停止：15 / 30 / 45 / 60 分後に再生を停止できます。設定済みの場合はいつでもキャンセルできます。',
    'cl210_feat_3': 'フォルダーの「別のアプリで開く」：これまでファイルのみの項目でしたが、グリッド・リスト・デュアルペインのすべてに対応しました。',
    'cl210_feat_4': 'プロパティの入口を補完：ブラウズ画面・最近使用・カテゴリー画面の三点メニューからファイルやフォルダーのプロパティを表示できます。',
    'cl210_feat_5': 'ホーム設定の解除：ホームに設定済みのフォルダーでは、メニューに「ホーム設定を解除」が表示されます。',
    'cl210_ui': '画面と操作',
    'cl210_ui_1': '三点メニューをアイコンのグリッド表示に変更しました。アイコンが上、ラベルが下になり、長いラベルは 2 行表示、項目数に応じて 3 列または 4 列に並びます。',
    'cl210_ui_2': 'ブラウズ画面とカテゴリー画面のメニュー順序を統一しました。「ホームに設定」は「場所を表示」と同じ位置になります。',
    'cl210_ui_3': 'アイコングリッドの整列を改善しました。翻訳で長いラベルが折り返しても、同じ行のアイコンは同じ高さに揃います。',
    'cl210_ui_4': 'ファイルとフォルダーの三点ボタンを縦向きに変更しました。グリッド・リスト・コンパクトのすべての表示に対応します。',
    'cl210_ui_5': '動画再生の改善：スワイプでのシークが再生を中断しなくなりました。ロックボタンは左側中央に移動し、常に表示されます。',
    'cl210_fixes': '修正',
    'cl210_fix_1': '制限された Android/data、Android/obb フォルダー内でファイル・フォルダー・圧縮ファイルを作成できない問題を修正しました。書き込みパスの方針を見直し、権限はアプリフォルダーごとに付与する方式に変更しました。',
    'cl210_fix_2': '作成の失敗が無言で終わらなくなりました。失敗時は理由を表示し、Android/data 直下で作成しようとした場合はアプリフォルダーを開くよう案内します。',
    'cl210_fix_3': 'カテゴリー画面の複数選択メニューで「最前面に固定」が効かない問題を修正しました（固定は保存されていましたが並べ替えが行われていませんでした）。併せてメニュー表記を「固定を解除」に修正しました。',
    'cl210_fix_4': '「ホーム設定を解除」が効かない問題を修正しました。ホーム設定が実際には消去されていませんでした。',
    'cl210_fix_5': '一部の画面で「プロパティ」が反応しない問題を修正しました。',
}

KO = {
    'cl210_features': '새로운 기능',
    'cl210_feat_1': '동영상 백그라운드 재생: 메뉴에 「백그라운드 재생」이 추가되어 재생 화면을 닫아도 알림에서 재생, 일시정지, 진행 위치를 조작할 수 있습니다.',
    'cl210_feat_2': '동영상 타이머 종료: 15 / 30 / 45 / 60분 후 재생을 멈출 수 있으며, 설정한 타이머는 언제든 취소할 수 있습니다.',
    'cl210_feat_3': '폴더의 「다른 앱으로 열기」: 이전에는 파일에만 있던 항목으로, 그리드·목록·이중 창 모두에서 사용할 수 있습니다.',
    'cl210_feat_4': '속성 항목 보강: 브라우저, 최근 항목, 카테고리 화면의 점 세 개 메뉴에서 파일과 폴더의 속성을 볼 수 있습니다.',
    'cl210_feat_5': '홈 폴더 해제: 이미 홈으로 지정한 폴더의 메뉴에 「홈 설정 해제」가 표시됩니다.',
    'cl210_ui': '화면과 조작',
    'cl210_ui_1': '점 세 개 메뉴가 아이콘 격자로 바뀌었습니다. 아이콘은 위쪽, 이름은 아래쪽에 놓이고 긴 이름은 두 줄로 표시되며 항목 수에 따라 3열 또는 4열로 정렬됩니다.',
    'cl210_ui_2': '브라우저와 카테고리 화면의 메뉴 순서를 통일했습니다. 「홈으로 설정」은 「위치에서 보기」와 같은 자리에 놓입니다.',
    'cl210_ui_3': '아이콘 격자의 정렬을 개선했습니다. 번역된 긴 이름이 줄바꿈되어도 같은 줄의 아이콘은 같은 높이에 놓입니다.',
    'cl210_ui_4': '파일과 폴더의 점 세 개 버튼이 세로 방향으로 바뀌었습니다. 그리드·목록·간단히 보기 모두에 적용됩니다.',
    'cl210_ui_5': '동영상 재생 개선: 좌우로 밀어 탐색해도 재생이 멈추지 않으며, 잠금 버튼이 왼쪽 중앙으로 이동해 항상 표시됩니다.',
    'cl210_fixes': '수정 사항',
    'cl210_fix_1': '제한된 Android/data, Android/obb 폴더에서 파일·폴더·압축 파일을 만들 수 없던 문제를 수정했습니다. 쓰기 경로 방식을 바로잡고 권한을 앱 폴더별로 부여하도록 변경했습니다.',
    'cl210_fix_2': '만들기 실패가 더 이상 조용히 지나가지 않습니다. 실패하면 이유를 보여 주고, Android/data 최상위에서 만들려 하면 앱 폴더로 들어가도록 안내합니다.',
    'cl210_fix_3': '카테고리 화면의 다중 선택 메뉴에서 「맨 위에 고정」이 동작하지 않던 문제를 수정했습니다(고정은 저장되었지만 목록이 다시 정렬되지 않았습니다). 메뉴 이름도 「고정 해제」로 바로잡았습니다.',
    'cl210_fix_4': '「홈 설정 해제」가 동작하지 않던 문제를 수정했습니다. 홈 설정이 실제로 지워지지 않았습니다.',
    'cl210_fix_5': '일부 화면에서 「속성」이 반응하지 않던 문제를 수정했습니다.',
}

DE = {
    'cl210_features': 'Neue Funktionen',
    'cl210_feat_1': 'Video im Hintergrund abspielen: Ein neuer Eintrag lässt die Wiedergabe weiterlaufen, wenn du den Player verlässt; die Benachrichtigung steuert Start, Pause und Position.',
    'cl210_feat_2': 'Abschalttimer für Videos: Wiedergabe nach 15, 30, 45 oder 60 Minuten beenden; ein gesetzter Timer lässt sich jederzeit abbrechen.',
    'cl210_feat_3': '„Öffnen mit" für Ordner: Bisher gab es diesen Eintrag nur für Dateien; Raster-, Listen- und Doppelfensteransicht unterstützen ihn jetzt.',
    'cl210_feat_4': 'Eigenschaften überall: Im Browser, unter „Zuletzt" und in den Kategorien lassen sich die Eigenschaften von Dateien und Ordnern über das Drei-Punkte-Menü anzeigen.',
    'cl210_feat_5': 'Startordner lässt sich aufheben: Ein bereits festgelegter Startordner bietet im Menü „Startordner aufheben".',
    'cl210_ui': 'Oberfläche und Bedienung',
    'cl210_ui_1': 'Das Drei-Punkte-Menü ist jetzt ein Symbolraster: Das Symbol steht oben, die Beschriftung darunter, lange Texte laufen über zwei Zeilen, und je nach Anzahl erscheinen drei oder vier Spalten.',
    'cl210_ui_2': 'Browser- und Kategoriemenü haben dieselbe Reihenfolge; „Als Startordner" sitzt dort, wo „Im Ordner anzeigen" steht.',
    'cl210_ui_3': 'Bessere Ausrichtung im Symbolraster: Auch wenn lange übersetzte Beschriftungen umbrechen, bleiben die Symbole einer Zeile auf einer Höhe.',
    'cl210_ui_4': 'Der Drei-Punkte-Knopf an Dateien und Ordnern ist jetzt senkrecht, in der Raster-, Listen- und Kompaktansicht.',
    'cl210_ui_5': 'Videowiedergabe verbessert: Das Spulen durch Wischen unterbricht die Wiedergabe nicht mehr, und der Schlossknopf sitzt dauerhaft sichtbar in der Mitte des linken Rands.',
    'cl210_fixes': 'Fehlerbehebungen',
    'cl210_fix_1': 'Behoben: In eingeschränkten Ordnern wie Android/data und Android/obb ließen sich keine Dateien, Ordner oder Archive erstellen. Die Strategie für den Schreibpfad wurde korrigiert und die Berechtigung wird jetzt pro App-Ordner erteilt.',
    'cl210_fix_2': 'Fehlschläge beim Erstellen sind nicht mehr still: Es wird der Grund angezeigt, und ein Versuch direkt in Android/data weist darauf hin, zuerst einen App-Ordner zu öffnen.',
    'cl210_fix_3': 'Behoben: „Oben anheften" im Mehrfachauswahlmenü der Kategorien wirkte nicht (die Markierung wurde gespeichert, die Liste aber nicht neu sortiert); außerdem heißt der Eintrag jetzt korrekt „Anheften aufheben".',
    'cl210_fix_4': 'Behoben: „Startordner aufheben" wirkte nicht, weil die Einstellung nicht wirklich gelöscht wurde.',
    'cl210_fix_5': 'Behoben: „Eigenschaften" reagierte auf einigen Seiten nicht.',
}

ES = {
    'cl210_features': 'Novedades',
    'cl210_feat_1': 'Reproducción de vídeo en segundo plano: una nueva opción mantiene la reproducción al salir del reproductor y la notificación permite reproducir, pausar y mover la posición.',
    'cl210_feat_2': 'Temporizador de apagado para vídeo: detén la reproducción a los 15, 30, 45 o 60 minutos y cancela el temporizador cuando quieras.',
    'cl210_feat_3': '«Abrir con» en carpetas: antes solo existía para archivos; ahora funciona en las vistas de cuadrícula, lista y doble panel.',
    'cl210_feat_4': 'Propiedades en todas partes: el menú de tres puntos del navegador, de Recientes y de las categorías muestra las propiedades de archivos y carpetas.',
    'cl210_feat_5': 'La carpeta de inicio se puede quitar: una carpeta ya fijada como inicio ofrece «Quitar como inicio» en su menú.',
    'cl210_ui': 'Interfaz y uso',
    'cl210_ui_1': 'El menú de tres puntos es ahora una cuadrícula de iconos: el icono arriba y el texto debajo, los textos largos ocupan dos líneas y se colocan en tres o cuatro columnas según el número de elementos.',
    'cl210_ui_2': 'Los menús del navegador y de las categorías comparten el mismo orden; «Establecer como inicio» ocupa el lugar de «Mostrar en la carpeta».',
    'cl210_ui_3': 'Mejor alineación en la cuadrícula: aunque los textos traducidos ocupen dos líneas, los iconos de una fila siguen en la misma altura.',
    'cl210_ui_4': 'El botón de tres puntos de archivos y carpetas ahora es vertical, en las vistas de cuadrícula, lista y compacta.',
    'cl210_ui_5': 'Reproducción de vídeo mejorada: desplazar para avanzar ya no interrumpe la reproducción y el botón de bloqueo se ha movido al centro del borde izquierdo, donde permanece visible.',
    'cl210_fixes': 'Correcciones',
    'cl210_fix_1': 'Corregido: no se podían crear archivos, carpetas ni comprimidos dentro de las carpetas restringidas Android/data y Android/obb. Se ha corregido la estrategia de ruta de escritura y el permiso se concede ahora por carpeta de aplicación.',
    'cl210_fix_2': 'Los fallos al crear ya no son silenciosos: se muestra el motivo y, si intentas crear directamente en Android/data, se te indica que entres antes en una carpeta de aplicación.',
    'cl210_fix_3': 'Corregido: «Anclar arriba» en el menú de selección múltiple de las categorías no hacía nada (el anclaje se guardaba pero la lista no se reordenaba); además la etiqueta correcta es «Quitar anclaje».',
    'cl210_fix_4': 'Corregido: «Quitar como inicio» no funcionaba porque el ajuste no se borraba de verdad.',
    'cl210_fix_5': 'Corregido: «Propiedades» no respondía en algunas páginas.',
}

FR = {
    'cl210_features': 'Nouveautés',
    'cl210_feat_1': 'Lecture vidéo en arrière-plan : une nouvelle entrée poursuit la lecture après la fermeture du lecteur, et la notification permet de lire, mettre en pause et déplacer la position.',
    'cl210_feat_2': 'Minuterie d arrêt pour la vidéo : arrête la lecture après 15, 30, 45 ou 60 minutes ; une minuterie réglée peut être annulée à tout moment.',
    'cl210_feat_3': '« Ouvrir avec » pour les dossiers : cette entrée n existait que pour les fichiers ; elle fonctionne désormais en grille, en liste et en double panneau.',
    'cl210_feat_4': 'Propriétés partout : le menu à trois points du navigateur, de Récents et des catégories affiche les propriétés des fichiers et des dossiers.',
    'cl210_feat_5': 'Le dossier d accueil peut être annulé : un dossier déjà défini comme accueil propose « Annuler comme accueil » dans son menu.',
    'cl210_ui': 'Interface et utilisation',
    'cl210_ui_1': 'Le menu à trois points devient une grille d icônes : l icône en haut, le libellé en dessous, les libellés longs sur deux lignes, et trois ou quatre colonnes selon le nombre d éléments.',
    'cl210_ui_2': 'Les menus du navigateur et des catégories partagent le même ordre ; « Définir comme accueil » occupe la place de « Afficher dans le dossier ».',
    'cl210_ui_3': 'Meilleur alignement dans la grille : même si un libellé traduit passe sur deux lignes, les icônes d une rangée restent sur la même ligne horizontale.',
    'cl210_ui_4': 'Le bouton à trois points des fichiers et dossiers est désormais vertical, en vues grille, liste et compacte.',
    'cl210_ui_5': 'Lecture vidéo améliorée : balayer pour avancer n interrompt plus la lecture, et le bouton de verrouillage se place au centre du bord gauche, toujours visible.',
    'cl210_fixes': 'Corrections',
    'cl210_fix_1': 'Corrigé : impossible de créer fichiers, dossiers ou archives dans les dossiers restreints Android/data et Android/obb. La stratégie de chemin d écriture a été corrigée et l autorisation est désormais accordée par dossier d application.',
    'cl210_fix_2': 'Les échecs de création ne sont plus silencieux : le motif s affiche, et créer directement dans Android/data invite à ouvrir d abord un dossier d application.',
    'cl210_fix_3': 'Corrigé : « Épingler en haut » dans le menu de sélection multiple des catégories ne faisait rien (l épinglage était enregistré mais la liste n était pas retriée) ; le libellé correct est « Retirer l épingle ».',
    'cl210_fix_4': 'Corrigé : « Annuler comme accueil » ne fonctionnait pas, le réglage n étant pas réellement effacé.',
    'cl210_fix_5': 'Corrigé : « Propriétés » ne répondait pas sur certaines pages.',
}

RU = {
    'cl210_features': 'Новые возможности',
    'cl210_feat_1': 'Фоновое воспроизведение видео: новый пункт меню продолжает воспроизведение после выхода из плеера, а уведомление позволяет ставить паузу и перематывать.',
    'cl210_feat_2': 'Таймер сна для видео: остановка через 15, 30, 45 или 60 минут; установленный таймер можно отменить в любой момент.',
    'cl210_feat_3': '«Открыть с помощью» для папок: раньше пункт был только у файлов; теперь он работает в сетке, списке и двухпанельном режиме.',
    'cl210_feat_4': 'Свойства везде: меню из трёх точек в браузере, в «Недавних» и в категориях показывает свойства файлов и папок.',
    'cl210_feat_5': 'Домашнюю папку можно отменить: у уже назначенной папки в меню появляется пункт «Отменить как домашнюю».',
    'cl210_ui': 'Интерфейс и управление',
    'cl210_ui_1': 'Меню из трёх точек стало сеткой значков: значок сверху, подпись снизу, длинные названия занимают две строки, а элементы выстраиваются в три или четыре столбца.',
    'cl210_ui_2': 'Меню браузера и категорий теперь имеют одинаковый порядок: «Сделать домашней» стоит там же, где «Показать в папке».',
    'cl210_ui_3': 'Улучшено выравнивание сетки значков: даже если длинный перевод занимает две строки, значки в одном ряду остаются на одной линии.',
    'cl210_ui_4': 'Кнопка из трёх точек у файлов и папок теперь вертикальная, во всех видах: сетка, список, компактный.',
    'cl210_ui_5': 'Улучшено воспроизведение видео: перемотка свайпом больше не прерывает воспроизведение, а кнопка блокировки переместилась в середину левого края и всегда видна.',
    'cl210_fixes': 'Исправления',
    'cl210_fix_1': 'Исправлено: в ограниченных папках Android/data и Android/obb не создавались файлы, папки и архивы. Скорректирован путь записи, а разрешение теперь выдаётся отдельно для папки каждого приложения.',
    'cl210_fix_2': 'Ошибки создания больше не остаются незаметными: теперь показывается причина, а при попытке создать объект прямо в Android/data предлагается сначала открыть папку приложения.',
    'cl210_fix_3': 'Исправлено: «Закрепить сверху» в меню множественного выбора на странице категорий не работало (закрепление сохранялось, но список не пересортировывался); пункт меню называется «Снять закрепление».',
    'cl210_fix_4': 'Исправлено: «Отменить как домашнюю» не работало, потому что настройка фактически не удалялась.',
    'cl210_fix_5': 'Исправлено: пункт «Свойства» не реагировал на некоторых страницах.',
}

AR = {
    'cl210_features': 'ميزات جديدة',
    'cl210_feat_1': 'تشغيل الفيديو في الخلفية: خيار جديد يُبقي التشغيل مستمرًا بعد مغادرة المشغّل، ويتيح الإشعار التشغيل والإيقاف المؤقت وتغيير الموضع.',
    'cl210_feat_2': 'مؤقت إيقاف الفيديو: إيقاف التشغيل بعد 15 أو 30 أو 45 أو 60 دقيقة، ويمكن إلغاء المؤقت المضبوط في أي وقت.',
    'cl210_feat_3': '«فتح بواسطة» للمجلدات: كان هذا الخيار متاحًا للملفات فقط، ويعمل الآن في عرض الشبكة والقائمة واللوحين.',
    'cl210_feat_4': 'الخصائص في كل مكان: قائمة النقاط الثلاث في المتصفح و«الأخيرة» والفئات تعرض خصائص الملفات والمجلدات.',
    'cl210_feat_5': 'يمكن إلغاء مجلد البداية: المجلد المعيّن كبداية يعرض «إلغاء التعيين كبداية» في قائمته.',
    'cl210_ui': 'الواجهة والاستخدام',
    'cl210_ui_1': 'أصبحت قائمة النقاط الثلاث شبكة أيقونات: الأيقونة في الأعلى والنص أسفلها، والنصوص الطويلة تمتد على سطرين، وتُرتّب العناصر في ثلاثة أو أربعة أعمدة حسب عددها.',
    'cl210_ui_2': 'تتشارك قوائم المتصفح والفئات الترتيب نفسه، ويحتل «تعيين كبداية» الموضع نفسه الذي يشغله «إظهار في المجلد».',
    'cl210_ui_3': 'تحسين محاذاة شبكة الأيقونات: حتى عند التفاف النص المترجم الطويل، تبقى أيقونات الصف على الخط الأفقي نفسه.',
    'cl210_ui_4': 'أصبح زر النقاط الثلاث للملفات والمجلدات عموديًا، في عروض الشبكة والقائمة والمدمج.',
    'cl210_ui_5': 'تحسين تشغيل الفيديو: لم يعد السحب للتنقل يقطع التشغيل، وانتقل زر القفل إلى منتصف الحافة اليسرى حيث يبقى ظاهرًا.',
    'cl210_fixes': 'إصلاحات',
    'cl210_fix_1': 'تم الإصلاح: تعذّر إنشاء الملفات والمجلدات والأرشيفات داخل المجلدات المقيدة Android/data وAndroid/obb. صُحّح أسلوب مسار الكتابة، وأصبح منح الإذن يتم لكل مجلد تطبيق على حدة.',
    'cl210_fix_2': 'لم يعد فشل الإنشاء يمر بصمت: يظهر السبب، وعند الإنشاء مباشرة في Android/data يُطلب منك فتح مجلد التطبيق أولًا.',
    'cl210_fix_3': 'تم الإصلاح: خيار «تثبيت في الأعلى» في قائمة التحديد المتعدد بصفحة الفئات لم يعمل (حُفظ التثبيت لكن القائمة لم تُعَد ترتيبها)، وصُحّح نص القائمة إلى «إلغاء التثبيت».',
    'cl210_fix_4': 'تم الإصلاح: خيار «إلغاء التعيين كبداية» لم يعمل لأن الإعداد لم يُحذف فعليًا.',
    'cl210_fix_5': 'تم الإصلاح: خيار «الخصائص» لم يستجب في بعض الصفحات.',
}

LANGS = {
    'en': EN, 'zh': ZH, 'zh_TW': ZH_TW, 'ja': JA, 'ko': KO,
    'de': DE, 'es': ES, 'fr': FR, 'ru': RU, 'ar': AR,
}

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
    nl = b'\r\n' if b'\r\n' in data else b'\n'
    text = data.decode('utf-8')

    anchor = '"@crypt_settings_title"'
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit('anchor not found in %s' % path)
    end = text.find('\n  },', idx)
    if end < 0:
        end = text.find('\n  }', idx)
        if end < 0:
            raise SystemExit('meta end not found in %s' % path)
        end += len('\n  }')
    else:
        end += len('\n  },')

    lines = []
    for key in KEYS:
        lines.append('  "%s": "%s",' % (key, table[key].replace('"', '\\"')))
        lines.append('  "@%s": {' % key)
        lines.append('    "description": "changelog 2.1.0: %s"' % key)
        lines.append('  },')
    block = '\n'.join(lines).replace('\n', nl.decode('utf-8'))

    text = text[:end] + nl.decode('utf-8') + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    with io.open(path, 'r', encoding='utf-8') as f:
        json.load(f)
    print('ARB  %-8s +%d keys' % (lang, len(KEYS)))


def insert_base():
    path = os.path.join(GEN_DIR, 'app_localizations.dart')
    data = read_bytes(path)
    nl = b'\r\n' if b'\r\n' in data else b'\n'
    text = data.decode('utf-8')

    anchor = '  String get crypt_settings_title;'
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit('anchor not found in base')
    end = idx + len(anchor)

    lines = []
    for key in KEYS:
        lines.append('')
        lines.append('  /// No description provided for @%s.' % key)
        lines.append('  String get %s;' % key)
    block = '\n'.join(lines).replace('\n', nl.decode('utf-8'))

    text = text[:end] + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    print('BASE app_localizations.dart +%d keys' % len(KEYS))


def insert_locale(lang):
    path = os.path.join(GEN_DIR, 'app_localizations_%s.dart' % lang)
    data = read_bytes(path)
    nl = b'\r\n' if b'\r\n' in data else b'\n'
    text = data.decode('utf-8')

    anchor = "  String get crypt_settings_title => '"
    occurrences = []
    pos = text.find(anchor)
    while pos >= 0:
        occurrences.append(pos)
        pos = text.find(anchor, pos + 1)
    if not occurrences:
        raise SystemExit('anchor not found in %s' % path)

    tables = [LANGS[lang]] if len(occurrences) == 1 else [ZH, ZH_TW]
    if len(occurrences) > 2:
        raise SystemExit('unexpected %d occurrences in %s' % (len(occurrences), path))

    for i in range(len(occurrences) - 1, -1, -1):
        start = occurrences[i]
        end = text.find("';", start)
        if end < 0:
            raise SystemExit('end not found in %s' % path)
        end += len("';")
        table = tables[i]
        lines = []
        for key in KEYS:
            lines.append('')
            lines.append('  @override')
            lines.append("  String get %s => '%s';" % (key, esc(table[key])))
        block = '\n'.join(lines).replace('\n', nl.decode('utf-8'))
        text = text[:end] + block + text[end:]

    write_bytes(path, text.encode('utf-8'))
    print('DART %-8s +%d keys (x%d)' % (lang, len(KEYS), len(occurrences)))


def main():
    for lang in sorted(LANGS.keys()):
        insert_arb(lang, LANGS[lang])
    insert_base()
    for lang in DART_LOCALES:
        insert_locale(lang)
    print('done')


if __name__ == '__main__':
    sys.exit(main())
