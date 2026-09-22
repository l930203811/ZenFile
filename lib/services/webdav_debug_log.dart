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
  ///
  /// 排查远程加密（cryptremote）播放问题期间曾临时打开，问题已解决并改回 false。
  /// 2026-09-15 起复用为**通用诊断日志**：Android/{data,obb} 受限目录的
  /// 新建/写入失败（root_shizuku_service）也会经此落盘，便于无 adb 环境下
  /// 直接取出 shell 命令与 stderr。排查结束后务必改回 false 再发版。
  /// 2026-09-15 视频黑屏诊断期间临时开启：用于采集黑屏机型播放器错误与
  /// 自动回退判定记录；黑屏问题定位并解决后务必改回 false。
  /// 2026-09-16 远程 SMB/FTP/SFTP 播放卡顿三次修复（顺序流式→Range 反代块缓存
  /// →0 字节响应修复）期间开启，用户实测已解决，现改回 false。
  /// 2026-09-23 RootlessJamesDSP「不兼容」排查期间**重新开启**：需要采集
  /// 「实际生效的 mpv 音频输出（AO）」等运行期证据（见
  /// `MpvAudioOutputService`）。⚠️ **发版前必须改回 false**。
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
