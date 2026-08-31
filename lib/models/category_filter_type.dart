import 'package:flutter/material.dart';
import '../core/icon_fonts/broken_icons.dart';
import '../core/utils.dart';
import '../l10n/generated/app_localizations.dart';
import 'file_item_model.dart';

/// 浏览页按类别过滤的枚举。
/// `none` 表示不过滤，保留所有文件与文件夹。
enum CategoryFilterType {
  none,
  images,
  videos,
  audios,
  documents,
  archives,
  apks,
  others,
}

extension CategoryFilterTypeExtension on CategoryFilterType {
  /// 显示名称，使用现有分类文案，减少重复翻译。
  String label(BuildContext context) {
    final l10n = L10n.of(context);
    switch (this) {
      case CategoryFilterType.none:
        return l10n.ui_all_files;
      case CategoryFilterType.images:
        return l10n.cat_images;
      case CategoryFilterType.videos:
        return l10n.cat_videos;
      case CategoryFilterType.audios:
        return l10n.cat_audios;
      case CategoryFilterType.documents:
        return l10n.cat_documents;
      case CategoryFilterType.archives:
        return l10n.msgc806d0fa;
      case CategoryFilterType.apks:
        return l10n.msg03070d08;
      case CategoryFilterType.others:
        return l10n.ui_filter_others;
    }
  }

  /// 对应图标。
  IconData get icon {
    switch (this) {
      case CategoryFilterType.none:
        return Broken.filter;
      case CategoryFilterType.images:
        return Broken.image;
      case CategoryFilterType.videos:
        return Broken.video;
      case CategoryFilterType.audios:
        return Broken.music;
      case CategoryFilterType.documents:
        return Broken.document;
      case CategoryFilterType.archives:
        return Broken.box;
      case CategoryFilterType.apks:
        return Icons.android_rounded;
      case CategoryFilterType.others:
        return Broken.more_circle;
    }
  }

  /// 是否匹配指定文件。文件夹始终匹配，保证导航可用。
  bool matches(FileItemModel file) {
    if (file.isDirectory) return true;
    final path = file.path;
    switch (this) {
      case CategoryFilterType.none:
        return true;
      case CategoryFilterType.images:
        return FileUtils.isImage(path);
      case CategoryFilterType.videos:
        return FileUtils.isVideo(path);
      case CategoryFilterType.audios:
        return FileUtils.isAudio(path);
      case CategoryFilterType.documents:
        return FileUtils.isDocument(path);
      case CategoryFilterType.archives:
        return FileUtils.isArchive(path);
      case CategoryFilterType.apks:
        final ext = path.toLowerCase().split('.').last;
        return ext == 'apk' || ext == 'aab';
      case CategoryFilterType.others:
        final ext = path.toLowerCase().split('.').last;
        return !FileUtils.isImage(path) &&
            !FileUtils.isVideo(path) &&
            !FileUtils.isAudio(path) &&
            !FileUtils.isDocument(path) &&
            !FileUtils.isArchive(path) &&
            ext != 'apk' &&
            ext != 'aab';
    }
  }

  /// 持久化用的字符串标识。
  String get value {
    switch (this) {
      case CategoryFilterType.none:
        return '';
      case CategoryFilterType.images:
        return 'images';
      case CategoryFilterType.videos:
        return 'videos';
      case CategoryFilterType.audios:
        return 'audios';
      case CategoryFilterType.documents:
        return 'documents';
      case CategoryFilterType.archives:
        return 'archives';
      case CategoryFilterType.apks:
        return 'apks';
      case CategoryFilterType.others:
        return 'others';
    }
  }
}

CategoryFilterType categoryFilterTypeFromString(String? value) {
  switch (value) {
    case 'images':
      return CategoryFilterType.images;
    case 'videos':
      return CategoryFilterType.videos;
    case 'audios':
      return CategoryFilterType.audios;
    case 'documents':
      return CategoryFilterType.documents;
    case 'archives':
      return CategoryFilterType.archives;
    case 'apks':
      return CategoryFilterType.apks;
    case 'others':
      return CategoryFilterType.others;
    default:
      return CategoryFilterType.none;
  }
}

/// 将逗号分隔的持久化字符串解析为多选集合。
/// 空字符串或 null 返回空集合（表示不过滤，显示全部）。
Set<CategoryFilterType> categoryFilterTypeSetFromString(String? value) {
  if (value == null || value.isEmpty) return {};
  return value
      .split(',')
      .where((s) => s.isNotEmpty)
      .map((s) => categoryFilterTypeFromString(s))
      .where((t) => t != CategoryFilterType.none)
      .toSet();
}

/// 将多选集合序列化为逗号分隔字符串用于持久化。
String categoryFilterTypesToString(Set<CategoryFilterType> set) {
  return set.map((t) => t.value).where((v) => v.isNotEmpty).join(',');
}

/// 判断文件是否匹配任一已选类别（文件夹始终匹配）。
/// [selected] 为空集合时表示不过滤。
bool matchesAnyCategory(Set<CategoryFilterType> selected, FileItemModel file) {
  if (file.isDirectory) return true;
  if (selected.isEmpty) return true;
  return selected.any((t) => t.matches(file));
}
