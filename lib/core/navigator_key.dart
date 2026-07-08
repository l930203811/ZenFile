import 'package:flutter/material.dart';

/// 全局 NavigatorState key，用于跨 widget 生命周期访问根 Navigator。
///
/// 某些场景下（如选择模式退出导致 SelectionActionBar unmount），
/// 传入的 widget context 可能失效。此时用此 key 的 currentContext
/// 作为兜底来显示弹窗或执行导航，避免依赖已 unmount 的 context。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
