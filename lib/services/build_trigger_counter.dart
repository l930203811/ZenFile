/// 重建触发源计数（诊断用，2026-11-27 新增）。
///
/// ## 为什么需要它
///
/// 真机日志能告诉我们「某一帧 build 了 50ms」，却**说不清是谁触发的这次重建**。
/// 而这恰恰是剩下的核心疑问：
///
/// * 掉帧日志显示新版本里仍有 41~106ms 的 build 段（与旧版本同量级），
///   说明它**不是**来自首页那次全量重建（那个已经修掉了），
///   而是来自浏览页自己的重建。
/// * 但「浏览页重建」又分两种完全不同的成因：
///   (A) provider 的一次无关紧要的 `notifyListeners()` 把整页重跑了一遍；
///   (B) 没有 provider 通知，纯粹是滚动/动画引起的 build + layout + paint。
///   (A) 要收窄订阅范围；(B) 要降绘制成本。**两者的修法完全相反。**
///
/// 所以这里放几个极轻量的计数器（整数自增，纳秒级开销），
/// 由各处在「触发点」自增，探针在打印掉帧日志时一并输出**增量**。
///
/// ## 约束
///
/// * 必须是**独立文件**：探针在 `services/`，provider 在 `providers/`，
///   若探针直接 import provider 会形成 services → providers → services 的循环依赖。
/// * 只计数，不改变任何行为；正式版也保留（开销可忽略），
///   与 [WebdavDebugLog.logAlways] 的取证策略一致。
library;

class BuildTriggerCounter {
  BuildTriggerCounter._();

  /// [FileManagerProvider.notifyListeners] 的调用次数。
  ///
  /// 该 provider 有 185 处 `notifyListeners()`，而浏览页整页被它包在
  /// `Consumer` 里 ⇒ 每一次通知都会重跑整个浏览页的 build。
  static int fileManagerNotifications = 0;

  /// [MediaProvider.notifyListeners] 的调用次数。
  static int mediaNotifications = 0;

  /// 浏览页（`DirectoryScreen.build`）实际被构建的次数。
  static int browsePageBuilds = 0;

  /// 首页（`HomeScreen.build`）实际被构建的次数。
  static int homePageBuilds = 0;

  /// 分类网格（`QuickCategoriesGrid.build`）实际被构建的次数。
  static int categoryGridBuilds = 0;

  /// 页面导航事件（push / pop）发生的次数。
  ///
  /// ## 为什么必须单独计数（2026-11-28 第十一轮）
  ///
  /// 探针原来用「浏览/首页/网格 三个页面有没有重建」来判断「这次点击有没有
  /// 产生业务响应」。但**打开一个新页面**既不重建这三个页面、也不通知任何
  /// provider ⇒ 一次「成功打开了视频页」的点击会被判成「400ms 内无响应」。
  ///
  /// 真机日志里 6 次分类卡片点击全部是这种误判：回调明明执行了（`分类卡片
  /// onTap 视频` 有日志），却被记成「无响应」，把排查方向带偏了一整轮。
  ///
  /// ⇒ 导航必须单独计数，「有响应」才成立。
  static int navigationEvents = 0;

  /// 取当前快照（探针用来算增量）。
  static List<int> snapshot() => <int>[
        fileManagerNotifications,
        mediaNotifications,
        browsePageBuilds,
        homePageBuilds,
        categoryGridBuilds,
        navigationEvents,
      ];
}
