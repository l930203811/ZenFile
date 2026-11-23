import 'package:package_info_plus/package_info_plus.dart';

String? _cachedVersion;

/// 读取 pubspec.yaml 里声明的版本号，供 UI 各处显示。
///
/// 统一走这里，避免像以前那样在抽屉页 / 关于页硬编码版本号，
/// 发版 bump 版本时漏改导致显示旧版本。带进程内缓存，重复调用不再走平台通道。
/// 读取失败时返回空串，调用方自行兜底（不要退回写死的旧版本号）。
Future<String> getAppVersion() async {
  final cached = _cachedVersion;
  if (cached != null) return cached;
  try {
    final info = await PackageInfo.fromPlatform();
    _cachedVersion = info.version;
    return info.version;
  } catch (_) {
    return '';
  }
}
