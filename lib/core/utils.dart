import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';
import 'icon_fonts/broken_icons.dart';

class FileUtils {
  static String formatBytes(int bytes, int decimals) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = 0;
    double b = bytes.toDouble();
    while (b > 1024) {
      b /= 1024;
      i++;
    }
    return '${b.toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  /// 紧凑文件大小（双窗口分屏使用）：去掉单位与数字间的空格，并去掉 KB/MB 中的 B，
  /// 例如 117.6 KB → 117.6K、68.1 MB → 68.1M，进一步节省水平空间。
  static String formatBytesCompact(int bytes, int decimals) {
    if (bytes <= 0) return "0B";
    const suffixes = ["B", "K", "M", "G", "T", "P", "E", "Z", "Y"];
    var i = 0;
    double b = bytes.toDouble();
    while (b > 1024) {
      b /= 1024;
      i++;
    }
    return '${b.toStringAsFixed(decimals)}${suffixes[i]}';
  }

  static String formatDate(DateTime date, {bool use24Hour = true}) {
    final timePattern = use24Hour ? 'HH:mm' : 'hh:mm a';
    return DateFormat('yyyy-MM-dd  $timePattern').format(date);
  }

  /// 紧凑日期（对标 MT 管理器）：今年内「yy-MM-dd HH:mm」（两位年份），
  /// 跨年「yy-MM-dd」（省时间）。比 yyyy-MM-dd HH:mm 短 2~6 字符，
  /// 让日期+时间+文件大小在同一行都能完整显示。
  static String formatDateShort(DateTime date, {bool use24Hour = true}) {
    final now = DateTime.now();
    final timePattern = use24Hour ? 'HH:mm' : 'hh:mm a';
    if (date.year == now.year) {
      return DateFormat('yy-MM-dd $timePattern').format(date);
    }
    return DateFormat('yy-MM-dd').format(date);
  }

  /// 超紧凑日期（双窗口分屏使用）：今年内省略年份只保留「MM-dd HH:mm」，
  /// 跨年仍显示「yy-MM-dd」。在窄 pane 下仍能保证日期+时间+大小完整显示。
  static String formatDateCompact(DateTime date, {bool use24Hour = true}) {
    final now = DateTime.now();
    final timePattern = use24Hour ? 'HH:mm' : 'hh:mm a';
    if (date.year == now.year) {
      return DateFormat('MM-dd $timePattern').format(date);
    }
    return DateFormat('yy-MM-dd').format(date);
  }

  /// 判断艺术家字符串是否为未知（null、空、或 "unknown"/"<unknown>" 等变体）。
  /// 音频插件 on_audio_query 在缺少元数据时会返回此类占位符。
  static bool isUnknownArtist(String? artist) {
    if (artist == null || artist.isEmpty) return true;
    final normalized = artist.replaceAll('<', '').replaceAll('>', '').trim().toLowerCase();
    return normalized == 'unknown' || normalized.isEmpty;
  }

  static bool isArchive(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.zip') ||
        lower.endsWith('.tar') ||
        lower.endsWith('.tar.gz') ||
        lower.endsWith('.tgz') ||
        lower.endsWith('.tar.bz2') ||
        lower.endsWith('.tbz2') ||
        lower.endsWith('.tar.lz4') ||
        lower.endsWith('.tlz4') ||
        lower.endsWith('.lz4') ||
        lower.endsWith('.tar.zst') ||
        lower.endsWith('.tzst') ||
        lower.endsWith('.zst') ||
        lower.endsWith('.zstd') ||
        lower.endsWith('.gz') ||
        lower.endsWith('.bz2') ||
        lower.endsWith('.7z') ||
        lower.endsWith('.rar') ||
        lower.endsWith('.001');
  }

