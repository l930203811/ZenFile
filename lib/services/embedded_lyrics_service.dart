import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'lyric_parser.dart';

/// 音频文件内嵌歌词提取（纯 Dart 实现，无第三方依赖）。
///
/// 支持的容器 / 标签格式：
/// - MP3（及含 ID3v2 的 WAV）：ID3v2.2/2.3/2.4 的 USLT/ULT（文本内含 LRC
///   时间戳则按同步歌词解析）与 SYLT/SLT（二进制同步歌词，转成 LRC 后解析）
/// - FLAC：Vorbis Comment 的 `LYRICS` / `UNSYNCEDLYRICS` 字段
/// - OGG / OPUS：`vorbis` / `OpusTags` 头部的 Vorbis Comment 字段
/// - M4A / MP4：`ilst` 元数据中的 `©lyr` 原子
/// - APEv2（.ape 及部分 MP3）：`Lyrics` 字段
///
/// 设计约束：
/// - 只解析**含时间戳的同步歌词**（LRC 文本或 SYLT）。绝大多数中文播放器
///   （QQ音乐 / 网易云等）写进 USLT/©lyr 的都是 LRC 文本，覆盖主流场景。
///   纯文本（未同步）内嵌歌词暂不展示——歌词视图是逐行时间轴驱动，无法
///   正确高亮，此时返回 null 让上层走在线搜索。
/// - 只读取文件头部的标签区（ID3 按声明长度、FLAC/MP4 按 chunk 定位、
///   OGG 只扫前 512KB、APE 只读尾部），不整读音频数据。
/// - 调用方应在后台 isolate 中调用（耗时主要是标签区的字节读取与解码）。
class EmbeddedLyricsService {
  /// 最多读取的 ID3 标签字节数（含专辑封面时可能到数 MB，超出视为异常）。
  static const int _maxId3Bytes = 8 << 20; // 8 MB

  /// OGG / OPUS 头部扫描窗口。
  static const int _maxOggScanBytes = 512 << 10; // 512 KB

  /// WAV 内 ID3 chunk 扫描窗口。
  static const int _maxWavScanBytes = 1 << 20; // 1 MB

