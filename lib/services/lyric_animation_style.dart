/// 歌词动画风格（借鉴 folia-major 的多风格歌词动画体系，纯 Flutter 重写实现）。
///
/// 每种风格对应 folia 的一套歌词观感：
/// - [classic]    Monet 经典：逐字扫过 + 距离衰减 + 弹簧滚动
/// - [glow]       Pendolo：扫过 + 霓虹辉光 + 词级着色
/// - [immersive]  Lattice：巨字自适应 + 电影感辉光 + 疏行距
/// - [pv]         Lumiere 文字 PV：单行巨字 + 呼吸晃动 + 四芒闪点，
///                切行时贝塞尔飞入 + 粒子径迹 + 崩解散聚
/// - [echo]       Lumiere 歌词回声：扫过 + 唱词炸出空心字碎片漂移背景
/// - [mixed]      混合模式：一个独立风格，但自身没有单一形态——**每句歌词
///                随机呈现池中的一种内置风格**（见 [kLyricMixedStylePool]），
///                一句一时一面，逐句之间自然变化（默认风格）
///
/// 风格持久化在 PreferencesService（只存 name 字符串，避免循环依赖）。
library;

import 'dart:math' as math;

enum LyricAnimationStyle {
  classic,
  glow,
  immersive,
  pv,
  echo,

  /// 混合模式：自身即一种独立风格，观感上是「每句随机一种内置风格」。
  mixed;

  /// 由持久化字符串还原；未知值（含旧版本残留）与从未设置过的用户
  /// 均回落 [mixed]（默认风格）。
  static LyricAnimationStyle fromName(String? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return mixed;
  }
}

/// 混合模式的逐句风格池：不含 [LyricAnimationStyle.mixed] 自身，避免自引用。
const List<LyricAnimationStyle> kLyricMixedStylePool = [
  LyricAnimationStyle.classic,
  LyricAnimationStyle.glow,
  LyricAnimationStyle.immersive,
  LyricAnimationStyle.pv,
  LyricAnimationStyle.echo,
];

/// 生成混合模式的**逐句风格计划**：第 i 句歌词对应返回值中第 i 个风格，
/// 整首歌（同一份歌词、同一份计划）内固定不变。
///
/// ⚠️ 必须一次性排定、之后只读，禁止在换行/逐帧时重掷：
/// 每次重掷都会改变该句的字号与行高 ⇒ 测量签名失效 ⇒ 整个列表重新排版，
/// 行高变化又会把滚动目标顶走，表现为「播完一句重载到首行 + 过渡卡顿」。
/// 排定后同句风格恒定，观感仍是「每句随机一种」，但零重排开销。
List<LyricAnimationStyle> buildMixedStylePlan(int count, math.Random rng) {
  final pool = kLyricMixedStylePool;
  if (count <= 0) return const [];
  final plan = List<LyricAnimationStyle>.filled(count, pool.first);
  var prev = -1;
  for (var i = 0; i < count; i++) {
    var k = rng.nextInt(pool.length);
    // 相邻两句同风格会削弱「随机」观感：撞上就地顺延一格。
    if (k == prev && pool.length > 1) k = (k + 1) % pool.length;
    plan[i] = pool[k];
    prev = k;
  }
  return plan;
}
