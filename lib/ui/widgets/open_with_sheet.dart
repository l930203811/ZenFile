import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/icon_fonts/broken_icons.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 「始终 + 外部」时可选的外部应用（原生 `getOpenWithApps` 经
/// `queryIntentActivities` 返回，第三方在前、系统应用在后）。
class ExternalOpenWithApp {
  final String packageName;
  final String label;
  final bool isSystem;

  /// 是否为本应用（列表第一项，弹窗默认勾选）。
  final bool isSelf;

  /// 应用图标（96px PNG，原生渲染；失败为空 → 回退通用图标）。
  final Uint8List? icon;

  const ExternalOpenWithApp({
    required this.packageName,
    required this.label,
    required this.isSystem,
    this.isSelf = false,
    this.icon,
  });

  static ExternalOpenWithApp? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final pkg = raw['packageName'];
    if (pkg is! String || pkg.isEmpty) return null;
    final iconRaw = raw['icon'];
    final Uint8List? icon =
        (iconRaw is Uint8List && iconRaw.isNotEmpty) ? iconRaw : null;
    return ExternalOpenWithApp(
      packageName: pkg,
      label: (raw['label'] as String?) ?? pkg,
      isSystem: raw['isSystem'] == true,
      isSelf: raw['isSelf'] == true,
      icon: icon,
    );
  }
}

/// 弹窗选择结果：本应用（[isNative]）或某个外部应用（[app]），
/// [always] 对应底部「始终」按钮（false = 「仅此一次」）。
class OpenWithAppChoice {
  final bool isNative;
  final ExternalOpenWithApp? app;
  final bool always;

  const OpenWithAppChoice({
    required this.isNative,
    this.app,
    required this.always,
  });
}

/// 统一「打开方式」弹窗（参考 ES 文件管理器样式）。
///
/// 与旧版两级弹窗（先选本应用/外部，再选应用）不同：这里一步到位——
/// 列表第一项固定为本应用并**默认勾选**，其后是可打开该文件的外部应用
/// （带真实图标）；底部「始终 / 仅此一次」决定是否按扩展名记住选择。
/// 三点菜单、长按菜单、浏览页/分类页/远程文件首次打开统一走这一个弹窗。
class OpenWithAppDialog extends StatefulWidget {
  /// 由调用方在 `showDialog` **之前**创建好，避免重建重复查询。
  final Future<List<ExternalOpenWithApp>> appsFuture;

  const OpenWithAppDialog({super.key, required this.appsFuture});

  @override
  State<OpenWithAppDialog> createState() => _OpenWithAppDialogState();
}

class _OpenWithAppDialogState extends State<OpenWithAppDialog> {
  /// 0 = 本应用（默认勾选），i>0 = apps[i-1]。
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.65,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 20),
            Text(
              L10n.of(context).open_with_title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              // ⚠️ FutureBuilder 必须直接返回可滚动列表：不能在内层再套
              // Column(min) + shrinkWrap ListView——Column 会给子级无界高度，
              // shrinkWrap 列表按完整内容撑开，应用多时溢出弹窗边框。
              child: FutureBuilder<List<ExternalOpenWithApp>>(
                future: widget.appsFuture,
                builder: (context, snap) {
                  final apps = snap.data ?? const <ExternalOpenWithApp>[];
                  // 缓存给 _submit 用（submit 只可能发生在列表已渲染后）
                  _cachedApps = apps;
                  final waiting = snap.connectionState == ConnectionState.waiting;
                  // 加载失败 / 无应用时显示占位行（按钮此时点击无效，见 _submit）
                  final showPlaceholder =
                      !waiting && apps.isEmpty;
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount:
                        apps.length + (waiting ? 1 : 0) + (showPlaceholder ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (waiting && i == 0) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          child: LinearProgressIndicator(minHeight: 2),
                        );
                      }
                      if (showPlaceholder) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                            child: Text(
                              L10n.of(context).open_with_no_apps,
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        );
                      }
                      final app = apps[waiting ? i - 1 : i];
                      final selected = (waiting ? i - 1 : i) == _selectedIndex;
                      return ListTile(
                        dense: true,
                        onTap: () => setState(() => _selectedIndex = waiting ? i - 1 : i),
                        leading: app.icon != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: Image.memory(
                                  app.icon!,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : CircleAvatar(
                                backgroundColor: theme.colorScheme.primary
                                    .withValues(alpha: 0.12),
                                child: Icon(
                                  app.isSelf ? Broken.folder : Icons.apps,
                                  size: 20,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                        title: Text(
                          app.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: selected ? FontWeight.w600 : null,
                          ),
                        ),
                        subtitle: app.isSelf
                            ? null
                            : Text(
                                app.packageName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                        trailing: _RadioDot(selected: selected, theme: theme),
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Row(children: [
              Expanded(
                child: TextButton(
                  onPressed: () => _submit(context, always: true),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: const RoundedRectangleBorder(),
                  ),
                  child: Text(
                    L10n.of(context).open_always,
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Container(width: 1, height: 24, color: theme.dividerColor),
              Expanded(
                child: TextButton(
                  onPressed: () => _submit(context, always: false),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: const RoundedRectangleBorder(),
                  ),
                  child: Text(
                    L10n.of(context).msgdb75b769,
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  void _submit(BuildContext context, {required bool always}) {
    final apps = _cachedApps;
    // 列表尚未加载完成（或加载失败为空）时不响应，避免越界
    if (apps == null || apps.isEmpty) return;
    final app = apps[_selectedIndex.clamp(0, apps.length - 1)];
    Navigator.pop(
      context,
      OpenWithAppChoice(
        isNative: app.isSelf,
        app: app.isSelf ? null : app,
        always: always,
      ),
    );
  }

  /// FutureBuilder 里缓存的应用列表（见 build 中的赋值说明）。
  List<ExternalOpenWithApp>? _cachedApps;
}

/// 单选圆点：选中 = 主题色实心 + 白色对勾；未选中 = 描边空心。
class _RadioDot extends StatelessWidget {
  final bool selected;
  final ThemeData theme;

  const _RadioDot({required this.selected, required this.theme});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? theme.colorScheme.primary : Colors.transparent,
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface.withValues(alpha: 0.35),
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, size: 14, color: Colors.white)
          : null,
    );
  }
}
