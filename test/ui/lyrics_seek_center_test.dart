import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/lyric_animation_style.dart';
import 'package:zenfile/services/lyric_parser.dart';
import 'package:zenfile/ui/screens/audio_player/lyrics_view_widget.dart';

/// 快进 / 快退后，当前播放行必须回到视口正中间。
///
/// 回归的是「目标行尚未被 ListView 构建时按固定 56dp/行估算偏移」的老实现：
/// 大字号风格（meteor / drop / cube / wave…）真实行高 65~100dp，估算会偏出
/// 几百 dp，且重试拿不到 RenderBox 就放弃 ⇒ 快进/快退后当前行不在屏幕中央、
/// 甚至完全看不见。
void main() {
  // 60 行，每行 4 秒。快进目标行（50）与快退目标行（4）故意写成超长句——
  // 会折成多条视觉行、明显比普通行高，这样在测试里能从已构建的列表项中
  // 把它认出来做「是否居中」的绝对校验（另一次跳转的目标行此时不在构建范围）。
  final buffer = StringBuffer();
  for (var i = 0; i < 60; i++) {
    final total = i * 4;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    final text = (i == 4 || i == 50)
        ? '第 $i 行是一句特别特别长的歌词内容用来制造一个明显更高的列表项'
              '便于在测试里认出它并校验它是否停在屏幕正中间的位置上'
        : '第 $i 行';
    buffer.writeln('[$m:$s.00]$text');
  }
  final lyrics = LyricParser.parse(buffer.toString());

  Widget app(Duration pos, LyricAnimationStyle style, double height) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 380,
          height: height,
          child: LyricsViewWidget(
            lyrics: lyrics,
            position: pos,
            accentColor: const Color(0xFFCDDC39),
            style: style,
            isPlaying: true,
          ),
        ),
      ),
    );
  }

  /// 已构建列表项里最高的那一项的中心离视口中心的距离（dp）。
  double tallestItemOffsetFromCenter(WidgetTester tester) {
    final viewport = tester.getRect(find.byType(ListView));
    final items = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(GestureDetector),
    );
    Rect? tallest;
    for (final element in items.evaluate()) {
      final box = element.renderObject as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (tallest == null || rect.height > tallest.height) tallest = rect;
    }
    expect(tallest, isNotNull, reason: '列表没有构建出任何行');
    return (tallest!.center.dy - viewport.center.dy).abs();
  }

  double scrollOffset(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .pixels;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
  }

  for (final height in [260.0, 700.0]) {
    for (final style in [
      LyricAnimationStyle.meteor,
      LyricAnimationStyle.drop,
      LyricAnimationStyle.cube,
      LyricAnimationStyle.wave,
      LyricAnimationStyle.classic,
      LyricAnimationStyle.echo,
    ]) {
      testWidgets('快进后当前行居中 ${style.name} h=$height', (tester) async {
        await tester.pumpWidget(app(Duration.zero, style, height));
        await settle(tester);
        // 0s -> 200s：跨 50 行，目标行必然尚未构建。
        await tester.pumpWidget(
          app(const Duration(seconds: 200), style, height),
        );
        await settle(tester);
        expect(
          tallestItemOffsetFromCenter(tester),
          lessThan(4.0),
          reason: '快进后当前行没有回到视口中央',
        );
      });

      testWidgets('快退后当前行居中 ${style.name} h=$height', (tester) async {
        await tester.pumpWidget(
          app(const Duration(seconds: 200), style, height),
        );
        await settle(tester);
        // 200s -> 16s：跨 46 行，目标行同样尚未构建。
        await tester.pumpWidget(
          app(const Duration(seconds: 16), style, height),
        );
        await settle(tester);
        expect(
          tallestItemOffsetFromCenter(tester),
          lessThan(4.0),
          reason: '快退后当前行没有回到视口中央',
        );
      });

      testWidgets('手动滑动后立即快进仍居中 ${style.name} h=$height', (tester) async {
        await tester.pumpWidget(app(Duration.zero, style, height));
        await settle(tester);
        // 用户先手动翻歌词（会置 _isUserScrolling，4s 内默认抑制自动滚动）。
        await tester.drag(find.byType(ListView), const Offset(0, -160));
        await tester.pump();
        expect(scrollOffset(tester), greaterThan(0), reason: '前置条件：手动滑动没有生效');
        // 紧接着点波形快进：快进必须无视刚才的手动滚动，重新居中。
        await tester.pumpWidget(
          app(const Duration(seconds: 200), style, height),
        );
        await settle(tester);
        expect(
          tallestItemOffsetFromCenter(tester),
          lessThan(4.0),
          reason: '手动滑动后快进，当前行没有重新回到视口中央',
        );
        // 手动滚动会挂一个 4s 的「抑制自动滚动」定时器，跑完它不留 pending timer。
        await tester.pump(const Duration(seconds: 5));
      });
    }
  }
}
