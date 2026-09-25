import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// 「清空 ZenFile 缓存目录」的**唯一实现**。
///
/// ## 为什么要有这个类
/// 这段逻辑此前**有两份逐行重复的拷贝**（`main.dart` 的自动清理定时器、设置页的
/// 「清除缓存」按钮），两份都写着「清空 `/storage/emulated/0/ZenFile` 下除
/// `Backups` 外的所有内容」。本项目已经反复栽在「改一处 ≠ 改完」上，而这里是
/// **唯一会把用户现场删光**的地方 —— 一处漏改就等于丢诊断数据。
///
/// ## 2026-09-25 的真实事故（本类存在的直接原因）
/// 用户按预期复现了崩溃，但：
///  * `ZenFile/crash/` 里**看不到任何报告**，`webdav_debug.log` 也没了；
///  * 应用**每次启动**都提示「检测到上次异常退出，诊断报告已保存到 ZenFile/crash」，
///    哪怕本次启动毫无异常。
///
/// 根因就是本类的旧实现：自动清理（间隔 > 0 时**每次启动立即执行一次**）把
/// `ZenFile/` 整棵子树除了 `Backups` 全删 —— 包括 `crash/` 与 `webdav_debug.log`。
/// 于是：
///  1. 崩溃报告（私有存档里的 `exit_*.txt`）在下次启动被导出进 `crash/` → 提示；
///  2. 同一次会话里自动清理又把 `crash/` 删掉；
///  3. 再下次启动，同一份报告**又被当成新增**导出 → 再提示……**无休止**。
/// 而「报告只存在于私有目录、公共目录总是空的」正好解释了用户说的「没生成日志」。
///
/// 所以这里把保留清单显式写死，并且**诊断数据与用户数据一律不进清理范围**。
class CacheCleanService {
  CacheCleanService._();

  /// ZenFile 根目录：应用所有缓存 / 临时数据的统一存放点。
  static const String basePath = '/storage/emulated/0/ZenFile';

  /// 清理时**永不删除**的条目（按名字匹配 [basePath] 的**直接子项**）。
  ///
  /// ⚠️ 往这里加东西请三思：清单里每少一项，一次「清理缓存」就会把它永久删掉。
  static const Set<String> preservedNames = {
    'Backups', // 用户备份：设置 / 应用 / 保险箱导出
    'crash', // 崩溃取证报告 —— 唯一的崩溃现场，删了就再也拿不回来
    'Receive', // 「快传」接收到的文件：用户数据，不是缓存
    'webdav_debug.log', // 无 adb 环境下的诊断日志（可能正在写）
  };

  /// 清理后需要重建的运行目录（缺了会让调用方异常）。
  static const List<String> runtimeDirs = ['cache', '.remote_cache', '.nomedia'];

  /// 该条目是否必须保留。
  static bool shouldPreserve(String name) => preservedNames.contains(name);

  /// 异步清理（在独立 isolate 中执行，避免阻塞 UI）。
  ///
  /// [basePathOverride] 是**测试注入点**：真机路径在宿主上必然不存在，不注入就
  /// 等于没测到清理逻辑本身。
  static Future<int> wipe({String? basePathOverride}) {
    final path = basePathOverride ?? basePath;
    // 只捕获一个 String（可跨 isolate 传递）；不要在闭包里捕获 Directory，
    // 那会因无法序列化而让清理静默失败（历史上真发生过）。
    return Isolate.run(() => wipeSync(path));
  }

  /// 同步清理 [base]：删除除 [preservedNames] 外的所有条目，并重建 [runtimeDirs]。
  ///
  /// 返回删除的条目数。**任何异常都不外抛** —— 清理失败只该是「没清干净」，
  /// 不该变成新的崩溃源。目录不存在时直接返回 0（不创建）。
  static int wipeSync(String base) {
    final baseDir = Directory(base);
    if (!baseDir.existsSync()) return 0;

    var deleted = 0;

    void wipeDirectory(Directory dir) {
      try {
        for (final entity in dir.listSync()) {
          // 只对**顶层**子项套保留清单；被保留目录内部的旧文件仍按各自的
          // 生命周期管理（如 crash/ 由原生侧按份数裁剪）。
          if (dir.path == baseDir.path && shouldPreserve(p.basename(entity.path))) {
            continue;
          }
          if (entity is File) {
            try {
              entity.deleteSync();
              deleted++;
            } catch (_) {}
          } else if (entity is Directory) {
            wipeDirectory(entity);
            try {
              entity.deleteSync();
              deleted++;
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    wipeDirectory(baseDir);

    // 清理后重建必要的运行目录，避免调用方因目录缺失而异常。
    for (final sub in runtimeDirs) {
      try {
        Directory(p.join(base, sub)).createSync(recursive: true);
      } catch (_) {}
    }
    // 重建 .nomedia 标记文件，确保清理后远程缩略图缓存仍不被媒体库索引。
    try {
      final marker = File(p.join(base, '.nomedia', '.nomedia'));
      if (!marker.existsSync()) marker.createSync();
    } catch (_) {}

    return deleted;
  }
}
