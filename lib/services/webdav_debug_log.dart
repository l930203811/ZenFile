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
  /// 2026-09-23 v2.1.6 发版：已改回 false。
  /// 2026-09-27「音频和视频都开启后台播放后，播放视频会崩溃闪退」排查期间**再次
  /// 开启**：10 份崩溃报告全是 `CRASH_NATIVE` 且系统不提供 trace（无 adb），只能靠
  /// `ZenFileAudioHandler` 在 attach / 退役 / detach 各关键动作落盘的 `[bg]` 序列，
  /// 判断崩溃前**最后执行到哪一步**。⚠️ **发版前必须改回 false**。
  /// 2026-09-28 v3.2.0 发版：已改回 false。
  /// 🔴 **血的教训（务必看完再动这个开关）**：本开关不只是「要不要往 SD 卡写日志」，
  /// 它**曾**同时决定 `MpvAudioOutputService` 的 AO 延迟回读诊断是否运行
  /// （2026-09-28 已解耦到 [aoDiagnostics]）；该诊断走
  /// **裸原生 `getProperty`**，且有「8s 兜底 + 内层 3s」的最长 **11 秒窗口**；player
  /// 一旦在此期间被销毁就是 use-after-free（`CRASH_NATIVE` 且无栈，`try/catch` 抓不住）。
  /// ⇒ **（解耦前）开着它发布出去的每个包，都自带「播放中偶发闪退」的悬垂窗口**，
  /// 而它的存在感又极低（只在本文件的 webdav_debug.log 里留痕）。
  /// ⇒ 任何情况下：**发版前必须回到 false，且要 grep 复核，
  ///   不要相信 WORKLOG / memory 里「应该已经关了」的文字描述。**
  /// ⚠️⚠️ **2026-09-28 起临时置 true**：视频后台播放「反复进出播放页崩溃」的
  /// 取证构建。取完日志（`/storage/emulated/0/ZenFile/webdav_debug.log` 与
  /// `.prev` **一起**取）**必须改回 false 再发版**，并 grep 复核 ——
  /// 不要相信 WORKLOG / memory 里「应该已经关了」的文字描述。
  /// 2026-09-28 晚：真机复测 `7204ac6`（接管退役）后**用户确认不再崩溃** ⇒
  /// 取证结束，**已改回 false**。
  ///
  /// 与 AO 诊断**已解耦**（见 [aoDiagnostics]）：打开本开关不再顺手装上那条
  /// 11 秒的裸原生悬垂窗口，所以取证包不会再自带崩因、不会把取证引向错误结论。
  /// 2026-09-30 网盘取证期间曾临时置 true 采集 `[netdisk:*]` 序列；
  /// **发版前已按红线改回 false**（今后每次取证结束都要改回并 grep 复核）。
  /// 2026-10-29 音频频谱（Visualizer FFT）排查期间曾临时置 true；
  /// **取证结束已按红线改回 false**。
  /// 与 [aoDiagnostics] 已解耦 ⇒ 打开它也不会带上那条 11 秒的裸原生悬垂窗口。
  /// ⚠️⚠️ **2026-10-29 20:10 曾临时置 true**：频谱可视化改「波形采集 +
  /// Dart 自算 FFT」链路的取证构建（采集波形 min/max/avg 与解码后 bins 采样）。
  /// **2026-10-29 发版前已改回 false 并 grep 复核。**
  static bool enabled = false; // 2026-10-29 频谱取证完毕（波形+自算 FFT 链路验证通过），按红线改回 false

  /// AO（音频输出）延迟回读诊断的**独立开关**，默认关闭。
  ///
  /// ## 为什么必须与 [enabled] 拆开（2026-09-28 血的教训）
  ///
  /// `MpvAudioOutputService.schedulePlaybackDiagnostics` 会挂
  /// 「8s 兜底 + 内层 3s」最长 **11 秒**的延迟回读窗口，且走**裸原生 `getProperty`**；
  /// player 一旦在此期间被销毁就是 use-after-free（`CRASH_NATIVE`、系统不给 trace、
  /// `try/catch` 抓不住 native 段错误）。
  /// 原先两者**共用 `enabled` 一个开关** ⇒ 为了抓崩溃而打开文件日志，会顺手把这条
  /// 悬垂窗口也装上 ⇒ 诊断包自带「播放中偶发闪退」的崩因，取证时极易得出
  /// 「上一轮修复无效」的错误结论。
  /// ⇒ 抓崩溃只开 [enabled]；查 AO 才额外把本开关置 true（两者都开才真正订阅）。
  static bool aoDiagnostics = false;

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

  /// 启动时把**上一次运行**的日志另存为 `webdav_debug.log.prev`。
  ///
  /// ## 为什么必须保全现场
  ///
  /// 本项目要定位的崩溃是 **native 段错误**（`CRASH_NATIVE`），进程当场死掉，
  /// 系统不给 trace —— 此时**日志的最后一行就是崩溃前最后执行的语句**，是
  /// 无 adb 环境下唯一能回答「崩在哪一步」的依据。
  ///
  /// 但崩溃后用户必然会**重新打开应用**看结果，而 `[boot]` 序列会立刻往同一个
  /// 文件继续追加，把真正的现场越埋越深（2026-09-27 真机里就出现过「日志里只剩
  /// 一次 boot、`[bg]` 一行都没有」的情况，导致这一轮只能靠推理定位）。
  /// 于是每次启动先把现有内容**复制**一份到 `.prev`：
  /// * `.log` 保持连续（不丢历史，也不会让文件管理器看不到主日志）；
  /// * `.prev` 恒为「**本次启动之前**那一段」，即崩溃现场。
  ///
  /// 只保留一代（每次都覆盖）。取日志时请把 `webdav_debug.log` 与
  /// `webdav_debug.log.prev` **一起**取走。
  static void snapshotPrevious() {
    if (!enabled) return;
    try {
      final file = File(filePath);
      if (!file.existsSync() || file.lengthSync() == 0) return;
      final prev = File('$filePath.prev');
      if (prev.existsSync()) {
        prev.deleteSync();
      }
      file.copySync(prev.path);
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
