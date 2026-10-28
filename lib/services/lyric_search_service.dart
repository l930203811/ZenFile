import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'lyric_parser.dart';
import 'preferences_service.dart';

/// 歌词源标识（搜索结果 / 下载动作按此分派到对应实现）。
enum LyricSourceId { qq, kugou, lrclib }

/// 用户可配置的「歌词搜索源」（prefs key `lyric_search_source`）。
///
/// [auto] 为默认：QQ / 酷狗 / LRCLIB **三源并发**搜索，结果合并进同一列表
/// （逐字优先、其余按源固定顺序排布，见 [LyricSearchService.searchAll]）；
/// 任一单源都存在覆盖缺口，并发合并才能一次搜全。
/// 选定具体源时**只搜该源**，不再回退其余源。
/// 只存 name 字符串到 PreferencesService，避免反向依赖。
enum LyricSearchSource { auto, qq, kugou, lrclib }

/// 由持久化字符串还原；未知值（含旧版本残留）与从未设置过的用户均回落
/// [LyricSearchSource.auto]。
LyricSearchSource lyricSearchSourceFromName(String? name) {
  for (final s in LyricSearchSource.values) {
    if (s.name == name) return s;
  }
  return LyricSearchSource.auto;
}

/// 单个歌词源的搜索结果。
class LyricSearchResult {
  /// 源内歌曲标识：QQ = songmid；酷狗 = FileHash；LRCLIB = track id。
  final String songId;

  /// 该结果来自哪个源（下载时按此分派）。
  final LyricSourceId source;

  final String title;
  final String singer;
  final String? albumName;
  final int? duration; // 秒

  /// 是否为逐字歌词（结果列表的「逐字」徽标）。
  ///
  /// 酷狗源为 true（KRC 普遍带逐字时间轴，下载后按内容自动识别兜底）；
  /// QQ 源恒为 false（qrc 为 3DES 密文、无解密依赖，只出普通 LRC）；
  /// LRCLIB 源按 hasWordSync / syncedLyrics 内容判定。
  final bool enhanced;

  /// 搜索阶段已顺带返回的歌词文本（LRCLIB 特性：搜索即带 syncedLyrics）。
  /// 其他源为 null，下载时再单独请求。
  final String? preloadedLrc;

