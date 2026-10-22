/// 歌词动画风格（借鉴 folia-major 的多风格歌词动画体系，纯 Flutter 重写实现）。
///
/// 每种风格对应一套独立观感：
/// - [classic]     Monet 经典：逐字扫过 + 当前字弹放 + 距离衰减 + 弹簧滚动
/// - [typewriter]  打字机：逐字敲出，当前字右侧带闪烁光标，无辉光、不放大，
///                 与「经典扫过」（缩放强调）运动形态完全不同
/// - [meteor]      流星坠落：整句先一起亮起，唱过的字脱离格位缓慢旋转着飘向
///                 屏幕底部，并随机堆叠在底部（飘落层铺满整个歌词视口）
/// - [pv]          Lumiere 文字 PV：单行巨字 + 呼吸晃动 + 四芒闪点，
///                 切行时贝塞尔飞入 + 粒子径迹 + 崩解散聚
/// - [echo]        Lumiere 歌词回声：扫过 + 唱词炸出空心字碎片漂移背景
/// - [drop]        重力坠落：唱到的字从高处砸落到位，落地溅起光环与碎屑
/// - [burst]       左右弹射：字从左/右交替高速弹入，带拖影与过冲回弹
/// - [cube]        立体旋入：字块绕竖轴旋入（带厚度与投影），唱字持续自转
/// - [punch]       冲击爆字：唱到的字从两倍大猛缩到位，炸开冲击波环
/// - [wave]        水波倒影：逐字上下起伏，行下方有镜像倒影随波淡出
///
/// 后六种（meteor / drop~wave）都由 `lyrics_view_widget.dart` 的
/// `_MotionLinePainter` **逐字重绘**，与「文字 PV / 回声碎片」同一套做法；
/// 只给整行套一层 Transform 时它们彼此看不出差别（这是它们被重做的原因）。
/// - [mixed]       混合模式：一个独立风格，但自身没有单一形态——**每句歌词
///                 只呈现当前句（文字 PV 舞台），并随机获得池中一种完整风格**
///                 （见 [kLyricMixedStylePool]），一句一时一面
///
/// 风格持久化在 PreferencesService（只存 name 字符串，避免循环依赖）。
library;

import 'dart:math' as math;

enum LyricAnimationStyle {
  classic,
  typewriter,

  /// 流星坠落：整句先一起亮起，唱过的字脱离格位，缓慢旋转 + 左右摆动着飘到
  /// 屏幕底部并随机堆叠（行内只留余痕，飘落与堆叠由铺满视口的飘落层完成）。
  meteor,

  pv,
  echo,

  /// 重力坠落：唱到的字从上方砸落，落地光环 + 碎屑（见 [_MotionLinePainter]）。
  drop,

  /// 左右弹射：奇偶字分别从左 / 右高速弹出，拖影 + 过冲回弹。
  burst,

  /// 立体旋入：字块带厚度与投影绕竖轴旋入，唱字持续自转（3D 字块）。
  cube,

  /// 冲击爆字：唱到的字从 2.4 倍猛缩到位并炸开冲击波环，未唱字退到远景。
  punch,

  /// 波纹漂浮：逐字漂浮 + 镜像倒影。
  wave,

  /// 混合模式：自身即一种独立风格，观感上是「单句舞台 + 每句随机一种风格」。
  mixed;

  /// 由持久化字符串还原；未知值（含旧版本残留）与从未设置过的用户
  /// 均回落 [mixed]（默认风格）。
  ///
  /// 历史 name 做平滑映射，避免老用户设置丢失：
  /// - `glow`  → [typewriter]（旧「辉光扫过」已被打字机取代）
  /// - `immersive` → [meteor]（旧「沉浸巨幕」已整体替换为流星坠落）
  /// - `fade`  → [drop]
  /// - `slide` → [burst]
  /// - `rotate`→ [cube]
  /// - `zoom`  → [punch]
  /// 这些旧风格已整体重做（观感与旧版完全不同），保留 name 只为不跳回默认。
  static LyricAnimationStyle fromName(String? name) {
    switch (name) {
      case 'glow':
        return typewriter;
      case 'immersive':
        return meteor;
      case 'fade':
        return drop;
      case 'slide':
        return burst;
      case 'rotate':
        return cube;
      case 'zoom':
        return punch;
    }
    for (final s in values) {
      if (s.name == name) return s;
    }
    return mixed;
  }
}

/// 混合模式的逐句风格池：不含 [LyricAnimationStyle.mixed] 自身，避免自引用。
///
/// 一首歌的句数通常大于池长，所以同一首歌里风格必然会重复几次——这是刻意的：
/// 池太长会让相邻两句观感雷同、失去「每句一面」的辨识度。
const List<LyricAnimationStyle> kLyricMixedStylePool = [
  LyricAnimationStyle.classic,
  LyricAnimationStyle.typewriter,
  LyricAnimationStyle.meteor,
  LyricAnimationStyle.pv,
  LyricAnimationStyle.echo,
  LyricAnimationStyle.drop,
  LyricAnimationStyle.burst,
  LyricAnimationStyle.cube,
  LyricAnimationStyle.punch,
  LyricAnimationStyle.wave,
];

/// 生成混合模式的**逐句风格计划**：第 i 句歌词对应返回值中第 i 个风格，
/// 整首歌（同一份歌词、同一份计划）内固定不变。
///
/// 排法是**洗牌轮转**而不是独立随机抽取：每轮把整个风格池打乱依次发牌，
/// 发完再洗一轮 ⇒ 任意连续 [kLyricMixedStylePool.length] 句里，**每种风格各
/// 出现一次**（用户的诉求是「每句都不同」；单纯随机抽取会在短歌里漏掉大
/// 半风格、在长歌里把同一种连着抽出来）。超过一轮后才开始重复。
///
/// ⚠️ 必须一次性排定、之后只读，禁止在换行/逐帧时重掷：
/// 每次重掷都会改变该句的字号与行高 ⇒ 测量签名失效 ⇒ 整个列表重新排版，
/// 行高变化又会把滚动目标顶走，表现为「播完一句重载到首行 + 过渡卡顿」。
/// 排定后同句风格恒定，观感仍是「每句随机一种」，但零重排开销。
List<LyricAnimationStyle> buildMixedStylePlan(int count, math.Random rng) {
  final pool = kLyricMixedStylePool;
  if (count <= 0) return const [];
  final plan = <LyricAnimationStyle>[];
  LyricAnimationStyle? prev;
  while (plan.length < count) {
    final bag = List<LyricAnimationStyle>.of(pool)..shuffle(rng);
    // 新一轮的头不要和上一轮的尾相同，否则接缝处看起来「没换」。
    if (prev != null && bag.first == prev && bag.length > 1) {
      final first = bag[0];
      bag[0] = bag[1];
      bag[1] = first;
    }
    for (final style in bag) {
      if (plan.length >= count) break;
      plan.add(style);
      prev = style;
    }
  }
  return plan;
}
