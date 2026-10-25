import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/core/utils.dart';

/// 「内容是文本、MIME 却像音视频」的格式判定（GitHub issue #43）。
///
/// 这组测试锁住两类边界，任何一侧松动都会直接变成用户可见的 bug：
/// - **漏判**：`.m3u` 认不出来 ⇒ 点开播放列表掉进音频播放器，而「打开方式 →
///   本应用打开」又因为已经「成功打开」不再弹类型选择器 ⇒ 用户只能先把后缀
///   改成 `.txt` 再改回来；
/// - **误伤**：把真音频（`.mp3` / `.flac`）判成文本 ⇒ 点歌曲进文本编辑器。
void main() {
  group('isTextDespiteMediaMime（文本格式、MIME 却像音视频）', () {
    test('播放列表 → true', () {
      expect(FileUtils.isTextDespiteMediaMime('a.m3u'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.m3u8'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.pls'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.asx'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.ram'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.xspf'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.wpl'), isTrue);
    });

    test('字幕 / 歌词 / cuesheet → true', () {
      expect(FileUtils.isTextDespiteMediaMime('a.srt'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.vtt'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.sbv'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.ass'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.ssa'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.lrc'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.cue'), isTrue);
    });

    test('大小写不敏感', () {
      expect(FileUtils.isTextDespiteMediaMime('MyList.M3U'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.SrT'), isTrue);
    });

    test('IM 追加后缀不影响判定（`a.m3u.1` 仍是播放列表）', () {
      expect(FileUtils.isTextDespiteMediaMime('a.m3u.1'), isTrue);
      expect(FileUtils.isTextDespiteMediaMime('a.srt.12'), isTrue);
    });

    test('真音视图 → false（绝不把媒体文件塞进文本编辑器）', () {
      expect(FileUtils.isTextDespiteMediaMime('a.mp3'), isFalse);
      expect(FileUtils.isTextDespiteMediaMime('a.flac'), isFalse);
      expect(FileUtils.isTextDespiteMediaMime('a.mp4'), isFalse);
      expect(FileUtils.isTextDespiteMediaMime('a.mkv'), isFalse);
      expect(FileUtils.isTextDespiteMediaMime('a.jpg'), isFalse);
      expect(FileUtils.isTextDespiteMediaMime('a.png'), isFalse);
    });

    test('普通文本 / 未知格式 → false（交给 isTextOrCode 兜底）', () {
      expect(FileUtils.isTextDespiteMediaMime('a.txt'), isFalse);
      expect(FileUtils.isTextDespiteMediaMime('a.ini'), isFalse);
      expect(FileUtils.isTextDespiteMediaMime('a.bin'), isFalse);
      expect(FileUtils.isTextDespiteMediaMime('noext'), isFalse);
    });

    test('名字里含 .m3u 但结尾不是该扩展名 → false', () {
      expect(FileUtils.isTextDespiteMediaMime('a.m3u.txt'), isFalse);
      expect(FileUtils.isTextDespiteMediaMime('m3u'), isFalse);
    });
  });

  group('canOpenAsText（是否给「用文本编辑器打开」入口）', () {
    test('播放列表 / 字幕 → true（issue #43 的核心场景）', () {
      expect(FileUtils.canOpenAsText('a.m3u'), isTrue);
      expect(FileUtils.canOpenAsText('a.m3u8'), isTrue);
      expect(FileUtils.canOpenAsText('a.srt'), isTrue);
      expect(FileUtils.canOpenAsText('a.lrc'), isTrue);
    });

    test('普通文本 / 配置 / 未知格式 → true', () {
      expect(FileUtils.canOpenAsText('a.txt'), isTrue);
      expect(FileUtils.canOpenAsText('a.ini'), isTrue);
      expect(FileUtils.canOpenAsText('a.log'), isTrue);
      expect(FileUtils.canOpenAsText('README'), isTrue);
      expect(FileUtils.canOpenAsText('a.bin'), isTrue);
    });

    test('图音视 → false（有更强的专用查看器）', () {
      expect(FileUtils.canOpenAsText('a.mp3'), isFalse);
      expect(FileUtils.canOpenAsText('a.flac'), isFalse);
      expect(FileUtils.canOpenAsText('a.mp4'), isFalse);
      expect(FileUtils.canOpenAsText('a.mkv'), isFalse);
      expect(FileUtils.canOpenAsText('a.jpg'), isFalse);
      expect(FileUtils.canOpenAsText('a.png'), isFalse);
    });

    test('压缩包 → false', () {
      expect(FileUtils.canOpenAsText('a.zip'), isFalse);
      expect(FileUtils.canOpenAsText('a.7z'), isFalse);
      expect(FileUtils.canOpenAsText('a.tar.gz'), isFalse);
    });

    test('IM 追加后缀同样按归一化名字判', () {
      expect(FileUtils.canOpenAsText('a.m3u.1'), isTrue);
      expect(FileUtils.canOpenAsText('a.mp3.1'), isFalse);
      expect(FileUtils.canOpenAsText('a.jpg.2'), isFalse);
    });
  });
}