  LyricSearchResult({
    required this.songId,
    required this.source,
    required this.title,
    required this.singer,
    this.albumName,
    this.duration,
    this.enhanced = false,
    this.preloadedLrc,
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

/// 多源歌词搜索与下载服务
///
/// 三个公开源，纯 Flutter 端 HTTP 请求（dart:io HttpClient），无第三方后端：
/// - QQ 音乐（c.y.qq.com）：搜索 + fcg_query_lyric_new.fcg 下载，只产普通 LRC
///   （qrc 逐字字段为 3DES 密文，项目无 pointycastle/encrypt 依赖，不解密）。
/// - 酷狗（songsearch.kugou.com 搜索 + lyrics.kugou.com 下载）：KRC 逐字歌词，
///   解密为公开零依赖算法（XOR + zlib inflate），转本项目 A2 增强格式。
/// - LRCLIB（lrclib.net/api/search）：无鉴权、稳定，普通逐句 LRC。
///
/// 搜索源（PreferencesService.lyric_search_source）：auto = 三源并发搜索、
/// 结果合并展示；指定源 = 只搜该源（不再回退，见 [searchAll]）。
class LyricSearchService {
  LyricSearchService._();

  // --- QQ 音乐 API 端点 ---
  static const String _searchUrl =
      'https://c.y.qq.com/soso/fcgi-bin/client_search_cp';
  static const String _lyricUrl =
      'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg';
  static const String _musicuUrl =
      'https://u.y.qq.com/cgi-bin/musicu.fcg';

  // --- 酷狗 API 端点 ---
  // 搜索用 songsearch.kugou.com（实测可达；老 mobilecdn/mobileservices 域名
  // 证书已坏 / DNS 失效）；歌词用 lyrics.kugou.com 老接口（krcs.kugou.com
  // 实测已 400 Bad Request）。
  static const String _kugouSearchUrl =
      'https://songsearch.kugou.com/song_search_v2';
  static const String _kugouLyricSearchUrl =
      'https://lyrics.kugou.com/search';
  static const String _kugouLyricDownloadUrl =
      'https://lyrics.kugou.com/download';

  // --- LRCLIB API 端点 ---
  static const String _lrclibSearchUrl = 'https://lrclib.net/api/search';

  // --- KRC 解密密钥（公开算法，见 _decryptKrc） ---
  static const List<int> _krcXorKey = [
    0x40, 0x47, 0x61, 0x77, 0x5E, 0x32, 0x74, 0x47, // "@Gaw^2tGQ"
    0x51, 0x36, 0x31, 0x2D, 0xCE, 0xD2, 0x6E, 0x69, // "61-\xce\xd2ni"
  ];

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
  //  多源搜索（面向 UI 的入口）
  // ================================================================

  /// 按搜索源设置给出本次要请求的源集合：auto = 三源全量（并发合并）；
  /// 指定源 = 只搜该源。
  static List<LyricSourceId> _sourcesForQuery() {
    switch (
        lyricSearchSourceFromName(PreferencesService.getLyricSearchSource())) {
      case LyricSearchSource.qq:
        return const [LyricSourceId.qq];
      case LyricSearchSource.kugou:
        return const [LyricSourceId.kugou];
      case LyricSearchSource.lrclib:
        return const [LyricSourceId.lrclib];
      case LyricSearchSource.auto:
        return const [LyricSourceId.qq, LyricSourceId.kugou, LyricSourceId.lrclib];
    }
  }

  /// 多源聚合搜索。
  ///
  /// - auto：QQ / 酷狗 / LRCLIB **三源并发**（各源内部仍保留「歌名+歌手 →
  ///   仅歌名」两级查询），结果合并为**一个列表**：逐字歌词优先，其次按源
  ///   固定顺序（QQ → 酷狗 → LRCLIB）排布、源内保持各源自带排序。列表项带
  ///   source 字段，UI 据此标注来源徽标。
  /// - 指定单一源：只请求该源，结果保持该源原有排序。
  ///
  /// [triedSources] 记录本次实际请求过的源，供 UI 在全部落空时提示
  /// 「所有歌词源均未找到」（auto 模式 = 三源都空才提示）。
  static Future<
      ({List<LyricSearchResult> results, List<LyricSourceId> triedSources})>
      searchAll({
    required String title,
    String artist = '',
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      return (results: const <LyricSearchResult>[], triedSources: const <LyricSourceId>[]);
    }
    // 两级查询：先「歌名 歌手」，空则仅歌名（歌手名解析不准时兜底）。
    final q1 =
        artist.trim().isEmpty ? cleanTitle : '$cleanTitle ${artist.trim()}';
    final q2 = q1 == cleanTitle ? '' : cleanTitle;

    final sources = _sourcesForQuery();

    // 单一源：维持原有两级查询顺序，结果保持该源原有排序。
    if (sources.length == 1) {
      final src = sources.first;
      var list = await _searchOn(src, q1);
      if (list.isEmpty && q2.isNotEmpty) {
        list = await _searchOn(src, q2);
      }
      return (results: list, triedSources: sources);
    }

    // auto：三源并发。每个源的失败/空结果互不阻塞（_searchOn 内部已吞异常
    // 返回空列表），全部返回后再合并。
    final perSource = await Future.wait(
      sources.map((src) async {
        var list = await _searchOn(src, q1);
        if (list.isEmpty && q2.isNotEmpty) {
          list = await _searchOn(src, q2);
        }
        return list;
      }),
    );

    // 合并 + 稳定排序：逐字优先；同级保持「源固定顺序 + 源内原序」。
    // List.sort 不保证稳定，用原始位置 order 作平级 tiebreaker。
    final tagged = <({LyricSearchResult r, int order})>[];
    for (final list in perSource) {
      for (final r in list) {
        tagged.add((r: r, order: tagged.length));
      }
    }
    tagged.sort((a, b) {
      if (a.r.enhanced != b.r.enhanced) return a.r.enhanced ? -1 : 1;
      return a.order.compareTo(b.order);
    });

    final merged = [for (final t in tagged) t.r];
    debugPrint('[LyricSearch] merged ${merged.length} results from '
        '$sources (enhanced=${merged.where((r) => r.enhanced).length})');
    return (results: merged, triedSources: sources);
  }

  /// 单源搜索分派
  static Future<List<LyricSearchResult>> _searchOn(
      LyricSourceId src, String query) async {
    switch (src) {
      case LyricSourceId.qq:
        return _searchQq(query);
      case LyricSourceId.kugou:
        return _searchKugou(query);
      case LyricSourceId.lrclib:
        return _searchLrclib(query);
    }
  }

  // ================================================================
  //  QQ 音乐源：搜索
  // ================================================================

  /// QQ 音乐搜索（type=1 歌曲）
  static Future<List<LyricSearchResult>> _searchQq(String query) async {
    if (query.trim().isEmpty) return [];

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
            songId: songmid,
            source: LyricSourceId.qq,
            title: title,
            singer: singer,
            albumName: albumName,
            duration: duration,
            // qrc 为 3DES 密文（无解密依赖），QQ 源只出普通 LRC
            enhanced: false,
          ));
        }
      }