  /// 提取内嵌歌词。无内嵌歌词 / 无法解析时返回 null。
  ///
  /// 必须在非主 isolate 中调用（内部有同步文件 IO）。
  static List<LyricLine>? extractSync(String audioPath) {
    try {
      final file = File(audioPath);
      if (!file.existsSync()) return null;
      final raf = file.openSync();
      try {
        final length = raf.lengthSync();
        if (length < 16) return null;

        // ── 按魔数识别容器并提取候选歌词文本 ──
        final texts = <String>[];

        // 1) ID3v2（MP3 在文件头；WAV 是嵌在 chunk 里，稍后兜底扫描）
        final id3Texts = _readId3v2(raf, offset: 0);
        if (id3Texts != null) texts.addAll(id3Texts);

        // 部分 FLAC / OGG 会被打标工具在文件头塞一段 ID3：真正的音频头
        // 在 ID3 之后，魔数识别必须从标签结束处开始，否则 fLaC/OggS 匹配不到。
        final dataStart = _id3TagEnd(raf);

        // 2) FLAC / OGG / MP4 / APE 魔数识别（ID3 存在时也继续，双标签共存的情况不少见）
        final head = _readAt(raf, dataStart, 64);
        if (_startsWith(head, [0x66, 0x4C, 0x61, 0x43])) {
          // "fLaC"
          final t = _readFlac(raf, start: dataStart);
          if (t != null) texts.addAll(t);
        } else if (_startsWith(head, [0x4F, 0x67, 0x67, 0x53])) {
          // "OggS"
          final t = _readOgg(raf, start: dataStart);
          if (t != null) texts.addAll(t);
        } else if (length > 12 && _equalsAt(head, 4, 'ftyp')) {
          // MP4 / M4A：第 4-7 字节是 'ftyp'
          final t = _readMp4(raf, start: dataStart);
          if (t != null) texts.addAll(t);
        } else if (_startsWith(head, [0x4D, 0x41, 0x43, 0x20])) {
          // "MAC " → Monkey's Audio，通常带 APEv2 尾标签
          final t = _readApeV2(raf, length);
          if (t != null) texts.addAll(t);
        }

        // 3) 无 ID3 且是 MP3（可能只有 APEv2 尾标签）或 WAV（ID3 chunk 藏在数据区）
        if (texts.isEmpty) {
          final isMp3 = _isMp3FrameSync(head) || (id3Texts != null);
          if (isMp3) {
            final t = _readApeV2(raf, length);
            if (t != null) texts.addAll(t);
          }
          if (texts.isEmpty && _startsWith(head, [0x52, 0x49, 0x46, 0x46])) {
            // "RIFF" → WAV：扫描内嵌 ID3 chunk
            final t = _readWavId3(raf);
            if (t != null) texts.addAll(t);
          }
        }

        if (texts.isEmpty) return null;

        // ── 解析：优先含 LRC 时间戳的文本 ──
        for (final text in texts) {
          if (text.isEmpty) continue;
          if (_hasLrcTimestamps(text)) {
            final lines = LyricParser.parse(text);
            if (lines.isNotEmpty) return lines;
          }
        }
        return null;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  /// 真机诊断：返回内嵌歌词未命中的原因（仅在加载失败时调用一次）。
  /// 复用与 [extractSync] 相同的魔数识别 / 标签读取路径，便于定位是
  /// 「路径不可读」「容器不识别」「无歌词标签」还是「标签文本格式不匹配」。
  static String diagnoseSync(String audioPath) {
    try {
      final file = File(audioPath);
      if (!file.existsSync()) return '文件不存在 ($audioPath)';
      final raf = file.openSync();
      try {
        final length = raf.lengthSync();
        final dataStart = _id3TagEnd(raf);
        final head = _readAt(raf, dataStart, 64);
        final magicBytes = head.take(4).toList();
        final magic = String.fromCharCodes(
          magicBytes.map((b) => (b >= 32 && b < 127) ? b : 46),
        );
        final texts = <String>[];
        final id3 = _readId3v2(raf, offset: 0);
        if (id3 != null) texts.addAll(id3);
        if (_startsWith(head, [0x66, 0x4C, 0x61, 0x43])) {
          final t = _readFlac(raf, start: dataStart);
          if (t != null) texts.addAll(t);
        } else if (_startsWith(head, [0x4F, 0x67, 0x67, 0x53])) {
          final t = _readOgg(raf, start: dataStart);
          if (t != null) texts.addAll(t);
        } else if (length > 12 && _equalsAt(head, 4, 'ftyp')) {
          final t = _readMp4(raf, start: dataStart);
          if (t != null) texts.addAll(t);
        }
        if (texts.isEmpty) {
          return '魔数=$magic(${magicBytes.join(',')}) 无歌词标签 size=$length';
        }
        final nl = String.fromCharCode(10);
        final sb = StringBuffer('魔数=$magic 候选=${texts.length}');
        for (final t in texts.take(2)) {
          final preview = (t.length > 60 ? t.substring(0, 60) : t)
              .replaceAll(nl, ' ');
          sb.write(' | len=${t.length} 时间戳=${_hasLrcTimestamps(t)} 预览=$preview');
        }
        return sb.toString();
      } finally {
        raf.closeSync();
      }
    } catch (e) {
      return '异常: $e';
    }
  }

  /// 读取音频基础标签（标题 / 艺术家），用于 MediaStore 未收录或缺失时的
  /// 回退显示与歌词在线搜索。容器识别逻辑与 [extractSync] 一致。
  ///
  /// 必须在非主 isolate 中调用（内部有同步文件 IO）。
  /// 无任何可用标签时返回 null。
  static ({String? title, String? artist})? readTagsSync(String audioPath) {
    try {
      final file = File(audioPath);
      if (!file.existsSync()) return null;
      final raf = file.openSync();
      try {
        final length = raf.lengthSync();
        if (length < 16) return null;

        final tags = <String, String>{};

        // 1) 文件头 ID3v2（MP3；WAV 的 chunk 内 ID3 见下方 RIFF 分支）
        _readId3v2(raf, offset: 0, tags: tags);

        // FLAC / OGG 头部可能被塞了 ID3，魔数识别从标签结束处开始
        final dataStart = _id3TagEnd(raf);
        final head = _readAt(raf, dataStart, 64);
        if (_startsWith(head, [0x66, 0x4C, 0x61, 0x43])) {
          // "fLaC"
          _readFlac(raf, start: dataStart, tags: tags);
        } else if (_startsWith(head, [0x4F, 0x67, 0x67, 0x53])) {
          // "OggS"
          _readOgg(raf, start: dataStart, tags: tags);
        } else if (length > 12 && _equalsAt(head, 4, 'ftyp')) {
          // MP4 / M4A
          _readMp4Tags(raf, start: dataStart, tags: tags);
        } else if (_startsWith(head, [0x52, 0x49, 0x46, 0x46])) {
          // "RIFF" → WAV：扫描内嵌 ID3 chunk
          _readWavId3(raf, tags);
        }

        // 2) APEv2 尾标签兜底（MP3 / Monkey's Audio 常见）
        if (!tags.containsKey('artist') || !tags.containsKey('title')) {
          final apeTags = <String, String>{};
          _readApeV2(raf, length, apeTags);
          for (final e in apeTags.entries) {
            tags.putIfAbsent(e.key, () => e.value);
          }
        }

        final title = _cleanTag(tags['title']);
        final artist = _cleanTag(tags['artist'] ?? tags['albumartist']);
        if (title == null && artist == null) return null;
        return (title: title, artist: artist);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  /// 标签值清洗：去掉字符串终止符与首尾空白，空串归一为 null。
  static String? _cleanTag(String? raw) {
    if (raw == null) return null;
    final v = raw.replaceAll('\x00', '').trim();
    return v.isEmpty ? null : v;
  }

  // ════════════════════════ ID3v2 ════════════════════════

  /// 解析文件偏移 [offset] 处的 ID3v2 标签，返回 USLT/SYLT 候选文本。
  /// 不存在 ID3 时返回 null。传入 [tags] 时同时收集基础文本帧
  /// （TPE1/TP1 → artist，TIT2/TT2 → title，首个生效）。
  static List<String>? _readId3v2(RandomAccessFile raf,
      {int offset = 0, Map<String, String>? tags}) {
    try {
      final header = _readAt(raf, offset, 10);
      if (header.length < 10) return null;
      if (!_equalsAscii(header, 0, 'ID3')) return null;

      final major = header[3];
      final flags = header[5];
      final tagSize = _synchsafe(header, 6); // 不含 10 字节头
      if (tagSize <= 0 || tagSize > _maxId3Bytes) return null;

      final body = _readAt(raf, offset + 10, tagSize);
      if (body.length < tagSize) return null;

      // 全局反同步（v2.3 常见）：FF 00 → FF
      Uint8List data = (flags & 0x80) != 0 ? _deUnsync(body) : body;
      int pos = 0;

      // 扩展头：跳过
      if ((flags & 0x40) != 0) {
        if (major == 3) {
          if (data.length < 4) return null;
          final extSize = _be32(data, 0);
          pos += extSize + 4;
        } else if (major == 4) {
          if (data.length < 4) return null;
          pos += _synchsafe(data, 0);
        }
      }

      final texts = <String>[];
      final idLen = major <= 2 ? 3 : 4;
      final sizeLen = major <= 2 ? 3 : 4;

      while (pos + idLen + sizeLen <= data.length) {
        final id = String.fromCharCodes(data.sublist(pos, pos + idLen));
        if (id.isEmpty || !_isPrintableId(id)) break; // 进入 padding

        int frameSize;
        int fpos = pos + idLen;
        if (major <= 2) {
          frameSize = (data[fpos] << 16) | (data[fpos + 1] << 8) | data[fpos + 2];
          fpos += 3;
        } else if (major == 4) {
          frameSize = _synchsafe(data, fpos);
          fpos += 4;
        } else {
          frameSize = _be32(data, fpos);
          fpos += 4;
        }

        int frameFlags = 0;
        if (major >= 3) {
          if (fpos + 2 > data.length) break;
          frameFlags = (data[fpos] << 8) | data[fpos + 1];
          fpos += 2;
        }
        if (frameSize <= 0 ||
            fpos + frameSize > data.length ||
            frameSize > _maxId3Bytes) {
          break;
        }

        Uint8List content = data.sublist(fpos, fpos + frameSize);
        // v2.4 帧级反同步
        if (major == 4 && (frameFlags & 0x02) != 0) {
          content = _deUnsync(content);
        }

        final isLyricsText = id == 'USLT' || id == 'ULT';
        final isSynced = id == 'SYLT' || id == 'SLT';
        if (isLyricsText) {
          final t = _parseUslt(content);
          if (t != null) texts.add(t);
        } else if (isSynced) {
          final t = _parseSylt(content);
          if (t != null) texts.add(t);
        } else if (tags != null) {
          // 文本帧：v2.2 用 3 字符 ID，v2.3+ 用 4 字符 ID
          final isArtistFrame =
              id == 'TPE1' || (major <= 2 && id == 'TP1');
          final isTitleFrame =
              id == 'TIT2' || (major <= 2 && id == 'TT2');
          if (isArtistFrame && !tags.containsKey('artist')) {
            final t = _parseId3TextFrame(content);
            if (t != null) tags['artist'] = t;
          } else if (isTitleFrame && !tags.containsKey('title')) {
            final t = _parseId3TextFrame(content);
            if (t != null) tags['title'] = t;
          }
        }
        pos = fpos + frameSize;
      }
      return texts.isEmpty ? null : texts;
    } catch (_) {
      return null;
    }
  }

  /// USLT：编码(1) + 语言(3) + 描述符(null 结尾) + 歌词文本。
  static String? _parseUslt(Uint8List b) {
    try {
      if (b.length < 5) return null;
      final enc = b[0];
      int pos = 4; // 跳过编码 + 语言
      // 描述符按编码宽度的 null 结尾
      final wide = enc == 1 || enc == 2;
      if (wide) {
        while (pos + 1 < b.length && !(b[pos] == 0 && b[pos + 1] == 0)) {
          pos += 2;
        }
        pos += 2;
      } else {
        while (pos < b.length && b[pos] != 0) {
          pos++;
        }
        pos += 1;
      }
      if (pos >= b.length) return null;
      final text = _decodeText(b.sublist(pos), enc);
      return (text == null || text.trim().isEmpty) ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// ID3 文本帧（TPE1/TIT2 等）：编码(1) + 文本（可能带 null 终止符）。
  static String? _parseId3TextFrame(Uint8List b) {
    try {
      if (b.isEmpty) return null;
      final text = _decodeText(b.sublist(1), b[0]);
      if (text == null) return null;
      return text.split('\x00').first.trim();
    } catch (_) {
      return null;
    }
  }

  /// SYLT：编码(1) + 语言(3) + 时间格式(1) + 内容类型(1) + 描述符(null 结尾)
  /// + N 组 [文本(null 结尾) + 时间戳(4B)]。
  /// 转成 LRC 文本返回（时间格式 2 = 毫秒；1 = MPEG 帧，无帧信息无法转换则放弃）。
  static String? _parseSylt(Uint8List b) {
    try {
      if (b.length < 7) return null;
      final enc = b[0];
      final timeFormat = b[4];
      if (timeFormat != 2) return null; // 帧计数格式无法换算
      final wide = enc == 1 || enc == 2;
      int pos = 6;
      // 描述符
      if (wide) {
        while (pos + 1 < b.length && !(b[pos] == 0 && b[pos + 1] == 0)) {
          pos += 2;
        }
        pos += 2;
      } else {
        while (pos < b.length && b[pos] != 0) {
          pos++;
        }
        pos += 1;
      }

      final rows = <(int, String)>[];
      while (pos < b.length) {
        final (text, next) = _readNullString(b, pos, wide);
        if (next + 4 > b.length) break;
        final stamp = _be32(b, next);
        pos = next + 4;
        if (text.trim().isEmpty && rows.isNotEmpty) continue;
        rows.add((stamp, text));
      }
      if (rows.isEmpty) return null;
      rows.sort((a, b2) => a.$1.compareTo(b2.$1));
      final sb = StringBuffer();
      for (final (ms, text) in rows) {
        sb.writeln('[${_msToLrcStamp(ms)}]$text');
      }
      return sb.toString();
    } catch (_) {
      return null;
    }
  }

  // ════════════════════════ Vorbis Comment（FLAC / OGG）════════════════════════

  static List<String>? _readFlac(RandomAccessFile raf,
      {int start = 0, Map<String, String>? tags}) {
    try {
      int pos = start + 4; // 跳过 fLaC
      while (true) {
        final head = _readAt(raf, pos, 4);
        if (head.length < 4) return null;
        final isLast = (head[0] & 0x80) != 0;
        final type = head[0] & 0x7F;
        final size = (head[1] << 16) | (head[2] << 8) | head[3];
        if (type == 4) {
          final block = _readAt(raf, pos + 4, size);
          if (block.length < size) return null;
          return _parseVorbisComments(block, start: 0, tags: tags);
        }
        if (isLast || size < 0 || size > (16 << 20)) return null;
        pos += 4 + size;
      }
    } catch (_) {
      return null;
    }
  }

  static List<String>? _readOgg(RandomAccessFile raf,
      {int start = 0, Map<String, String>? tags}) {
    try {
      final scan = _readAt(raf, start, _maxOggScanBytes);
      // Vorbis: 0x03 'vorbis'；Opus: 'OpusTags'
      int commentStart = -1;
      for (int i = 0; i + 7 <= scan.length; i++) {
        if (scan[i] == 0x03 &&
            _equalsAscii(scan, i + 1, 'vorbis')) {
          commentStart = i + 7;
          break;
        }
        if (_equalsAscii(scan, i, 'OpusTags')) {
          commentStart = i + 8;
          break;
        }
      }
      if (commentStart < 0) return null;
      return _parseVorbisComments(scan, start: commentStart, tags: tags);
    } catch (_) {
      return null;
    }
  }

  /// 解析 Vorbis Comment 结构：供应商长度(4LE) + 供应商 + 条目数(4LE) +
  /// N 条 [长度(4LE) + "KEY=value"]。[start] 为起始偏移，最多向后扫 2MB。
  /// 传入 [tags] 时同时收集 TITLE / ARTIST / ALBUMARTIST（首个生效；
  /// ALBUMARTIST 单独存 albumartist 槽，避免抢在 ARTIST 前出现时顶掉它）。
  static List<String>? _parseVorbisComments(Uint8List b,
      {required int start, Map<String, String>? tags}) {
    try {
      int pos = start;
      int readLe32() {
        if (pos + 4 > b.length) throw RangeError('vorbis eof');
        final v = b[pos] | (b[pos + 1] << 8) | (b[pos + 2] << 16) | (b[pos + 3] << 24);
        pos += 4;
        return v;
      }

      final vendorLen = readLe32();
      if (vendorLen < 0 || vendorLen > (1 << 20)) return null;
      pos += vendorLen;
      final count = readLe32();
      if (count < 0 || count > 512) return null;

      final texts = <String>[];
      for (int i = 0; i < count; i++) {
        final len = readLe32();
        if (len < 0 || pos + len > b.length || len > (1 << 20)) break;
        final entry = utf8.decode(b.sublist(pos, pos + len), allowMalformed: true);
        pos += len;
        final eq = entry.indexOf('=');
        if (eq <= 0) continue;
        final key = entry.substring(0, eq).toUpperCase().replaceAll(RegExp(r'\s+'), '');
        final value = entry.substring(eq + 1);
        // contains('LYRICS') 兼容 key 变体：lyrics / LYRICS:eng / UNSYNCEDLYRICS 等
        if (key.contains('LYRICS')) {
          texts.add(value);
        } else if (tags != null) {
          if (key == 'TITLE') {
            tags.putIfAbsent('title', () => value);
          } else if (key == 'ARTIST') {
            tags.putIfAbsent('artist', () => value);
          } else if (key == 'ALBUMARTIST') {
            tags.putIfAbsent('albumartist', () => value);
          }
        }
      }
      return texts.isEmpty ? null : texts;
    } catch (_) {
      return null;
    }
  }

  // ════════════════════════ MP4 / M4A ════════════════════════

  static List<String>? _readMp4(RandomAccessFile raf, {int start = 0}) {
    try {
      final length = raf.lengthSync();
      final ilst = _findMp4Ilst(raf, start, length);
      if (ilst < 0) return null;
      final text = _readMp4IlstText(raf, ilst, length, '\u00A9lyr');
      return text == null ? null : [text];
    } catch (_) {
      return null;
    }
  }

  /// 读取 MP4 基础标签：ilst 内的 ©nam（标题）与 ©ART（艺术家）。
  static void _readMp4Tags(RandomAccessFile raf,
      {int start = 0, required Map<String, String> tags}) {
    try {
      final length = raf.lengthSync();
      final ilst = _findMp4Ilst(raf, start, length);
      if (ilst < 0) return;
      final title = _readMp4IlstText(raf, ilst, length, '\u00A9nam');
      if (title != null) tags.putIfAbsent('title', () => title);
      final artist = _readMp4IlstText(raf, ilst, length, '\u00A9ART');
      if (artist != null) tags.putIfAbsent('artist', () => artist);
    } catch (_) {
      // 静默：标签读取失败不影响主流程
    }
  }

  /// 逐层下钻 moov → udta → meta → ilst，返回 ilst 原子内容区起始偏移。
  static int _findMp4Ilst(RandomAccessFile raf, int start, int fileLength) {
    int pos = start;
    for (final name in ['moov', 'udta', 'meta', 'ilst']) {
      final found = _findMp4Atom(raf, pos, fileLength, name);
      if (found < 0) return -1;
      // meta 原子头后有 4 字节 version/flags，子原子从 +8+4 开始
      pos = (name == 'meta') ? found + 12 : found + 8;
    }
    return pos;
  }

  /// 读取 ilst 内名为 [name] 的原子中 data 原子里的 UTF-8 文本。
  static String? _readMp4IlstText(
      RandomAccessFile raf, int ilstStart, int fileLength, String name) {
    final target = _findMp4Atom(raf, ilstStart, fileLength, name);
    if (target < 0) return null;

    // 原子内的 data 原子：size + 'data' + version/flags(4) + reserved(4) + utf8 文本
    final head = _readAt(raf, target, 8);
    if (head.length < 8) return null;
    final size = _be32(head, 0);
    if (size <= 16 || size > (4 << 20)) return null;
    final dataHead = _readAt(raf, target + 8, 16);
    if (dataHead.length < 16 || !_equalsAscii(dataHead, 4, 'data')) return null;
    final textBytes = _readAt(raf, target + 24, size - 16);
    final text = utf8.decode(textBytes, allowMalformed: true);
    return text.trim().isEmpty ? null : text;
  }

  /// 在 [start, end) 范围内逐个扫描同层原子，返回名为 [name] 的原子头偏移。
  static int _findMp4Atom(RandomAccessFile raf, int start, int end, String name) {
    try {
      int pos = start;
      while (pos + 8 <= end) {
        final head = _readAt(raf, pos, 8);
        if (head.length < 8) return -1;
        var size = _be32(head, 0);
        final type = String.fromCharCodes(head.sublist(4, 8));
        if (size == 1) {
          // 64 位长度：读高 4 字节足够（音频文件远小于 4GB 情况按 64 位处理头两层）
          final ext = _readAt(raf, pos + 8, 8);
          if (ext.length < 8) return -1;
          final hi = _be32(ext, 0);
          final lo = _be32(ext, 4);
          size = hi == 0 ? lo : end; // 超过 4GB 的极端情况直接扫到结尾
        } else if (size == 0) {
          size = end - pos;
        }
        if (size < 8) return -1;
        if (type == name) return pos;
        pos += size;
      }
      return -1;
    } catch (_) {
      return -1;
    }
  }

  // ════════════════════════ APEv2 ════════════════════════

  static List<String>? _readApeV2(RandomAccessFile raf, int fileLength,
      [Map<String, String>? tags]) {
    try {
      // 尾部 32 字节是 footer：magic(8) + version(4) + size(4) + items(4) + flags(4) + reserved(8)
      final footStart = fileLength - 32;
      if (footStart < 32) return null;
      final foot = _readAt(raf, footStart, 32);
      if (foot.length < 32 || !_equalsAscii(foot, 0, 'APETAGEX')) return null;

      final tagSize = _le32(foot, 12); // 含 footer（若含 header 则再加 32）
      final itemCount = _le32(foot, 16);
      final flags = _le32(foot, 20);
      if (tagSize <= 32 || tagSize > (8 << 20) || itemCount <= 0 || itemCount > 1000) {
        return null;
      }
      final hasHeader = (flags & 0x20000000) != 0; // bit29: tag contains header
      final itemsStart = footStart - (tagSize - 32) - (hasHeader ? 32 : 0);
      if (itemsStart < 0) return null;

      final items = _readAt(raf, itemsStart, tagSize - 32);
      int pos = 0;
      for (int i = 0; i < itemCount && pos + 8 <= items.length; i++) {
        final valueSize = _le32(items, pos);
        final valueFlags = _le32(items, pos + 4);
        pos += 8;
        int keyEnd = pos;
        while (keyEnd < items.length && items[keyEnd] != 0) {
          keyEnd++;
        }
        if (keyEnd >= items.length) break;
        final key = String.fromCharCodes(items.sublist(pos, keyEnd));
        pos = keyEnd + 1;
        if (pos + valueSize > items.length) break;
        if (valueSize <= (4 << 20) && (valueFlags & 0x6) == 0) {
          // type 0 = UTF-8 文本
          final text =
              utf8.decode(items.sublist(pos, pos + valueSize), allowMalformed: true);
          final ku = key.toUpperCase();
          if (ku == 'LYRICS') {
            if (text.trim().isNotEmpty) return [text];
          } else if (tags != null) {
            if (ku == 'ARTIST') {
              tags.putIfAbsent('artist', () => text);
            } else if (ku == 'ALBUM ARTIST') {
              tags.putIfAbsent('albumartist', () => text);
            } else if (ku == 'TITLE') {
              tags.putIfAbsent('title', () => text);
            }
          }
        }
        pos += valueSize;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ════════════════════════ WAV ════════════════════════

  /// WAV 的 ID3 通常在 'id3 ' chunk 里，但位置不定；直接扫描 RIFF 区前段找 'ID3' 魔数。
  /// 传入 [tags] 时同时收集基础文本帧。
  static List<String>? _readWavId3(RandomAccessFile raf,
      [Map<String, String>? tags]) {
    try {
      final scan = _readAt(raf, 0, _maxWavScanBytes);
      for (int i = 12; i + 10 <= scan.length; i++) {
        if (scan[i] == 0x49 && scan[i + 1] == 0x44 && scan[i + 2] == 0x33) {
          // 找到 'ID3'；合法性粗检：版本字节 < 5
          if (scan[i + 3] <= 4) {
            final texts = _readId3v2(raf, offset: i, tags: tags);
            if (texts != null) return texts;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 文件头 ID3v2 标签总长度（含 10 字节头与可能的 footer）；无 ID3 时返回 0。
  static int _id3TagEnd(RandomAccessFile raf) {
    try {
      final header = _readAt(raf, 0, 10);
      if (header.length < 10 || !_equalsAscii(header, 0, 'ID3')) return 0;
      int size = 10 + _synchsafe(header, 6);
      if ((header[5] & 0x10) != 0) size += 10; // footer
      return size;
    } catch (_) {
      return 0;
    }
  }

  // ════════════════════════ 工具函数 ════════════════════════

  static bool _hasLrcTimestamps(String text) {
    // 至少出现两个行首时间戳才认定是同步歌词，避免把 "[" 开头的普通文本误判
    final re = RegExp(r'\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]');
    if (re.allMatches(text).length >= 2) return true;
    // 毫秒制逐字格式（KRC 明文变体）: [起始ms,行时长ms]
    final ms = RegExp(r'\[\d{1,7},\d{1,7}\]');
    return ms.allMatches(text).length >= 2;
  }

  static String _msToLrcStamp(int ms) {
    final m = ms ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final frac = ms % 1000;
    return '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.'
        '${frac.toString().padLeft(3, '0')}';
  }

  /// 读取一个以编码宽度的 null 结尾的字符串，返回 (文本, 结束后偏移)。
  static (String, int) _readNullString(Uint8List b, int start, bool wide) {
    if (wide) {
      int i = start;
      while (i + 1 < b.length && !(b[i] == 0 && b[i + 1] == 0)) {
        i += 2;
      }
      return (_decodeUtf16(b.sublist(start, i)), i + 2);
    }
    int i = start;
    while (i < b.length && b[i] != 0) {
      i++;
    }
    return (latin1.decode(b.sublist(start, i)), i + 1);
  }

  static String? _decodeText(Uint8List bytes, int enc) {
    try {
      switch (enc) {
        case 0:
          return latin1.decode(bytes);
        case 1:
          return _decodeUtf16(bytes);
        case 2:
          return _decodeUtf16(bytes, bigEndian: true);
        case 3:
        default:
          return utf8.decode(bytes, allowMalformed: true);
      }
    } catch (_) {
      return null;
    }
  }

  /// UTF-16 解码（dart:convert 无内置）：按 BOM 或指定端序。
  static String _decodeUtf16(Uint8List bytes, {bool bigEndian = false}) {
    if (bytes.length < 2) return '';
    bool be = bigEndian;
    int start = 0;
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      be = false;
      start = 2;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      be = true;
      start = 2;
    }
    final units = <int>[];
    for (int i = start; i + 1 < bytes.length; i += 2) {
      units.add(be ? (bytes[i] << 8) | bytes[i + 1] : bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }

  /// 反同步：FF 00 → FF。
  static Uint8List _deUnsync(Uint8List b) {
    final out = BytesBuilder(copy: false);
    int i = 0;
    while (i < b.length) {
      if (i + 1 < b.length && b[i] == 0xFF && b[i + 1] == 0x00) {
        out.addByte(0xFF);
        i += 2;
      } else {
        out.addByte(b[i]);
        i++;
      }
    }
    return out.toBytes();
  }

  /// 定位读取：把文件位置设为 [start] 后读 [count] 字节（可能少于 count）。
  static Uint8List _readAt(RandomAccessFile raf, int start, int count) {
    raf.setPositionSync(start);
    return raf.readSync(count);
  }

  static bool _isPrintableId(String id) {
    for (final c in id.codeUnits) {
      if (!((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A))) return false;
    }
    return true;
  }

  static bool _isMp3FrameSync(Uint8List head) {
    return head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0;
  }

  static int _synchsafe(Uint8List b, int off) =>
      (b[off] & 0x7F) << 21 | (b[off + 1] & 0x7F) << 14 | (b[off + 2] & 0x7F) << 7 | (b[off + 3] & 0x7F);

  static int _be32(Uint8List b, int off) =>
      (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];

  static int _le32(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static bool _equalsAscii(Uint8List b, int off, String s) {
    if (off + s.length > b.length) return false;
    for (int i = 0; i < s.length; i++) {
      if (b[off + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  static bool _equalsAt(Uint8List b, int off, String s) => _equalsAscii(b, off, s);

  static bool _startsWith(Uint8List b, List<int> magic) {
    if (b.length < magic.length) return false;
    for (int i = 0; i < magic.length; i++) {
      if (b[i] != magic[i]) return false;
    }
    return true;
  }
}
