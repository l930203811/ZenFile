import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'crash_forensics_service.dart';
import 'preferences_service.dart';

/// 一份待上传的诊断日志。
class CrashLogFile {
  const CrashLogFile({required this.name, required this.content});

  /// 文件名（含崩溃时间戳，天然唯一）。
  final String name;

  /// 截断后的文本内容。
  final String content;
}

/// 用户反馈 / 崩溃日志上传服务。
///
/// 端点是部署在 Cloudflare Workers 上的转发器（`zenfile-feedback`）：收到报告后
/// 自动创建为 GitHub 仓库 Issue，无需自建数据库。仓库与 Workers 配置见
/// 项目外 `D:\Xiangmu\zenfile-feedback-worker\`。
///
/// 安全设计：
///  * 纯旁路 —— 所有 IO/网络都吞异常，上传失败绝不影响主流程；
///  * 端点 / 令牌为空（未部署）时 [upload] 直接返回 false，界面不会报错；
///  * 日志按份截断 + 总量封顶，防止巨型 tombstone 拖垮请求。
abstract final class CrashReportUploadService {
  /// 反馈端点（Workers 转发器，收到报告创建为仓库 GitHub Issue）。
  static const String endpoint =
      'https://feedback.poach.dpdns.org/report';

  /// 共享令牌，与服务端 `REPORT_TOKEN` 一致（防滥用，非强机密）。
  static const String token = '4001a0dcd58ecfbe8239dd1b75fa7de1';

  /// 单份日志最多上传的字符数（tombstone 全文 ~180KB，尾部大头是线程快照）。
  static const int _maxCharsPerFile = 80000;

  /// 单次上传的日志总字符数上限。
  static const int _maxTotalChars = 300000;

  /// 单次上传的日志份数上限（取最新的）。
  static const int _maxFiles = 6;

  /// 公共归档目录里所有诊断报告的前缀（含 xCrash 的 tombstone）。
  static const List<String> _prefixes = [
    'exit_',
    'java_crash_',
    'tombstone_',
    'dart_error_',
  ];

  static bool get _configured => endpoint.isNotEmpty && token.isNotEmpty;

  /// 列出公共归档目录里的诊断报告名（升序 = 按崩溃时间）。
  ///
  /// 自行列目录而不是复用 [CrashForensicsService.listAllReports]：那个只认
  /// `.txt`，会漏掉 xCrash 的 `tombstone_*.xcrash` —— 恰恰是最有价值的堆栈。
  static List<String> listReportNames() {
    try {
      final dir = Directory(CrashForensicsService.publicDir);
      if (!dir.existsSync()) return const <String>[];
      return dir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((n) => _prefixes.any((pre) => n.startsWith(pre)))
          .toList()
        ..sort();
    } catch (_) {
      return const <String>[];
    }
  }

  /// 从 [names] 里挑出**尚未上传过**的（比对持久化台账）。
  static List<String> filterUnuploaded(List<String> names) {
    if (names.isEmpty) return const <String>[];
    final uploaded = PreferencesService.getUploadedCrashReports().toSet();
    return names.where((n) => !uploaded.contains(n)).toList();
  }

  /// 读取并截断日志内容。纯读文件，失败跳过该份。
  static Future<List<CrashLogFile>> _readLogs(List<String> names) async {
    final logs = <CrashLogFile>[];
    var total = 0;
    // 只取最新的 [_maxFiles] 份
    final picked = names.length <= _maxFiles
        ? names
        : names.sublist(names.length - _maxFiles);
    for (final name in picked) {
      if (total >= _maxTotalChars) break;
      try {
        final file = File(p.join(CrashForensicsService.publicDir, name));
        if (!file.existsSync()) continue;
        var content = file.readAsStringSync();
        final budget = min(_maxCharsPerFile, _maxTotalChars - total);
        if (content.length > budget) {
          // 保头弃尾：报告头部有信号/机型/版本，尾部多为线程快照
          content = content.substring(0, budget);
        }
        total += content.length;
        logs.add(CrashLogFile(name: name, content: content));
      } catch (e) {
        debugPrint('[Feedback] Skip log $name: $e');
      }
    }
    return logs;
  }

  /// 上报反馈到 Workers 端点。
  ///
  /// [includeLogs] 为 true 时附带 [logNames] 对应的日志内容（自动剔除已上传
  /// 与缺失的）；[extraMeta] 是附加的环境描述行（机型/版本等）。
  /// 成功返回 true 并把日志名记入「已上传」台账。
  static Future<bool> upload({
    required String description,
    required String kind, // 'crash' | 'feedback'
    String? extraMeta,
    bool includeLogs = false,
    List<String> logNames = const <String>[],
  }) async {
    if (!_configured) {
      debugPrint('[Feedback] Endpoint not configured, skip upload');
      return false;
    }
    try {
      final logs = includeLogs
          ? await _readLogs(filterUnuploaded(logNames))
          : const <CrashLogFile>[];
      final payload = jsonEncode(<String, dynamic>{
        'type': kind,
        'description': description.trim().substring(
          0,
          description.trim().length.clamp(0, 4000),
        ),
        'meta': (extraMeta ?? '').substring(
          0,
          (extraMeta ?? '').length.clamp(0, 2000),
        ),
        'logs': [
          for (final l in logs)
            <String, String>{'name': l.name, 'content': l.content},
        ],
      });

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final req = await client.postUrl(Uri.parse(endpoint));
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.headers.set('X-Report-Token', token);
        req.add(utf8.encode(payload));
        final res = await req.close().timeout(const Duration(seconds: 30));
        await res.drain<void>();
        if (res.statusCode != 200) {
          debugPrint('[Feedback] Upload failed: HTTP ${res.statusCode}');
          return false;
        }
      } finally {
        client.close(force: true);
      }

      if (logs.isNotEmpty) {
        await PreferencesService.saveUploadedCrashReports(<String>[
          ...PreferencesService.getUploadedCrashReports(),
          ...logs.map((l) => l.name),
        ]);
      }
      debugPrint('[Feedback] Uploaded (${logs.length} logs)');
      return true;
    } catch (e) {
      debugPrint('[Feedback] Upload error: $e');
      return false;
    }
  }
}