  /// 返回压缩包格式的简短标签（大写），用于图标显示。
  /// 例如 .zip → "ZIP"，.7z → "7Z"，.tar.gz → "TAR.GZ"
  static String getArchiveTypeLabel(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) return 'GZ';
    if (lower.endsWith('.tar.bz2') || lower.endsWith('.tbz2')) return 'BZ2';
    if (lower.endsWith('.tar.lz4') || lower.endsWith('.tlz4')) return 'LZ4';
    if (lower.endsWith('.tar.zst') || lower.endsWith('.tzst')) return 'ZST';
    // 单扩展名
    final ext = lower.split('.').last;
    switch (ext) {
      case 'zip': return 'ZIP';
      case '7z': return '7Z';
      case 'rar': return 'RAR';
      case 'tar': return 'TAR';
      case 'gz': return 'GZ';
      case 'bz2': return 'BZ2';
      case 'xz': return 'XZ';
      case 'zst':
      case 'zstd': return 'ZST';
      case 'lz4': return 'LZ4';
      case 'iso': return 'ISO';
      case 'cab': return 'CAB';
      case '001': return '001';
      default: return ext.toUpperCase();
    }
  }

  static bool isTextOrCode(String path) {
    final lower = path.toLowerCase();
    
    // Fallback for files without extension (e.g. hosts)
    final filename = path.split('/').last.split('\\').last;
    if (!filename.contains('.') && filename.isNotEmpty) {
      return true;
    }

    const exts = [
      '.txt', '.md', '.json', '.xml', '.py', '.js', '.ts', '.dart', '.html', '.css',
      '.scss', '.java', '.kt', '.cpp', '.c', '.h', '.hpp', '.cs', '.php', '.rb', '.go',
      '.rs', '.swift', '.sql', '.yaml', '.yml', '.ini', '.cfg', '.conf', '.sh', '.bat',
      '.ps1', '.cmd', '.env', '.log', '.csv', '.tsv', '.properties', '.gradle', '.pom', '.err'
    ];
    for (final ext in exts) {
      if (lower.endsWith(ext)) return true;
    }
    final mime = lookupMimeType(path);
    return mime != null && mime.startsWith('text/');
  }

  static bool isImage(String path) {
    final lower = path.toLowerCase();

    if (lower.endsWith('.3ds') ||
        lower.endsWith('.svg') ||
        lower.endsWith('.psd') ||
        lower.endsWith('.tiff') ||
        lower.endsWith('.tif') ||
        lower.endsWith('.xcf')) {
      return false;
    }
    final mimeType = lookupMimeType(path);
    if (mimeType != null && mimeType.startsWith('image/')) {
      final lowerMime = mimeType.toLowerCase();
      if (lowerMime.contains('x-3ds') ||
          lowerMime.contains('svg') ||
          lowerMime.contains('photoshop') ||
          lowerMime.contains('tiff') ||
          lowerMime.contains('xcf') ||
          lowerMime.contains('gimp')) {
        return false;
      }
      return true;
    }
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.avif') ||
        lower.endsWith('.heic') ||
        lower.endsWith('.heif');
  }

  static bool isVideo(String path) {
    final mimeType = lookupMimeType(path);
    if (mimeType != null && mimeType.startsWith('video/')) return true;
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') || lower.endsWith('.ts') || lower.endsWith('.mts') || lower.endsWith('.mkv') || lower.endsWith('.webm') || lower.endsWith('.avi') || lower.endsWith('.mov') || lower.endsWith('.flv');
  }

  static bool isAudio(String path) {
    final mimeType = lookupMimeType(path);
    if (mimeType != null && mimeType.startsWith('audio/')) return true;
    final lower = path.toLowerCase();
    return lower.endsWith('.mp3') || lower.endsWith('.wav') || lower.endsWith('.m4a') || lower.endsWith('.ogg') || lower.endsWith('.flac') || lower.endsWith('.aac') || lower.endsWith('.wma') || lower.endsWith('.opus');
  }

  /// 判断是否为文档文件（非图片/视频/音频/压缩包/APK）
  static bool isDocument(String path) {
    if (isImage(path) || isVideo(path) || isAudio(path) || isArchive(path)) return false;
    final lower = path.toLowerCase();
    final ext = lower.split('.').last;
    const docExts = [
      'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
      'txt', 'md', 'json', 'xml', 'html', 'htm', 'csv',
      'log', 'yaml', 'yml', 'ini', 'cfg', 'conf', 'properties',
      'py', 'js', 'ts', 'dart', 'java', 'kt', 'cpp', 'c', 'h',
      'hpp', 'cs', 'php', 'rb', 'go', 'rs', 'swift', 'sql',
      'sh', 'bat', 'cmd', 'ps1', 'env', 'gradle',
    ];
    return docExts.contains(ext);
  }

  /// 取文件名扩展名（含点，小写），无扩展名返回空串。
  static String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot).toLowerCase();
  }

  /// 分类同步用：文档扩展名集合（与 MediaProvider 扫描一致）。
  static const List<String> syncDocumentExtensions = [
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.txt', '.csv', '.odt', '.ods', '.odp', '.rtf', '.epub',
  ];
  static const List<String> syncArchiveExtensions = ['.zip', '.tar', '.gz', '.bz2', '.rar', '.7z'];
  static const List<String> syncApkExtensions = ['.apk', '.xapk', '.apks', '.aab'];

  static bool isSyncDocumentFile(String name) => syncDocumentExtensions.contains(_extOf(name));
  static bool isSyncArchiveFile(String name) => syncArchiveExtensions.contains(_extOf(name));
  static bool isSyncApkFile(String name) => syncApkExtensions.contains(_extOf(name));

  /// 返回某类别（中文标签）的「文件名过滤器」，用于远程→本地同步时只下载该类别识别的文件。
  /// 与 MediaProvider 的扫描过滤保持一致。
  static bool Function(String name) categoryFileFilter(String categoryLabel) {
    switch (categoryLabel) {
      case '图片':
      case '截图':
        return (name) => name.toLowerCase().endsWith('.svg') || isImage(name);
      case '视频':
        return isVideo;
      case '音频':
        return isAudio;
      case '文档':
        return isSyncDocumentFile;
      case '压缩包':
        return isSyncArchiveFile;
      case '安装包':
        return isSyncApkFile;
      case '下载':
      default:
        return (_) => true;
    }
  }

  /// 返回图片格式的简短标签（大写），用于图标显示。
  /// 例如 .jpg → "JPG"，.png → "PNG"
  static String getImageTypeLabel(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'JPG';
    if (lower.endsWith('.png')) return 'PNG';
    if (lower.endsWith('.webp')) return 'WEBP';
    if (lower.endsWith('.gif')) return 'GIF';
    if (lower.endsWith('.bmp')) return 'BMP';
    if (lower.endsWith('.avif')) return 'AVIF';
    if (lower.endsWith('.heic')) return 'HEIC';
    if (lower.endsWith('.heif')) return 'HEIF';
    // 兜底：取扩展名大写
    final ext = lower.split('.').last;
    return ext.length <= 4 ? ext.toUpperCase() : ext.substring(0, 4).toUpperCase();
  }

  /// 返回文档格式的简短标签（大写），用于图标显示。
  /// 例如 .pdf → "PDF"，.docx → "DOCX"
  static String getDocumentTypeLabel(String path) {
    final lower = path.toLowerCase();
    final ext = lower.split('.').last;
    return ext.length <= 4 ? ext.toUpperCase() : ext.substring(0, 4).toUpperCase();
  }

  static IconData getIconForFile(String path) {
    final ext = path.split('.').last.toLowerCase();
    if (isArchive(path)) return Broken.box;
    if (isImage(path)) return Broken.image;
    if (isVideo(path)) return Broken.video;
    if (isAudio(path)) return Broken.music;
    
    // 文档格式
    switch (ext) {
      case 'pdf': return Broken.document;
      case 'doc': case 'docx': return Broken.document;
      case 'xls': case 'xlsx': return Icons.table_chart;
      case 'ppt': case 'pptx': return Icons.slideshow;
      case 'txt': return Icons.description_outlined;
      case 'md': return Icons.article_outlined;
      case 'json': return Icons.data_object;
      case 'xml': return Icons.code;
      case 'html': case 'htm': return Icons.web;
      case 'csv': return Icons.table_chart;
      case 'log': return Icons.receipt_long;
      case 'db': case 'sqlite': case 'sqlite3': return Icons.storage;
      case 'apk': case 'aab': return Broken.mobile;
      case 'sh': case 'bat': case 'cmd': return Icons.terminal;
      case 'py': case 'js': case 'ts': case 'dart': case 'java': case 'kt': case 'cpp': case 'c': case 'h': case 'hpp': case 'cs': case 'php': case 'rb': case 'go': case 'rs': case 'swift': return Icons.code;
      case 'sql': return Icons.storage_outlined;
      case 'yaml': case 'yml': return Icons.settings;
      case 'exe': case 'msi': return Icons.settings_applications;
      case 'zip': case 'rar': case '7z': return Broken.box;
    }
    
    if (isTextOrCode(path)) return Icons.description_outlined;
    
    // 未知格式
    return Icons.insert_drive_file_outlined;
  }
  
  static Color getColorForFile(String path, BuildContext context) {
    final ext = path.split('.').last.toLowerCase();
    if (isImage(path)) return Colors.purple;
    if (isVideo(path)) return Colors.red.shade700;
    if (isAudio(path)) return Colors.teal.shade700;
    
    switch (ext) {
      case 'pdf': return Colors.red.shade700;
      case 'doc': case 'docx': return Colors.blue.shade700;
      case 'xls': case 'xlsx': return Colors.green.shade700;
      case 'ppt': case 'pptx': return Colors.orange.shade700;
      case 'txt': return Colors.blue.shade700;
      case 'md': return Colors.grey.shade700;
      case 'json': return Colors.amber.shade700;
      case 'xml': return Colors.orange.shade600;
      case 'html': case 'htm': return Colors.orange;
      case 'csv': return Colors.green.shade600;
      case 'db': case 'sqlite': case 'sqlite3': return Colors.indigo;
      case 'apk': case 'aab': return Colors.green;
      case 'sh': case 'bat': case 'cmd': return Colors.grey.shade700;
      case 'py': case 'js': case 'ts': case 'dart': case 'java': case 'kt': case 'cpp': case 'c': case 'h': case 'hpp': case 'cs': case 'php': case 'rb': case 'go': case 'rs': case 'swift': return Colors.cyan.shade700;
      case 'sql': return Colors.blue.shade600;
      case 'yaml': case 'yml': return Colors.pink.shade600;
      case 'exe': case 'msi': return Colors.blue.shade800;
      case 'log': return Colors.grey;
      // 压缩包格式 - 不同格式不同颜色
      case 'zip': return Colors.orange.shade700;
      case 'rar': return Colors.red.shade700;
      case '7z': return Colors.purple.shade700;
      case 'tar': return Colors.brown.shade700;
      case 'gz': return Colors.green.shade700;
      case 'bz2': return Colors.blue.shade700;
      case 'xz': return Colors.cyan.shade700;
      case 'iso': return Colors.grey.shade700;
      case 'cab': return Colors.indigo.shade700;
      case 'deb': return Colors.orange.shade600;
      case 'rpm': return Colors.red.shade600;
      case 'dmg': return Colors.blueGrey.shade700;
      case 'wim': return Colors.teal.shade600;
    }
    
    if (isTextOrCode(path)) return Colors.blue.shade700;
    
    // 未知格式
    return Colors.grey.shade500;
  }

  static IconData getFolderIcon(String option) {
    switch (option) {
      case 'solid': return Icons.folder;
      case 'rounded': return Icons.folder_rounded;
      case 'special': return Icons.folder_special_rounded;
      case 'snippet': return Icons.snippet_folder_rounded;
      case 'outlined': return Icons.folder_outlined;
      case 'broken':
      default:
        return Broken.folder;
    }
  }

  static int compareNatural(String a, String b) {
    int i = 0;
    int j = 0;
    
    final aLower = a.toLowerCase();
    final bLower = b.toLowerCase();

    while (i < aLower.length && j < bLower.length) {
      int charA = aLower.codeUnitAt(i);
      int charB = bLower.codeUnitAt(j);

      if (_isDigit(charA) && _isDigit(charB)) {
        int startA = i;
        while (i < aLower.length && _isDigit(aLower.codeUnitAt(i))) {
          i++;
        }
        int startB = j;
        while (j < bLower.length && _isDigit(bLower.codeUnitAt(j))) {
          j++;
        }

        String subA = aLower.substring(startA, i);
        String subB = bLower.substring(startB, j);

        BigInt? numA = BigInt.tryParse(subA);
        BigInt? numB = BigInt.tryParse(subB);

        if (numA != null && numB != null) {
          int cmp = numA.compareTo(numB);
          if (cmp != 0) return cmp;
          if (subA.length != subB.length) {
            return subA.length.compareTo(subB.length);
          }
        } else {
          int cmp = subA.compareTo(subB);
          if (cmp != 0) return cmp;
        }
      } else {
        if (charA != charB) {
          return charA.compareTo(charB);
        }
        i++;
        j++;
      }
    }

    if (i < aLower.length) return 1;
    if (j < bLower.length) return -1;
    return a.compareTo(b);
  }

  static bool _isDigit(int codeUnit) {
    return codeUnit >= 48 && codeUnit <= 57;
  }
}
