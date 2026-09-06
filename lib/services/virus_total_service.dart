import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
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
  /// 使用 64 位零哈希探测端点：有效 Key 返回 200/404（鉴权通过），
  /// 无效 Key 返回 401/403。
  static Future<bool> validateApiKey(String apiKey) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);

      final probe = '0000000000000000000000000000000000000000000000000000000000000000';
      final uri = Uri.parse('$_baseUrl/files/$probe');
      final request = await client.getUrl(uri);
      request.headers.set('x-apikey', apiKey);

      final response = await request.close();
      await response.drain();
      return response.statusCode == 200 || response.statusCode == 404;
    } catch (_) {
      return false;
    } finally {
      client?.close();
    }
  }

  /// 上传文件到 VirusTotal 并等待完整扫描结果。
  /// 优先直接 POST /files（走 www.virustotal.com，代理友好）；
  /// 仅当返回 413（文件过大）时，才获取 upload_url 回退上传（签名 URL，不带 x-apikey）。
  static Future<VirusTotalResult> uploadAndScan(
    String filePath, {
    String? apiKey,
    void Function(String status)? onStatus,
  }) async {
    final key = apiKey ?? getApiKey();
    if (key == null || key.isEmpty) {
      return VirusTotalResult(
        found: false,
        sha256: '',
        error: '请先在设置中配置 VirusTotal API Key',
      );
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return VirusTotalResult(found: false, sha256: '', error: '文件不存在');
    }
    final sha256 = await computeSha256(filePath);

    // 构建 multipart body（字段名固定为 file）
    onStatus?.call('uploading');
    final bytes = await file.readAsBytes();
    final boundary = '----ZenFile${DateTime.now().millisecondsSinceEpoch}';
    final rawName = filePath.split(RegExp(r'[/\\]')).last;
    final header = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="$rawName"\r\n'
      'Content-Type: application/octet-stream\r\n\r\n',
    );
    final footer = utf8.encode('\r\n--$boundary--\r\n');
    final body = BytesBuilder();
    body.add(header);
    body.add(bytes);
    body.add(footer);
    final bodyBytes = body.toBytes();

    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 60);

      String? analysisId;

      // 1. 优先直接 POST /files（走 www.virustotal.com）
      try {
        final directReq = await client.postUrl(Uri.parse('$_baseUrl/files'));
        directReq.headers.set('x-apikey', key);
        directReq.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
        directReq.contentLength = bodyBytes.length;
        directReq.add(bodyBytes);
        final directResp = await directReq.close();
        final directBody = await directResp.transform(utf8.decoder).join();

        if (directResp.statusCode == 200) {
          analysisId = (jsonDecode(directBody)['data']?['id'] as String?) ?? '';
        } else if (directResp.statusCode != 413) {
          return VirusTotalResult(
            found: false,
            sha256: sha256,
            error: '上传失败: HTTP ${directResp.statusCode}',
          );
        }
        // 413 = 文件过大，继续回退到 upload_url
      } catch (_) {
        // 直接上传异常，回退到 upload_url
      }

      // 2. 回退：获取 upload_url 并上传（签名 URL，不带 x-apikey）
      if (analysisId == null || analysisId.isEmpty) {
        final uploadUrlReq = await client.getUrl(Uri.parse('$_baseUrl/files/upload_url'));
        uploadUrlReq.headers.set('x-apikey', key);
        final uploadUrlResp = await uploadUrlReq.close();
        final uploadUrlBody = await uploadUrlResp.transform(utf8.decoder).join();
        if (uploadUrlResp.statusCode != 200) {
          return VirusTotalResult(
            found: false,
            sha256: sha256,
            error: '获取上传地址失败: HTTP ${uploadUrlResp.statusCode}',
          );
        }
        final uploadUrl = (jsonDecode(uploadUrlBody)['data']?['url'] as String?) ?? '';
        if (uploadUrl.isEmpty) {
          return VirusTotalResult(found: false, sha256: sha256, error: '获取上传地址失败: 空 URL');
        }

        final uploadReq = await client.postUrl(Uri.parse(uploadUrl));
        // 签名 URL 认证，不要带 x-apikey，否则会导致签名校验失败
        uploadReq.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
        uploadReq.contentLength = bodyBytes.length;
        uploadReq.add(bodyBytes);
        final uploadResp = await uploadReq.close();
        final uploadBody = await uploadResp.transform(utf8.decoder).join();
        if (uploadResp.statusCode != 200) {
          return VirusTotalResult(
            found: false,
            sha256: sha256,
            error: '上传失败: HTTP ${uploadResp.statusCode}',
          );
        }
        analysisId = (jsonDecode(uploadBody)['data']?['id'] as String?) ?? '';
        if (analysisId.isEmpty) {
          return VirusTotalResult(found: false, sha256: sha256, error: '上传后未获取到分析 ID');
        }
      }

      // 3. 轮询分析结果（每 8 秒，最多约 2.5 分钟）
      for (var i = 0; i < 20; i++) {
        onStatus?.call('analyzing');
        await Future.delayed(const Duration(seconds: 8));
        final analysisReq = await client.getUrl(Uri.parse('$_baseUrl/$analysisId'));
        analysisReq.headers.set('x-apikey', key);
        final analysisResp = await analysisReq.close();
        final analysisBody = await analysisResp.transform(utf8.decoder).join();
        if (analysisResp.statusCode != 200) continue;

        final attrs = jsonDecode(analysisBody)['data']?['attributes'] as Map<String, dynamic>?;
        if (attrs?['status'] != 'completed') continue;
        final stats = attrs?['stats'] as Map<String, dynamic>?;
        return VirusTotalResult(
          found: true,
          sha256: sha256,
          malicious: (stats?['malicious'] as num?)?.toInt() ?? 0,
          suspicious: (stats?['suspicious'] as num?)?.toInt() ?? 0,
          harmless: (stats?['harmless'] as num?)?.toInt() ?? 0,
          undetected: (stats?['undetected'] as num?)?.toInt() ?? 0,
          scanDate: DateTime.now().millisecondsSinceEpoch.toString(),
          permalink: 'https://www.virustotal.com/gui/file/$sha256',
        );
      }

      return VirusTotalResult(
        found: false,
        sha256: sha256,
        error: '分析超时，请稍后在 VirusTotal 网站查看结果',
      );
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
}
