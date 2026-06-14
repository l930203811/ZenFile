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

  static String formatDate(DateTime date, {bool use24Hour = true}) {
    final timePattern = use24Hour ? 'HH:mm' : 'hh:mm a';
    return DateFormat('MMM dd, yyyy  $timePattern').format(date);
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
    if (isArchive(path)) return Colors.orange.shade700;
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
