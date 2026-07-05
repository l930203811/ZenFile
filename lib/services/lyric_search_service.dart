import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'lyric_parser.dart';
import 'preferences_service.dart';

/// QQ 音乐歌词搜索结果
class LyricSearchResult {
  final String songmid;
  final String title;
  final String singer;
  final String? albumName;
  final int? duration; // 秒

  LyricSearchResult({
    required this.songmid,
    required this.title,
    required this.singer,
    this.albumName,
    this.duration,
  });
}

/// 歌词下载结果
class LyricDownloadResult {
  /// 增强逐字 LRC（优先），若无则为 null
  final String? enhancedLrc;
  /// 普通逐行 LRC
  final String? plainLrc;

  LyricDownloadResult({this.enhancedLrc, this.plainLrc});

  /// 返回最佳可用歌词内容（优先增强 LRC）
  String? get best => enhancedLrc ?? plainLrc;

  /// 是否为增强 LRC
  bool get hasEnhanced => enhancedLrc != null && enhancedLrc!.trim().isNotEmpty;
}

/// QQ 音乐歌词搜索与下载服务
///
/// 通过调用 QQ 音乐公开接口实现在线搜索歌词并下载。
/// 参考 qq-music-api v2.4.0 (2026-06) 的 API 参数规范。
/// 不依赖任何第三方后端服务，纯 Flutter 端 HTTP 请求。
class LyricSearchService {
  LyricSearchService._();

  // --- API 端点 ---
  static const String _searchUrl =
      'https://c.y.qq.com/soso/fcgi-bin/client_search_cp';
  static const String _lyricUrl =
      'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg';
  static const String _musicuUrl =
      'https://u.y.qq.com/cgi-bin/musicu.fcg';

  // --- 通用参数（参考 qq-music-api config.ts）---
  static const int _gTk = 1124214810;
  static const String _loginUin = '0';
  static const String _platform = 'yqq.json';

  static Map<String, String> _commonParams() => {
        'g_tk': '$_gTk',
        'loginUin': _loginUin,
        'hostUin': '0',
        'inCharset': 'utf8',
        'outCharset': 'utf-8',
        'notice': '0',
        'platform': _platform,
        'needNewCode': '0',
      };

