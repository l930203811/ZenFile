import 'dart:io';

/// WebDAV / 远程流式播放诊断日志。
///
/// 直接追加写到 `/storage/emulated/0/ZenFile/webdav_debug.log`，用于无法使用
/// USB / adb（如云电脑环境）时，用任意文件管理器即可取出日志。
///
/// 设计约束：
/// * 绝不能因写日志而影响主流程 —— 所有异常一律吞掉；
/// * release 包同样输出（不依赖 debugPrint / adb）；
/// * 文件超过 [_maxBytes] 自动清空重写，避免长期增长占满存储；
/// * 自动脱敏 URL 中的 `user:pass@` 凭据，避免日志泄露密码。
class WebdavDebugLog {
  WebdavDebugLog._();

  /// 日志文件路径（与 App 既有的 /storage/emulated/0/ZenFile 目录一致）。
  static const String filePath = '/storage/emulated/0/ZenFile/webdav_debug.log';

  /// 超过此大小（2MB）则清空重写。
  static const int _maxBytes = 2 * 1024 * 1024;

  /// 总开关。排查完毕可在发布前置 false（保留代码便于下次排查）。
  static bool enabled = true;

  /// 写入一行日志（同步落盘，保证崩溃前也已写入）。
  static void log(String msg) {
    if (!enabled) return;
    try {
      final file = File(filePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        file.writeAsStringSync('', mode: FileMode.write, flush: true);
      }
      final ts = DateTime.now().toIso8601String();
      final line = '[$ts] $msg\n';
      file.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志绝不能影响主流程
    }
  }

  /// 清空日志（每次开始新的排查时可调用）。
  static void clear() {
    try {
      final file = File(filePath);
      if (file.parent.existsSync()) {
        file.writeAsStringSync('', mode: FileMode.write, flush: true);
      }
    } catch (_) {}
  }

  /// 脱敏：把 `scheme://user:pass@host` 中的凭据替换为 `***:***`。
  static String mask(String text) {
    try {
      return text.replaceAllMapped(
        RegExp(r'(https?://)([^/@\s]+):([^/@\s]+)@'),
        (m) => '${m.group(1)}***:***@',
      );
    } catch (_) {
      return text;
    }
  }
}
