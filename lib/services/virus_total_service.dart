import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'preferences_service.dart';

/// VirusTotal 扫描结果。
class VirusTotalResult {
  final bool found; // 是否已在 VT 数据库中
  final int malicious; // 报毒引擎数
  final int suspicious; // 可疑引擎数
  final int harmless; // 安全引擎数
  final int undetected; // 未检测引擎数
  final String? scanDate; // 最近扫描日期
  final String sha256; // 文件 SHA-256
  final String? permalink; // VT 报告链接
  final String? error; // 错误信息（如有）

  const VirusTotalResult({
    required this.found,
    this.malicious = 0,
    this.suspicious = 0,
    this.harmless = 0,
    this.undetected = 0,
    this.scanDate,
    required this.sha256,
    this.permalink,
    this.error,
  });

  /// 安全评级：true=安全，false=有风险
  bool get isSafe => found && malicious == 0 && suspicious == 0;

  /// 总检测引擎数
  int get totalEngines => malicious + suspicious + harmless + undetected;

  /// 危险等级描述
  String get riskLevel {
    if (!found) return '未收录';
    if (malicious > 0) return '危险 ($malicious 引擎报毒)';
    if (suspicious > 0) return '可疑';
    return '安全';
  }
}

/// VirusTotal API v3 服务：APK 安全扫描。
/// 用户需提供自己的 API Key（免费版限制 4 请求/分钟）。
class VirusTotalService {
  static const String _baseUrl = 'https://www.virustotal.com/api/v3';

  /// 获取用户保存的 API Key。
  static String? getApiKey() {
    return PreferencesService.getVirusTotalApiKey();
  }

  /// 保存用户的 API Key。
  static Future<void> saveApiKey(String key) async {
    await PreferencesService.saveVirusTotalApiKey(key);
  }

  /// 计算文件的 SHA-256 哈希。
  static Future<String> computeSha256(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  /// 使用文件哈希查询 VirusTotal（无需上传文件，节省时间和流量）。
  static Future<VirusTotalResult> queryByHash(String sha256, {String? apiKey}) async {
    final key = apiKey ?? getApiKey();
    if (key == null || key.isEmpty) {
      return VirusTotalResult(
        found: false,
        sha256: sha256,
        error: '请先在设置中配置 VirusTotal API Key',
      );
    }

    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 30);

      final uri = Uri.parse('$_baseUrl/files/$sha256');
      final request = await client.getUrl(uri);
      request.headers.set('x-apikey', key);
      request.headers.set('Accept', 'application/json');

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        final attrs = data['data']?['attributes'] as Map<String, dynamic>?;
        final lastAnalysis = attrs?['last_analysis_stats'] as Map<String, dynamic>?;

        return VirusTotalResult(
          found: true,
          sha256: sha256,
          malicious: (lastAnalysis?['malicious'] as num?)?.toInt() ?? 0,
          suspicious: (lastAnalysis?['suspicious'] as num?)?.toInt() ?? 0,
          harmless: (lastAnalysis?['harmless'] as num?)?.toInt() ?? 0,
          undetected: (lastAnalysis?['undetected'] as num?)?.toInt() ?? 0,
          scanDate: attrs?['last_analysis_date']?.toString(),
          permalink: 'https://www.virustotal.com/gui/file/$sha256',
        );
      } else if (response.statusCode == 404) {
        return VirusTotalResult(found: false, sha256: sha256);
      } else {
        return VirusTotalResult(
          found: false,
          sha256: sha256,
          error: 'API 错误: HTTP ${response.statusCode}',
        );
      }
    } catch (e) {
      return VirusTotalResult(
        found: false,
        sha256: sha256,
        error: '网络错误: ${e.toString()}',
      );
    } finally {
      client?.close();
    }
  }

  /// 扫描 APK 文件：计算哈希后查询 VT。
  static Future<VirusTotalResult> scanFile(String filePath, {String? apiKey}) async {
    final sha256 = await computeSha256(filePath);
    return queryByHash(sha256, apiKey: apiKey);
  }

  /// 验证 API Key 是否有效。
  static Future<bool> validateApiKey(String apiKey) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);

      final uri = Uri.parse('$_baseUrl/users/$apiKey');
      final request = await client.getUrl(uri);
      request.headers.set('x-apikey', apiKey);

      final response = await request.close();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client?.close();
    }
  }
}