  // --- HTTP 客户端 ---
  static HttpClient? _client;
  static HttpClient get _httpClient {
    _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 15);
    return _client!;
  }

  /// 发送 GET 请求（可指定 Referer）
  static Future<String?> _get(
    String url, {
    String referer = 'https://y.qq.com',
  }) async {
    try {
      final uri = Uri.parse(url);
      final req = await _httpClient.getUrl(uri);
      req.headers.set('Referer', referer);
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      req.headers.set('Accept', 'application/json');
      // 部分接口校验 Host
      if (uri.host.isNotEmpty) {
        req.headers.set('Host', uri.host);
      }

      final resp = await req.close().timeout(
        const Duration(seconds: 10),
      );

      if (resp.statusCode != 200) {
        debugPrint('[LyricSearch] HTTP ${resp.statusCode} for $url');
        return null;
      }

      return await resp.transform(utf8.decoder).join();
    } catch (e) {
      debugPrint('[LyricSearch] GET error: $e');
      return null;
    }
  }

  /// 发送 POST JSON 请求
  static Future<String?> _postJson(
    String url,
    Map<String, dynamic> body, {
    String referer = 'https://y.qq.com',
    String origin = 'https://y.qq.com',
  }) async {
    try {
      final uri = Uri.parse(url);
      final req = await _httpClient.postUrl(uri);
      req.headers.set('Referer', referer);
      req.headers.set('Origin', origin);
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      req.headers.set('Accept', 'application/json');
      if (uri.host.isNotEmpty) {
        req.headers.set('Host', uri.host);
      }

      final payload = utf8.encode(jsonEncode(body));
      req.contentLength = payload.length;
      req.add(payload);

      final resp = await req.close().timeout(
        const Duration(seconds: 10),
      );

      if (resp.statusCode != 200) {
        debugPrint('[LyricSearch] POST ${resp.statusCode} for $url');
        return null;
      }

      return await resp.transform(utf8.decoder).join();
    } catch (e) {
      debugPrint('[LyricSearch] POST error: $e');
      return null;
    }
  }

  /// 构建带通用参数的查询字符串
  static String _buildQuery(Map<String, String> params) {
    return params.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  // ================================================================
  //  搜索
  // ================================================================

  /// 搜索歌曲，返回结果列表
  static Future<List<LyricSearchResult>> search(String query) async {
    if (query.trim().isEmpty) return [];

    final encodedQuery = Uri.encodeQueryComponent(query);
    final params = <String, String>{
      ..._commonParams(),
      'format': 'json',
      'w': query,
      'n': '15',
      'p': '1',
      'type': '1', // 歌曲
      't': '0',
      'ct': '24',
      'qqmusic_ver': '1298',
      'remoteplace': 'txt.yqq.song',
      'aggr': '1',
      'cr': '1',
      'lossless': '0',
      'flag_qc': '0',
    };

    final url = '$_searchUrl?${_buildQuery(params)}';
    final body = await _get(url);
    if (body == null) return [];

    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final songList = data['data']?['song']?['list'];

      if (songList == null || songList is! List) return [];

      final results = <LyricSearchResult>[];
      for (final item in songList) {
        if (item is! Map<String, dynamic>) continue;

        final songmid = item['songmid'] as String?;
        final title = item['songname'] as String? ?? '';
        final singer = item['singer'] is List
            ? (item['singer'] as List)
                .map((s) => (s['name'] ?? '').toString())
                .join(' / ')
            : (item['singer']?['name'] ?? '').toString();
        final albumName = item['albumname'] as String?;
        final duration = item['interval'] as int?;

        if (songmid != null && songmid.isNotEmpty && title.isNotEmpty) {
          results.add(LyricSearchResult(
            songmid: songmid,
            title: title,
            singer: singer,
            albumName: albumName,
            duration: duration,
          ));
        }
      }

      return results;
    } catch (e) {
      debugPrint('[LyricSearch] parse search error: $e');
      return [];
    }
  }

  // ================================================================
  //  歌词下载（主接口 + 备用接口）
  // ================================================================

  /// 判断响应是否为负数业务码（-1310、-1900 等，表示拒绝访问）
  static bool _hasNegativeBizCode(Map<String, dynamic> data) {
    for (final key in ['retcode', 'code', 'subcode']) {
      final val = num.tryParse(data[key]?.toString() ?? '');
      if (val != null && val < 0) return true;
    }
    return false;
  }

  /// 主接口：c.y.qq.com/lyric/...（传统歌词接口）
  static Future<LyricDownloadResult?> _fetchLyricPrimary(
      String songmid) async {
    if (songmid.isEmpty) return null;

    final params = <String, String>{
      ..._commonParams(),
      'songmid': songmid,
      'format': 'json',
      'pcachetime': DateTime.now().millisecondsSinceEpoch.toString(),
    };

    final url = '$_lyricUrl?${_buildQuery(params)}';
    final body = await _get(url, referer: 'https://y.qq.com/portal/player.html');
    if (body == null) return null;

    try {
      final data = jsonDecode(body) as Map<String, dynamic>;

      // 负数业务码表示接口拒绝
      if (_hasNegativeBizCode(data)) {
        debugPrint('[LyricSearch] Primary lyric returned negative code for $songmid, trying fallback...');
        return null; // 触发备用接口
      }

      final plainLrc = _decodeLyric(data['lyric']);
      final enhancedLrc = _decodeLyric(data['qrc']);

      if (plainLrc == null && enhancedLrc == null) return null;

      return LyricDownloadResult(
        plainLrc: plainLrc,
        enhancedLrc: enhancedLrc,
      );
    } catch (e) {
      debugPrint('[LyricSearch] parse primary lyric error: $e');
      return null;
    }
  }

  /// 备用接口：u.y.qq.com/cgi-bin/musicu.fcg（新版歌词接口）
  static Future<LyricDownloadResult?> _fetchLyricMusicu(
      String songmid) async {
    if (songmid.isEmpty) return null;

    final body = {
      'req_0': {
        'module': 'music.musichallSong.PlayLyricInfo',
        'method': 'GetPlayLyricInfo',
        'param': {
          'songMID': songmid,
          'songID': 0,
          'trans_t': 0,
          'roma_t': 0,
          'qrc_t': 0, // 不再额外请求 qrc
          'crypt': 1,
          'lrc_t': 0,
          'interval': 0,
        },
      },
      'loginUin': _loginUin,
      'comm': {
        'uin': _loginUin,
        'format': 'json',
        'ct': 24,
        'cv': 0,
      },
    };

    final resp = await _postJson(
      _musicuUrl,
      body,
      referer: 'https://y.qq.com/portal/player.html',
    );

    if (resp == null) return null;

    try {
      final data = jsonDecode(resp) as Map<String, dynamic>;
      final lyricData =
          data['req_0']?['data'] as Map<String, dynamic>? ??
          data['PlayLyricInfo']?['data'] as Map<String, dynamic>?;

      if (lyricData == null) return null;

      final plainLrc = _decodeLyric(lyricData['lyric']);
      final enhancedLrc = _decodeLyric(lyricData['qrc']);

      if (plainLrc == null && enhancedLrc == null) return null;

      return LyricDownloadResult(
        plainLrc: plainLrc,
        enhancedLrc: enhancedLrc,
      );
    } catch (e) {
      debugPrint('[LyricSearch] parse musicu lyric error: $e');
      return null;
    }
  }

  /// 根据 songmid 获取歌词（优先主接口，失败降级备用接口）
  ///
  /// QQ 音乐返回的 [qrc] 字段是逐字歌词（增强 LRC），
  /// [lyric] 是普通逐行 LRC。
  static Future<LyricDownloadResult?> fetchLyric(String songmid) async {
    if (songmid.isEmpty) return null;

    // 先尝试主接口
    final primary = await _fetchLyricPrimary(songmid);
    if (primary != null) return primary;

    // 降级到 musicu 备用接口
    debugPrint('[LyricSearch] Falling back to musicu for $songmid');
    return _fetchLyricMusicu(songmid);
  }

  // ================================================================
  //  Base64 / 文本解码
  // ================================================================

  /// 解码 QQ 音乐歌词字段（可能是 base64 编码的）
  static String? _decodeLyric(dynamic field) {
    if (field == null) return null;

    if (field is String) {
      if (field.isEmpty) return null;
      // 可能是 base64 编码的
      try {
        final decoded = utf8.decode(const Base64Decoder().convert(field));
        if (decoded.trim().isNotEmpty) return decoded;
      } catch (_) {
        // 不是 base64，就是纯文本
        return field;
      }
    }

    if (field is Map<String, dynamic>) {
      final lyric = field['lyric'] as String?;
      if (lyric != null && lyric.isNotEmpty) return lyric;
    }

    return null;
  }

  // ================================================================
  //  搜索 + 下载 — 面向 UI 的入口
  // ================================================================

  /// 搜索并下载歌词，保存为 .lrc 文件
  ///
  /// 返回解析后的歌词和文件路径，失败返回 null。
  static Future<({List<LyricLine> lyrics, String sourcePath})?> searchAndDownload({
    required String title,
    required String artist,
    required String audioPath,
    String? saveDir,
  }) async {
    if (kDebugMode) {
      debugPrint('[LyricSearch] Searching: $title - $artist');
    }

    // 清理查询字符串
    String cleanQuery(String s) {
      // 去掉括号内容（feat, live, remix 等）
      return s
          .replaceAll(RegExp(r'\([^)]*\)'), '')
          .replaceAll(RegExp(r'（[^）]*）'), '')
          .replaceAll(RegExp(r'\[[^\]]*\]'), '')
          .trim();
    }

    final cleanTitle = cleanQuery(title);
    final cleanArtist = cleanQuery(artist);

    // 用标题+歌手搜索
    var results = await search('$cleanTitle $cleanArtist');

    // 如果结果太精确匹配少，只用标题搜
    if (results.isEmpty) {
      results = await search(cleanTitle);
    }

    if (results.isEmpty) {
      debugPrint('[LyricSearch] No results for: $cleanTitle - $cleanArtist');
      return null;
    }

    // 尝试下载所有结果的歌词，优先取有增强 LRC 的
    LyricDownloadResult? bestResult;
    LyricSearchResult? bestSong;

    for (final song in results) {
      final lyricResult = await fetchLyric(song.songmid);
      if (lyricResult == null) continue;

      if (lyricResult.hasEnhanced) {
        bestResult = lyricResult;
        bestSong = song;
        break; // 找到增强 LRC 就直接用了
      }

      // 退而求其次：普通 LRC
      if (bestResult == null && lyricResult.plainLrc != null) {
        bestResult = lyricResult;
        bestSong = song;
      }
    }

    if (bestResult == null) {
      debugPrint('[LyricSearch] No usable lyric found');
      return null;
    }

    final lrcContent = bestResult.best;
    if (lrcContent == null) return null;

    // 保存为 .lrc 文件
    final dir = saveDir ?? p.dirname(audioPath);
    final baseName = p.basenameWithoutExtension(audioPath);
    final lrcPath = p.join(dir, '$baseName.lrc');

    try {
      final file = File(lrcPath);
      // QQ 音乐歌词用 unix 换行符，统一处理
      final fixedContent =
          lrcContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      await file.writeAsString(fixedContent, flush: true);

      // 解析歌词
      final lyrics = LyricParser.parse(fixedContent);
      if (lyrics.isEmpty) {
        debugPrint('[LyricSearch] Parsed lyrics empty');
        return null;
      }

      // 保存映射
      await PreferencesService.saveLyricMapping(audioPath, lrcPath);

      debugPrint(
          '[LyricSearch] Downloaded: ${bestSong?.title ?? "?"} - ${bestResult.hasEnhanced ? "enhancedLRC" : "plainLRC"} (${lyrics.length} lines, ${lyrics.where((l) => l.hasWordTimestamps).length} word-by-word)');

      return (lyrics: lyrics, sourcePath: lrcPath);
    } catch (e) {
      debugPrint('[LyricSearch] Save file error: $e');
      return null;
    }
  }
}
