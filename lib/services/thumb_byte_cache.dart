import 'dart:collection';
import 'dart:typed_data';

/// 缩略图**字节**（原生侧已压好的 JPEG/PNG）的内存缓存，**条目数与总字节双上限**。
///
/// ## 为什么需要这个类（issue #58 的直接由来）
/// 分类页视频格子的缩略图原本用 `static final Map<String, Uint8List>` 做缓存，
/// **只进不出**：用户滑过的每一个视频都会把一份缩略图字节永久留在内存里，几千个
/// 视频就是几百 MB。issue #52 / #53 / #58 三份 ANR 报告的共同特征是
/// `RssHwmKb ≈ 1.2 GB`、主线程阻塞在 Dart 代码里 —— 内存高压下的 GC 风暴正是
/// 「主 isolate 长时间不处理输入事件」的典型成因。
///
/// 这里改成 LRU（命中即移到队尾、超限淘汰最旧），并且**允许在系统低内存时整体
/// 清空**（见 `MemoryPressureRelief`），保证内存占用有明确天花板。
///
/// 注意：清空只影响内存，磁盘/原生侧的缩略图缓存不受影响 —— 被淘汰的条目下次
/// 重新生成即可，代价是一次原生调用，可接受。
class ThumbByteCache {
  ThumbByteCache._();

  /// 最多保留多少张缩略图。
  static const int maxEntries = 120;

  /// 最多占用多少字节（12 MB）。120 张 × 平均 ~100 KB 大致与之相当，
  /// 实际以先到者为准。
  static const int maxBytes = 12 * 1024 * 1024;

  /// 插入序 = LRU 序（命中/写入即移到末尾，队首即最久未用）。
  static final LinkedHashMap<String, Uint8List> _map = LinkedHashMap();
  static int _bytes = 0;

  static int get byteSize => _bytes;
  static int get length => _map.length;

  static Uint8List? get(String key) {
    if (!_map.containsKey(key)) return null;
    final value = _map.remove(key);
    if (value == null) return null;
    _map[key] = value; // 命中即刷新为「最近使用」
    return value;
  }

  static bool containsKey(String key) => _map.containsKey(key);

  static void put(String key, Uint8List value) {
    if (value.isEmpty) return;
    if (_map.containsKey(key)) {
      _bytes -= _map.remove(key)?.length ?? 0;
    }
    _map[key] = value;
    _bytes += value.length;
    _evict();
  }

  static void remove(String key) {
    final old = _map.remove(key);
    if (old != null) _bytes -= old.length;
  }

  /// 整体清空（系统低内存 / 检测到 UI 卡顿时的自愈动作）。
  static void clearAll() {
    _map.clear();
    _bytes = 0;
  }

  static void _evict() {
    while (_map.length > maxEntries || _bytes > maxBytes) {
      if (_map.isEmpty) break;
      final oldestKey = _map.keys.first;
      final oldest = _map.remove(oldestKey);
      _bytes -= oldest?.length ?? 0;
    }
  }
}
