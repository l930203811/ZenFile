import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/lyric_animation_style.dart';
import 'package:zenfile/services/lyric_parser.dart';
import 'package:zenfile/services/lyric_timeline.dart';
import 'package:zenfile/ui/screens/audio_player/lyrics_view_widget.dart';

/// 「逐字重绘」风格的冒烟测试。
///
/// 这几种风格（meteor/drop/burst/cube/punch/wave）由 `_MotionLinePainter`
/// 逐字绘制，绘制路径与「整行 TextPainter + 裁剪」完全不同，最容易踩到
/// 字边界越界 / fill.index 落在行尾 / 句首之前等边界情况。这里在
/// 「列表视图 / 混合模式 / 单行槽位」三种布局 × 三个时间点上各画一帧，
/// 只要能画完且没有异常，就说明坐标换算没有越界。
void main() {
  // 第一句短、第二句长（会换行）、第三句普通；末尾留一个纯时间戳行。
  final lyrics = LyricParser.parse(
    '[00:01.00]第一句\n'
    '[00:04.00]第二句明显更长的歌词内容用来验证自动换行时的字边界\n'
    '[00:09.00]第三句',
  );

  const motionStyles = <LyricAnimationStyle>[
    LyricAnimationStyle.meteor,
    LyricAnimationStyle.drop,
    LyricAnimationStyle.burst,
    LyricAnimationStyle.cube,
    LyricAnimationStyle.punch,
    LyricAnimationStyle.wave,
  ];

  // 500ms = 句首之前（fill.index == -1）；2000ms = 首句唱到一半（有字已唱完、
  // 有字正在唱，meteor 的「坠落中 + 待坠」两态同时存在）；
  // 9000ms = 第二句唱完 / 第三句刚开始。
  const positions = <Duration>[
    Duration(milliseconds: 500),
    Duration(milliseconds: 2000),
    Duration(milliseconds: 9000),
  ];

  test('immersive 老设置平滑迁移到 meteor，且风格池覆盖它', () {
    // 旧版「沉浸巨幕」被流星坠落整体替换：老用户存的是 'immersive'，
    // 必须映射到新风格，不能掉回默认（否则一升级就换风格）。
    expect(
      LyricAnimationStyle.fromName('immersive'),
      LyricAnimationStyle.meteor,
    );
    expect(LyricAnimationStyle.fromName('meteor'), LyricAnimationStyle.meteor);
    expect(kLyricMixedStylePool, contains(LyricAnimationStyle.meteor));
    // 池里不能残留已删除的旧风格，也不能自引用。
    expect(kLyricMixedStylePool.contains(LyricAnimationStyle.mixed), isFalse);
    expect(
      kLyricMixedStylePool.toSet().length,
      kLyricMixedStylePool.length,
      reason: '池内不得重复',
    );
  });

  for (final style in [...motionStyles, LyricAnimationStyle.mixed]) {
    testWidgets('${style.name}: 列表视图逐帧绘制不抛异常', (tester) async {
      for (final pos in positions) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  height: 420,
                  child: LyricsViewWidget(
                    lyrics: lyrics,
                    position: pos,
                    accentColor: Colors.purple,
                    style: style,
                  ),
                ),
              ),
            ),
          ),
        );
        // 多推几帧：入场动画（burst / cube / punch）要跨过初始帧。
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(tester.takeException(), isNull, reason: '${style.name} @ $pos');
      }
    });

    testWidgets('${style.name}: 单行槽位逐帧绘制不抛异常', (tester) async {
      for (final pos in positions) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 360,
                  height: 44,
                  child: SingleLineLyricSweep(
                    lyrics: lyrics,
                    position: pos,
                    accentColor: Colors.purple,
                    style: style,
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(tester.takeException(), isNull, reason: '${style.name} @ $pos');
      }
    });
  }

  testWidgets('主动卸载后 ticker 正常释放', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 420,
            child: LyricsViewWidget(
              lyrics: lyrics,
              position: const Duration(milliseconds: 2000),
              accentColor: Colors.purple,
              style: LyricAnimationStyle.wave,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  // 末字的 endTime 恰好等于行尾（= 下一行起点），照它发射的话末字要等下一句
  // 开口才飘落 —— 用户反馈「最后一个字不坠落 / 下一句开始才坠落」。
  test('流星离格时刻：末字必须提前于行尾，且不早于本字开唱', () {
    final lines = LyricParser.parse(
      '[00:01.00]第一句短歌词\n'
      '[00:04.00]第二句明显更长的歌词内容用来验证自动换行时的字边界\n'
      '[00:09.00]第三句',
    );
    for (var i = 0; i < lines.length; i++) {
      final tl = buildLineTimeline(lines[i], lineEndForIndex(lines, i));
      final esc = meteorEscapeMs(tl);
      expect(esc.length, tl.graphemes.length);
      final lineEndMs = tl.lineEnd.inMilliseconds;
      // 1) 整句在本句内就散完：末字必须早于行尾（否则就是下一句才飘落）。
      expect(esc.last, lessThan(lineEndMs), reason: '第 $i 行末字没提前');
      // 2) 不得早于本字开唱（否则字还没唱就飞走）。
      for (var k = 0; k < tl.graphemes.length; k++) {
        expect(
          esc[k],
          greaterThanOrEqualTo(tl.graphemes[k].startTime.inMilliseconds),
          reason: '第 $i 行第 $k 个字早于开唱时刻',
        );
      }
      // 3) 严格保序。
      for (var k = 1; k < esc.length; k++) {
        expect(esc[k], greaterThan(esc[k - 1]), reason: '第 $i 行离格时刻未保序');
      }
    }
  });
}