      return results;
    } catch (e) {
      debugPrint('[LyricSearch] parse qq search error: $e');
      return [];
    }
  }

  // ================================================================
  //  酷狗源：搜索 + KRC 下载/解密 → A2 增强 LRC
  // ================================================================

  /// 酷狗搜索（song_search_v2）。SongName/SingerName 可能带 <em> 高亮标签，
  /// 统一剥掉。酷狗歌词库普遍有 KRC 逐字歌词，结果标 enhanced=true
  ///（下载后仍按内容自动识别，个别纯逐句条目会自然退化为普通 LRC）。
  static Future<List<LyricSearchResult>> _searchKugou(String query) async {
    if (query.trim().isEmpty) return [];

    final url =
        '$_kugouSearchUrl?format=json&keyword=${Uri.encodeQueryComponent(query)}&page=1&pagesize=15';
    final body = await _get(url, referer: 'https://www.kugou.com/');
    if (body == null) return [];

    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final lists = data['data']?['lists'];
      if (lists == null || lists is! List) return [];

      final results = <LyricSearchResult>[];
      for (final item in lists) {
        if (item is! Map<String, dynamic>) continue;

        final hash = (item['FileHash'] ?? item['fileHash'])?.toString();
        final title = _stripKugouEm(item['SongName'] ?? item['songname']);
        final singer =
            _stripKugouEm(item['SingerName'] ?? item['singername'] ?? '');
        final albumName = _stripKugouEm(item['AlbumName'] ?? item['albumname']);
        final duration = (item['Duration'] ?? item['duration']) is int
            ? item['Duration'] as int
            : int.tryParse('${item['Duration'] ?? ''}');

        if (hash != null && hash.isNotEmpty && title.isNotEmpty) {
          results.add(LyricSearchResult(
            songId: hash,
            source: LyricSourceId.kugou,
            title: title,
            singer: singer,
            albumName: albumName.isEmpty ? null : albumName,
            duration: duration,
            enhanced: true,
          ));
        }
      }

      return results;
    } catch (e) {
      debugPrint('[LyricSearch] parse kugou search error: $e');
      return [];
    }
  }

  /// 剥掉酷狗搜索结果里的 <em> 高亮标签并清理空白
  static String _stripKugouEm(dynamic field) {
    final s = field?.toString() ?? '';
    return s
        .replaceAll(RegExp(r'</?em>'), '')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
  }

  /// 酷狗歌词下载：hash → lyrics.kugou.com 两步拿加密 KRC → 解密 → 转 A2。
  static Future<LyricDownloadResult?> _fetchKugouLyric(
      LyricSearchResult song) async {
    if (song.songId.isEmpty) return null;

    // 第一步：按 hash 在酷狗歌词库找候选（duration 用毫秒参与匹配）。
    final durMs = (song.duration ?? 0) * 1000;
    final searchUrl =
        '$_kugouLyricSearchUrl?ver=2049&man=yes&client=pc&keyword=%20&duration=$durMs&hash=${Uri.encodeQueryComponent(song.songId)}';
    final searchBody = await _get(searchUrl, referer: 'https://www.kugou.com/');
    if (searchBody == null) return null;

    String? id;
    String? accessKey;
    try {
      final data = jsonDecode(searchBody) as Map<String, dynamic>;
      final candidates = data['candidates'];
      if (candidates is! List || candidates.isEmpty) {
        debugPrint('[LyricSearch] kugou no lyric candidate for ${song.songId}');
        return null;
      }
      // 优先挑 krctype==1（KRC 逐字）的候选，否则取第一个。
      Map<String, dynamic>? pick;
      for (final c in candidates) {
        if (c is! Map<String, dynamic>) continue;
        if ('${c['krctype']}' == '1') {
          pick = c;
          break;
        }
        pick ??= c;
      }
      id = pick?['id']?.toString();
      accessKey = pick?['accesskey']?.toString();
    } catch (e) {
      debugPrint('[LyricSearch] parse kugou lyric search error: $e');
      return null;
    }
    if (id == null || id.isEmpty || accessKey == null || accessKey.isEmpty) {
      return null;
    }

    // 第二步：用 id + accesskey 拉加密 KRC（base64）。
    final dlUrl =
        '$_kugouLyricDownloadUrl?ver=1&client=pc&id=${Uri.encodeQueryComponent(id)}&accesskey=${Uri.encodeQueryComponent(accessKey)}&fmt=krc&charset=utf8';
    final dlBody = await _get(dlUrl, referer: 'https://www.kugou.com/');
    if (dlBody == null) return null;

    String? base64Content;
    try {
      final data = jsonDecode(dlBody) as Map<String, dynamic>;
      if ('${data['status']}' != '200') {
        debugPrint('[LyricSearch] kugou download status=${data['status']}');
        return null;
      }
      base64Content = data['content']?.toString();
    } catch (e) {
      debugPrint('[LyricSearch] parse kugou download error: $e');
      return null;
    }
    if (base64Content == null || base64Content.isEmpty) return null;

    final krcText = _decryptKrc(base64Content);
    if (krcText == null) return null;

    return _krcToDownloadResult(krcText);
  }

  /// KRC 解密（公开零依赖算法，参照 LDDC KuGouDecrypt）：
  /// 1. base64 解码 → 前 4 字节是 "krc1" 魔数（明文）；
  /// 2. 第 4 字节起的密文体逐字节与 16 字节密钥滚动 XOR（i % key.length）；
  /// 3. zlib inflate（dart:convert 自带）得 UTF-8 KRC 文本。
  /// KRC 文本含逐字 [行头+词标签]，转 A2 后直接喂 LyricParser。
  static String? _decryptKrc(String base64Content) {
    try {
      final normalized = base64Content
          .replaceAll('\n', '')
          .replaceAll('\r', '')
          .replaceAll('-', '+')
          .replaceAll('_', '/');
      final raw = base64.decode(normalized);
      // 兼容带 / 不带 "krc1" 魔数的响应（lyrics.kugou.com 实测带魔数）。
      var start = 0;
      if (raw.length > 4 &&
          raw[0] == 0x6B &&
          raw[1] == 0x72 &&
          raw[2] == 0x63 &&
          raw[3] == 0x31) {
        start = 4; // "krc1"
      }
      if (raw.length <= start) return null;

      final plain = List<int>.generate(raw.length - start, (i) {
        return raw[start + i] ^ _krcXorKey[i % _krcXorKey.length];
      });
      return utf8.decode(zlib.decode(plain), allowMalformed: true);
    } catch (e) {
      debugPrint('[LyricSearch] krc decrypt error: $e');
      return null;
    }
  }

  // --- KRC → A2 增强 LRC 转换 ---

  /// KRC 行头：[行起始ms,行时长ms]
  static final RegExp _krcLineHead = RegExp(r'^\s*\[(\d+),\d+\]');

  /// KRC 词标签：<词起始ms(相对行头),词时长ms,0>词文本
  static final RegExp _krcWordTag = RegExp(r'<(\d+),\d+,\d+>([^<]*)');

  /// 把解密后的 KRC 文本转成本项目 A2 增强格式（`[mm:ss.xx]<mm:ss.xx>字`）。
  ///
  /// - KRC 词时间戳是相对行头的毫秒，转换为绝对时间后取百分秒；
  /// - 带 [language:...] 的行与元数据行跳过；
  /// - 翻译/音译行（无词标签的纯文本行）在同一时间戳上与原文行重复：
  ///   只要存在词级行就丢弃全部纯文本行；整首无词级行时才按逐句 LRC 输出。
  static LyricDownloadResult _krcToDownloadResult(String krcText) {
    final enhancedBuf = StringBuffer();
    final plainBuf = StringBuffer();
    var enhancedLines = 0;
    var plainLines = 0;
    var hasWordLines = false;
    final plainTextLines = <String>[]; // (start, text)

    for (final rawLine in krcText.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      // 元数据行（[id:][ar:][ti:][offset:][language:...] 等）
      if (RegExp(r'^\[[^,\]]*\]').hasMatch(line)) continue;

      final head = _krcLineHead.firstMatch(line);
      if (head == null) continue;
      final startMs = int.tryParse(head.group(1)!) ?? 0;
      final rest = line.substring(head.end);

      // 收集词标签
      final words = <({int relMs, String text})>[];
      for (final m in _krcWordTag.allMatches(rest)) {
        final relMs = int.tryParse(m.group(1)!) ?? 0;
        final text = _sanitizeKrcWord(m.group(2) ?? '');
        if (text.isEmpty) continue;
        words.add((relMs: relMs, text: text));
      }

      if (words.isNotEmpty) {
        hasWordLines = true;
        enhancedBuf.write('[${_formatTimestamp(startMs)}]');
        for (final w in words) {
          enhancedBuf
              .write('<${_formatTimestamp(startMs + w.relMs)}>${w.text}');
        }
        enhancedBuf.writeln();
        enhancedLines++;
      } else {
        // 无词标签：纯文本行（可能是翻译行，也可能整首就是逐句 KRC）
        final plain = _sanitizeKrcWord(rest).trim();
        if (plain.isNotEmpty) {
          plainTextLines.add(plain);
          plainBuf.writeln('[${_formatTimestamp(startMs)}]$plain');
          plainLines++;
        }
      }
    }

    // 有词级行 → 输出增强 LRC（丢弃翻译行）；否则退化为普通逐句 LRC。
    if (hasWordLines && enhancedLines > 0) {
      return LyricDownloadResult(enhancedLrc: enhancedBuf.toString());
    }
    if (plainLines > 0) {
      return LyricDownloadResult(plainLrc: plainBuf.toString());
    }
    // 理论不可达（调用前已确认解密出内容），兜底返回 null 走失败路径。
    return LyricDownloadResult();
  }

  /// 词文本清洗：剥掉可能破坏 LRC 结构的时间戳/标签字符
  static String _sanitizeKrcWord(String s) {
    return s.replaceAll(RegExp(r'[\[\]<>]'), '');
  }

  /// 毫秒 → mm:ss.xx（百分秒，四舍五入）
  static String _formatTimestamp(int ms) {
    var v = ms < 0 ? 0 : ms;
    final cs = (v / 10).round(); // 百分秒
    final minutes = cs ~/ 6000;
    final remain = cs % 6000;
    final seconds = remain ~/ 100;
    final hundredths = remain % 100;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(minutes)}:${two(seconds)}.${two(hundredths)}';
  }

  // ================================================================
  //  LRCLIB 源：搜索（搜索即返回歌词文本）
  // ================================================================

  /// LRCLIB 搜索（无鉴权）。只收 syncedLyrics 非空的条目（纯文本歌词无
  /// 时间轴，解析后为空行，对本播放器无用）。
  static Future<List<LyricSearchResult>> _searchLrclib(String query) async {
    if (query.trim().isEmpty) return [];

    final url = '$_lrclibSearchUrl?q=${Uri.encodeQueryComponent(query)}';
    final body = await _get(url, referer: 'https://lrclib.net/');
    if (body == null) return [];

    try {
      final list = jsonDecode(body);
      if (list is! List) return [];

      final results = <LyricSearchResult>[];
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        if (item['instrumental'] == true) continue;
        if (results.length >= 15) break;

        final synced = item['syncedLyrics']?.toString();
        if (synced == null || synced.trim().isEmpty) continue;

        final trackName = (item['trackName'] ?? '').toString();
        if (trackName.isEmpty) continue;

        // hasWordSync（词级同步标记）或内容里真有 <> 标签都算逐字。
        final hasWord = item['hasWordSync'] == true ||
            RegExp(r'<\d{1,3}:\d{1,2}').hasMatch(synced);

        results.add(LyricSearchResult(
          songId: '${item['id'] ?? ''}',
          source: LyricSourceId.lrclib,
          title: trackName,
          singer: (item['artistName'] ?? '').toString(),
          albumName: (item['albumName'] ?? '').toString(),
          duration: (item['duration'] is num)
              ? (item['duration'] as num).round()
              : null,
          enhanced: hasWord,
          preloadedLrc: synced,
        ));
      }

      return results;
    } catch (e) {
      debugPrint('[LyricSearch] parse lrclib search error: $e');
      return [];
    }
  }

  // ================================================================
  //  QQ 音乐源：歌词下载（主接口 + 备用接口）
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
      if (plainLrc == null) return null;

      // ⚠️ 不读 qrc 字段：qrc 是 3DES 加密密文，项目没有 pointycastle/encrypt
      // 依赖无法解密——此前把密文当 enhancedLrc 返回，一旦接口下发该字段就会
      // 把乱码存成歌词。QQ 源只出普通 LRC，逐字由酷狗 KRC 源提供。
      return LyricDownloadResult(plainLrc: plainLrc);
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
          'qrc_t': 0, // 不再额外请求 qrc（密文无法解密）
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
      if (plainLrc == null) return null;

      // 同主接口：qrc 密文不解密，只出普通 LRC。
      return LyricDownloadResult(plainLrc: plainLrc);
    } catch (e) {
      debugPrint('[LyricSearch] parse musicu lyric error: $e');
      return null;
    }
  }

  /// 根据 songmid 获取 QQ 歌词（优先主接口，失败降级备用接口）。
  ///
  /// QQ 源只返回普通逐行 LRC（qrc 逐字字段为 3DES 密文，无解密依赖）。
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
  //  按结果下载（源分派）
  // ================================================================

  /// 按搜索结果的源分派下载。返回歌词内容，失败返回 null。
  static Future<LyricDownloadResult?> _downloadFrom(LyricSearchResult song) async {
    switch (song.source) {
      case LyricSourceId.qq:
        return fetchLyric(song.songId);
      case LyricSourceId.kugou:
        return _fetchKugouLyric(song);
      case LyricSourceId.lrclib:
        // LRCLIB 搜索阶段已带歌词文本，直接用；内容里真有逐字标签才算增强。
        final lrc = song.preloadedLrc;
        if (lrc == null || lrc.trim().isEmpty) return null;
        final hasWord = RegExp(r'<\d{1,3}:\d{1,2}').hasMatch(lrc);
        return LyricDownloadResult(
          enhancedLrc: hasWord ? lrc : null,
          plainLrc: hasWord ? null : lrc,
        );
    }
  }

  // ================================================================
  //  搜索 + 下载 — 面向 UI 的入口
  // ================================================================

  // ================================================================
  //  歌词落盘
  // ================================================================

  /// 歌词保存目录候选：优先与音频同目录（用户可见、便于自行管理）；同目录不可写
  /// （受限目录 / 只读挂载）或路径不是本地真实路径（远程流）时，退回应用私有
  /// lyrics 目录 —— 否则「自动下载歌词」会因为写不进去而静默失败，用户只看到
  /// 「没有歌词」却不知道为什么。
  static Future<List<String>> _lyricSaveDirs(
    String audioPath,
    String? saveDir,
  ) async {
    final dirs = <String>[];
    if (saveDir != null && saveDir.isNotEmpty) dirs.add(saveDir);
    // 只有本地绝对路径才谈得上「与音频同目录」；远程（remote:// / http）跳过。
    if (audioPath.startsWith('/')) dirs.add(p.dirname(audioPath));
    try {
      final support = await getApplicationSupportDirectory();
      dirs.add(p.join(support.path, 'lyrics'));
    } catch (_) {}
    return dirs;
  }

  /// 把歌词内容写到第一个可写目录，解析并登记映射。全部失败返回 null。
  static Future<({List<LyricLine> lyrics, String sourcePath})?> _writeLrcFile({
    required String content,
    required String baseName,
    required List<String> dirs,
    required String audioPath,
  }) async {
    if (baseName.isEmpty) return null;
    // 各源歌词换行符不一，统一处理
    final fixed = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    for (final dir in dirs) {
      try {
        final target = Directory(dir);
        if (!target.existsSync()) target.createSync(recursive: true);
        final file = File(p.join(dir, '$baseName.lrc'));
        await file.writeAsString(fixed, flush: true);
        final lyrics = LyricParser.parse(fixed);
        if (lyrics.isEmpty) continue;
        // 保存映射
        await PreferencesService.saveLyricMapping(audioPath, file.path);
        return (lyrics: lyrics, sourcePath: file.path);
      } catch (e) {
        debugPrint('[LyricSearch] Save lyric to $dir failed: $e');
      }
    }
    return null;
  }

  /// 多源搜索并自动下载第一首可用歌词，保存为 .lrc 文件。
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

    final multi = await searchAll(
      title: cleanQuery(title),
      artist: cleanQuery(artist),
    );
    final results = multi.results;

    if (results.isEmpty) {
      debugPrint('[LyricSearch] No results for: $title - $artist '
          '(tried: ${multi.triedSources})');
      return null;
    }

    // 尝试下载所有结果的歌词，优先取有增强 LRC 的
    LyricDownloadResult? bestResult;
    LyricSearchResult? bestSong;

    for (final song in results) {
      final lyricResult = await _downloadFrom(song);
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

    // 保存为 .lrc 文件（同目录优先，不可写时退回应用私有 lyrics 目录）
    final saved = await _writeLrcFile(
      content: lrcContent,
      baseName: p.basenameWithoutExtension(audioPath),
      dirs: await _lyricSaveDirs(audioPath, saveDir),
      audioPath: audioPath,
    );
    if (saved == null) {
      debugPrint('[LyricSearch] Save file error: no writable lyric dir');
      return null;
    }

    debugPrint(
      '[LyricSearch] Downloaded: ${bestSong?.title ?? "?"} - ${bestResult.hasEnhanced ? "enhancedLRC" : "plainLRC"} (${saved.lyrics.length} lines, ${saved.lyrics.where((l) => l.hasWordTimestamps).length} word-by-word)',
    );

    return saved;
  }

  /// 下载指定歌曲的歌词（用户从搜索结果列表中手动选择后调用）。
  ///
  /// 按结果来源分派到对应源的下载实现。返回解析后的歌词与路径，失败返回 null。
  static Future<({List<LyricLine> lyrics, String sourcePath})?> downloadForSong({
    required LyricSearchResult song,
    required String audioPath,
    String? saveDir,
  }) async {
    if (kDebugMode) {
      debugPrint('[LyricSearch] Downloading selected: ${song.title} - ${song.singer} (${song.songId}, source=${song.source.name})');
    }

    final lyricResult = await _downloadFrom(song);
    if (lyricResult == null) return null;

    final lrcContent = lyricResult.best;
    if (lrcContent == null) return null;

    final saved = await _writeLrcFile(
      content: lrcContent,
      baseName: p.basenameWithoutExtension(audioPath),
      dirs: await _lyricSaveDirs(audioPath, saveDir),
      audioPath: audioPath,
    );
    if (saved == null) {
      debugPrint('[LyricSearch] Save selected lyric error: no writable dir');
      return null;
    }

    debugPrint(
      '[LyricSearch] Saved selected lyric: ${song.title} (${saved.lyrics.length} lines)',
    );
    return saved;
  }
}
