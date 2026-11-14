import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/embedded_lyrics_service.dart';
import 'package:zenfile/services/lyric_parser.dart';

/// 构造 ID3v2.3 帧
Uint8List _id3Frame(String id, Uint8List content) {
  final b = BytesBuilder();
  b.add(ascii.encode(id));
  final size = ByteData(4)..setUint32(0, content.length, Endian.big);
  b.add(size.buffer.asUint8List());
  b.add(Uint8List.fromList([0x00, 0x00])); // flags
  b.add(content);
  return b.toBytes();
}

/// 构造完整 ID3v2.3 标签
Uint8List _id3v23(List<Uint8List> frames) {
  final body = BytesBuilder();
  for (final f in frames) {
    body.add(f);
  }
  final bodyBytes = body.toBytes();

  final head = BytesBuilder();
  head.add(ascii.encode('ID3'));
  head.add(Uint8List.fromList([0x03, 0x00, 0x00])); // v2.3, 无 flag
  final size = ByteData(4);
  final s = bodyBytes.length;
  size.setUint32(0, ((s >> 21) & 0x7F) << 24 | ((s >> 14) & 0x7F) << 16 | ((s >> 7) & 0x7F) << 8 | (s & 0x7F), Endian.big);
  head.add(size.buffer.asUint8List());
  head.add(bodyBytes);
  return head.toBytes();
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('embedded_lyrics_test');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  String file(String name, List<int> bytes) {
    final f = File('${tmp.path}/$name');
    f.writeAsBytesSync(bytes);
    return f.path;
  }

  test('MP3: ID3v2.3 USLT 内嵌 LRC 文本', () {
    const lrc = '[ti:测试]\n[00:01.00]第一行\n[00:05.50]第二行\n[00:10.00]第三行\n';
    final uslt = BytesBuilder();
    uslt.add(Uint8List.fromList([0x03])); // UTF-8
    uslt.add(ascii.encode('chi'));
    uslt.add(Uint8List.fromList([0x00])); // 空描述符
    uslt.add(utf8.encode(lrc));

    final mp3 = BytesBuilder();
    mp3.add(_id3v23([_id3Frame('USLT', uslt.toBytes())]));
    // 补一个假的 MPEG 帧头让文件看起来像 MP3
    mp3.add(Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00]) + List.filled(400, 0x11));

    final lyrics = EmbeddedLyricsService.extractSync(file('a.mp3', mp3.toBytes()));
    expect(lyrics, isNotNull);
    expect(lyrics!.length, 3);
    expect(lyrics[0].timestamp, const Duration(milliseconds: 1000));
    expect(lyrics[1].text, '第二行');
  });

  test('MP3: ID3v2.4 SYLT 同步歌词转为 LRC 解析', () {
    // 编码(1) + 语言(3) + 时间格式(1, 2=毫秒) + 内容类型(1) + 描述符 + 行+时间戳
    final sylt = BytesBuilder();
    sylt.add(Uint8List.fromList([0x03])); // UTF-8
    sylt.add(ascii.encode('eng'));
    sylt.add(Uint8List.fromList([0x02])); // 毫秒
    sylt.add(Uint8List.fromList([0x01])); // 歌词
    sylt.add(Uint8List.fromList([0x00])); // 空描述符

    void row(String text, int ms) {
      sylt.add(utf8.encode(text));
      sylt.add(Uint8List.fromList([0x00]));
      final ts = ByteData(4)..setUint32(0, ms, Endian.big);
      sylt.add(ts.buffer.asUint8List());
    }

    row('hello', 2000);
    row('world', 6500);

    final mp3 = BytesBuilder();
    mp3.add(_id3v23([_id3Frame('SYLT', sylt.toBytes())]));
    mp3.add(Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00]) + List.filled(400, 0x22));

    final lyrics = EmbeddedLyricsService.extractSync(file('b.mp3', mp3.toBytes()));
    expect(lyrics, isNotNull);
    expect(lyrics!.length, 2);
    expect(lyrics[0].timestamp, const Duration(milliseconds: 2000));
    expect(lyrics[0].text, 'hello');
    expect(lyrics[1].timestamp, const Duration(milliseconds: 6500));
  });

  test('MP3: 无内嵌歌词返回 null', () {
    final mp3 = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00] + List.filled(1000, 0x33));
    expect(EmbeddedLyricsService.extractSync(file('c.mp3', mp3)), isNull);
  });

  test('FLAC: Vorbis Comment LYRICS 字段', () {
    final vendor = utf8.encode('test');
    final entry = utf8.encode('LYRICS=[00:02.00]flac行一\n[00:04.00]flac行二');

    final comment = BytesBuilder();
    final vd = ByteData(4)..setUint32(0, vendor.length, Endian.little);
    comment.add(vd.buffer.asUint8List());
    comment.add(vendor);
    final cd = ByteData(4)..setUint32(0, 1, Endian.little);
    comment.add(cd.buffer.asUint8List());
    final ed = ByteData(4)..setUint32(0, entry.length, Endian.little);
    comment.add(ed.buffer.asUint8List());
    comment.add(entry);
    final commentBytes = comment.toBytes();

    final flac = BytesBuilder();
    flac.add(ascii.encode('fLaC'));
    // STREAMINFO 块（type 0，非最后）34 字节
    flac.add(Uint8List.fromList([0x00, 0x00, 0x00, 0x22]) + List.filled(34, 0));
    // VORBIS_COMMENT 块（type 4，最后一块 0x84）
    flac.add(Uint8List.fromList([0x84, (commentBytes.length >> 16) & 0xFF, (commentBytes.length >> 8) & 0xFF, commentBytes.length & 0xFF]));
    flac.add(commentBytes);

    final lyrics = EmbeddedLyricsService.extractSync(file('d.flac', flac.toBytes()));
    expect(lyrics, isNotNull);
    expect(lyrics!.length, 2);
    expect(lyrics[0].text, 'flac行一');
    expect(lyrics[1].timestamp, const Duration(milliseconds: 4000));
  });

  test('FLAC 带 ID3 前缀 + 小写键名变体', () {
    final vendor = utf8.encode('test');
    final entry = utf8.encode('lyrics:eng=[00:02.50]id3flac一\n[00:05.00]id3flac二');
    final comment = BytesBuilder();
    final vd = ByteData(4)..setUint32(0, vendor.length, Endian.little);
    comment.add(vd.buffer.asUint8List());
    comment.add(vendor);
    final cd = ByteData(4)..setUint32(0, 1, Endian.little);
    comment.add(cd.buffer.asUint8List());
    final ed = ByteData(4)..setUint32(0, entry.length, Endian.little);
    comment.add(ed.buffer.asUint8List());
    comment.add(entry);
    final cb = comment.toBytes();

    final flacBody = BytesBuilder();
    flacBody.add(ascii.encode('fLaC'));
    flacBody.add(Uint8List.fromList([0x00, 0x00, 0x00, 0x22]) + List.filled(34, 0));
    flacBody.add(Uint8List.fromList([0x84, (cb.length >> 16) & 0xFF, (cb.length >> 8) & 0xFF, cb.length & 0xFF]));
    flacBody.add(cb);

    // 前置一个含 TIT2 的 ID3v2.3（无歌词）
    final tit2 = utf8.encode('测试歌曲');
    final id3 = BytesBuilder();
    final body = BytesBuilder();
    body.add(ascii.encode('TIT2'));
    final fs = ByteData(4)..setUint32(0, tit2.length, Endian.big);
    body.add(fs.buffer.asUint8List());
    body.add(Uint8List.fromList([0, 0]));
    body.add(tit2);
    final bb = body.toBytes();
    id3.add(ascii.encode('ID3'));
    id3.add(Uint8List.fromList([0x03, 0x00, 0x00]));
    final s = bb.length;
    id3.add(Uint8List.fromList([((s >> 21) & 0x7F), ((s >> 14) & 0x7F), ((s >> 7) & 0x7F), (s & 0x7F)]));
    id3.add(bb);

    final full = BytesBuilder();
    full.add(id3.toBytes());
    full.add(flacBody.toBytes());

    final lyrics = EmbeddedLyricsService.extractSync(file('i.flac', full.toBytes()));
    expect(lyrics, isNotNull);
    expect(lyrics!.length, 2);
    expect(lyrics[0].text, 'id3flac一');
    expect(lyrics[0].timestamp, const Duration(milliseconds: 2500));
  });

  test('OGG Opus: OpusTags LYRICS 字段', () {
    final vendor = utf8.encode('opus-test');
    final entry = utf8.encode('UNSYNCEDLYRICS=[00:01.00]opus一\n[00:03.00]opus二');

    final tags = BytesBuilder();
    tags.add(ascii.encode('OpusTags'));
    final vd = ByteData(4)..setUint32(0, vendor.length, Endian.little);
    tags.add(vd.buffer.asUint8List());
    tags.add(vendor);
    final cd = ByteData(4)..setUint32(0, 1, Endian.little);
    tags.add(cd.buffer.asUint8List());
    final ed = ByteData(4)..setUint32(0, entry.length, Endian.little);
    tags.add(ed.buffer.asUint8List());
    tags.add(entry);

    final oggPage = BytesBuilder();
    oggPage.add(ascii.encode('OggS'));
    oggPage.add(Uint8List.fromList(List.filled(22, 0)));
    oggPage.add(Uint8List.fromList([1, 0])); // 1 segment
    oggPage.add(Uint8List.fromList([tags.toBytes().length & 0xFF]));
    oggPage.add(tags.toBytes());

    final lyrics = EmbeddedLyricsService.extractSync(file('e.opus', oggPage.toBytes()));
    expect(lyrics, isNotNull);
    expect(lyrics!.length, 2);
    expect(lyrics[1].text, 'opus二');
  });

  test('M4A: ©lyr 原子', () {
    Uint8List atom(String type, List<int> payload) {
      final b = BytesBuilder();
      final size = ByteData(4)..setUint32(0, 8 + payload.length, Endian.big);
      b.add(size.buffer.asUint8List());
      b.add(ascii.encode(type));
      b.add(payload);
      return b.toBytes();
    }

    final lyricsText = utf8.encode('[00:02.00]m4a一\n[00:06.00]m4a二');
    final dataAtom = atom('data', [0, 0, 0, 1, 0, 0, 0, 0] + lyricsText);
    final lyrAtom = BytesBuilder();
    final lyrSize = ByteData(4)..setUint32(0, 8 + dataAtom.length, Endian.big);
    lyrAtom.add(lyrSize.buffer.asUint8List());
    lyrAtom.add(Uint8List.fromList([0xA9, 0x6C, 0x79, 0x72])); // ©lyr
    lyrAtom.add(dataAtom);

    final ilst = atom('ilst', lyrAtom.toBytes());
    final meta = BytesBuilder();
    final metaSize = ByteData(4)..setUint32(0, 8 + 4 + ilst.length, Endian.big);
    meta.add(metaSize.buffer.asUint8List());
    meta.add(ascii.encode('meta'));
    meta.add(Uint8List.fromList([0, 0, 0, 0])); // version/flags
    meta.add(ilst);
    final udta = atom('udta', meta.toBytes());
    final moov = atom('moov', udta);

    final m4a = BytesBuilder();
    m4a.add(Uint8List.fromList([0, 0, 0, 16]));
    m4a.add(ascii.encode('ftyp'));
    m4a.add(ascii.encode('M4A '));
    m4a.add(Uint8List.fromList([0, 0, 0, 0]));
    m4a.add(moov);

    final lyrics = EmbeddedLyricsService.extractSync(file('f.m4a', m4a.toBytes()));
    expect(lyrics, isNotNull);
    expect(lyrics!.length, 2);
    expect(lyrics[0].text, 'm4a一');
  });

  test('WAV: 内嵌 ID3 chunk', () {
    const lrc = '[00:01.00]wav行\n[00:03.00]wav行二\n';
    final uslt = BytesBuilder();
    uslt.add(Uint8List.fromList([0x03]));
    uslt.add(ascii.encode('chi'));
    uslt.add(Uint8List.fromList([0x00]));
    uslt.add(utf8.encode(lrc));

    final id3 = _id3v23([_id3Frame('USLT', uslt.toBytes())]);
    final chunk = BytesBuilder();
    chunk.add(ascii.encode('id3 '));
    final sz = ByteData(4)..setUint32(0, id3.length, Endian.little);
    chunk.add(sz.buffer.asUint8List());
    chunk.add(id3);

    final wav = BytesBuilder();
    wav.add(ascii.encode('RIFF'));
    final riffSize = ByteData(4)..setUint32(0, 4 + 8 + chunk.toBytes().length, Endian.little);
    wav.add(riffSize.buffer.asUint8List());
    wav.add(ascii.encode('WAVE'));
    wav.add(chunk.toBytes());

    final lyrics = EmbeddedLyricsService.extractSync(file('g.wav', wav.toBytes()));
    expect(lyrics, isNotNull);
    expect(lyrics!.length, 2);
    expect(lyrics[0].text, 'wav行');
  });

  test('纯音乐占位文本仍返回 null（交上层走在线搜索/占位提示）', () {
    // 纯文本无时间戳 → 不认同步歌词
    final uslt = BytesBuilder();
    uslt.add(Uint8List.fromList([0x03]));
    uslt.add(ascii.encode('chi'));
    uslt.add(Uint8List.fromList([0x00]));
    uslt.add(utf8.encode('这是一段没有时间戳的普通文本歌词'));

    final mp3 = BytesBuilder();
    mp3.add(_id3v23([_id3Frame('USLT', uslt.toBytes())]));
    mp3.add(Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00]) + List.filled(400, 0x44));

    final path = file('h.mp3', mp3.toBytes());
    final lyrics = EmbeddedLyricsService.extractSync(path);
    expect(lyrics, isNull);
    // 顺带确认 LyricParser 对纯文本也解析不出（行为一致性）
    expect(LyricParser.parse('这是一段没有时间戳的普通文本歌词'), isEmpty);
  });

  // ── 毫秒制逐字格式（KRC 明文变体）──

  Uint8List vcBlock(List<String> entries) {
    final bb = BytesBuilder();
    final vendor = utf8.encode('test');
    final vlen = ByteData(4)..setUint32(0, vendor.length, Endian.little);
    bb.add(vlen.buffer.asUint8List());
    bb.add(vendor);
    final cnt = ByteData(4)..setUint32(0, entries.length, Endian.little);
    bb.add(cnt.buffer.asUint8List());
    for (final e in entries) {
      final eb = utf8.encode(e);
      final len = ByteData(4)..setUint32(0, eb.length, Endian.little);
      bb.add(len.buffer.asUint8List());
      bb.add(eb);
    }
    return bb.toBytes();
  }

  Uint8List flacWith(List<String> entries) {
    final bb = BytesBuilder();
    bb.add(utf8.encode('fLaC'));
    bb.add(Uint8List.fromList([0x00]) + Uint8List.fromList([0x00, 0x00, 0x22]));
    bb.add(List.filled(34, 0x00));
    final vc = vcBlock(entries);
    bb.add(Uint8List.fromList([0x84, (vc.length >> 16) & 0xFF, (vc.length >> 8) & 0xFF, vc.length & 0xFF]));
    bb.add(vc);
    bb.add(List.filled(200, 0x11));
    return bb.toBytes();
  }
  test('LyricParser: 毫秒制逐字格式（酷狗 KRC 明文 / 汽水导出变体）', () {
    const lrc = '[ti:测试歌曲]\n'
        '[ar:测试歌手]\n'
        '[offset:0]\n'
        '[795,4678]你(795,285)离(1080,282)开(1362,248)了(1610,286) - (4982,15)邓(4997,45)千(5042,188)荧(5230,243)\n'
        '[5473,1265]词(5473,225)：(5698,0)空(5698,214)鹫(5912,205)\n'
        '[16886,7506]想念的时候 蓦然回首\n';
    final lines = LyricParser.parse(lrc);
    expect(lines.length, 3);
    expect(lines[0].timestamp.inMilliseconds, 795);
    expect(lines[0].hasWordTimestamps, isTrue);
    expect(lines[0].text, '你离开了-邓千荧');
    expect(lines[0].words![0].text, '你');
    expect(lines[0].words![0].timestamp.inMilliseconds, 795);
    expect(lines[0].words![1].text, '离');
    expect(lines[0].words![1].timestamp.inMilliseconds, 1080);
    expect(lines[0].words![4].text, '-');
    expect(lines[0].words![4].timestamp.inMilliseconds, 4982);
    expect(lines[1].timestamp.inMilliseconds, 5473);
    expect(lines[1].text, '词：空鹫');
    expect(lines[1].words!.length, 4);
    expect(lines[2].text, '想念的时候 蓦然回首');
    expect(lines[2].hasWordTimestamps, isFalse);
  });

  test('LyricParser: 标准 LRC / Enhanced LRC / 多时间戳回归', () {
    final lrc = LyricParser.parse('[00:01.00]第一行\n[00:05.50]第二行\n');
    expect(lrc.length, 2);
    expect(lrc[0].timestamp.inMilliseconds, 1000);
    expect(lrc[1].text, '第二行');

    final elrc = LyricParser.parse('[00:01.00]<00:01.00>你<00:01.50>好\n');
    expect(elrc.length, 1);
    expect(elrc[0].hasWordTimestamps, isTrue);
    expect(elrc[0].words!.length, 2);

    final multi = LyricParser.parse('[00:01.00][00:05.00]重复歌词\n');
    expect(multi.length, 2);
    expect(multi[0].timestamp.inMilliseconds, 1000);
    expect(multi[1].timestamp.inMilliseconds, 5000);

    // 普通括号数字不应被毫秒逐字逻辑误伤（无 [ms,ms] 行戳时走原路径）
    final paren = LyricParser.parse('[00:01.00]这个问题(123,456)怎么看\n');
    expect(paren.length, 1);
    expect(paren[0].text.contains('(123,456)'), isTrue);
  });

  test('FLAC: Vorbis LYRICS 为毫秒制逐字格式时可解析（真实场景回归）', () {
    final path = file('i.flac', flacWith([
      'TITLE=测试歌曲',
      'ARTIST=测试歌手',
      'LYRICS=[795,4678]你(795,285)离(1080,282)开(1362,248)\n[5473,1265]第二行文本\n',
    ]));
    final lyrics = EmbeddedLyricsService.extractSync(path);
    expect(lyrics, isNotNull);
    expect(lyrics!.length, 2);
    expect(lyrics[0].timestamp.inMilliseconds, 795);
    expect(lyrics[0].hasWordTimestamps, isTrue);
  });

  test('readTagsSync: FLAC Vorbis 基础标签（ALBUMARTIST 不顶掉 ARTIST）', () {
    final path = file('j.flac', flacWith([
      'ALBUMARTIST=专辑歌手',
      'ARTIST=真实歌手',
      'TITLE=测试标题',
    ]));
    final tags = EmbeddedLyricsService.readTagsSync(path);
    expect(tags, isNotNull);
    expect(tags!.artist, '真实歌手');
    expect(tags.title, '测试标题');
  });

  test('diagnoseSync: 区分「文件不存在」与「有标签但无歌词」', () {
    final missing = EmbeddedLyricsService.diagnoseSync(
      '${Directory.systemTemp.path}/zenfile-no-such-audio.flac',
    );
    expect(missing, contains('文件不存在'));

    // 只有 TITLE/ARTIST、没有 LYRICS 的 FLAC：应报告魔数与无歌词标签
    final path = file('k.flac', flacWith([
      'TITLE=无歌词标题',
      'ARTIST=无歌词歌手',
    ]));
    final diag = EmbeddedLyricsService.diagnoseSync(path);
    expect(diag, contains('fLaC'));
    expect(diag, contains('无歌词标签'));
  });
}
