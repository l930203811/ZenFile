import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class OpenWithSheet extends StatefulWidget {
  final String fileName;
  final String fileExtension;

  const OpenWithSheet({
    super.key,
    required this.fileName,
    required this.fileExtension,
  });

  @override
  State<OpenWithSheet> createState() => _OpenWithSheetState();
}

class _OpenWithSheetState extends State<OpenWithSheet> {
  String _selectedType = 'native';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                L10n.of(context).msg2a4cfb07,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: () {
                  if (_selectedType == 'native') {
                    Navigator.pop(context, 'just_once_native');
                  } else {
                    setState(() => _selectedType = 'native');
                  }
                },
                onDoubleTap: () {
                  Navigator.pop(context, 'just_once_native');
                },
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _selectedType == 'native'
                        ? theme.colorScheme.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _selectedType == 'native'
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline.withValues(alpha: 0.2),
                      width: _selectedType == 'native' ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Broken.eye,
                          color: theme.colorScheme.primary,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L10n.of(context).built_in_zenfile_viewer,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _selectedType == 'native'
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              L10n.of(context).zenfile6,
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_selectedType == 'native')
                        Icon(Icons.check_circle, color: theme.colorScheme.primary)
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: () {
                  if (_selectedType == 'external') {
                    Navigator.pop(context, 'just_once_external');
                  } else {
                    setState(() => _selectedType = 'external');
                  }
                },
                onDoubleTap: () {
                  Navigator.pop(context, 'just_once_external');
                },
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _selectedType == 'external'
                        ? theme.colorScheme.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _selectedType == 'external'
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline.withValues(alpha: 0.2),
                      width: _selectedType == 'external' ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Broken.export_1,
                          color: theme.colorScheme.primary,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              L10n.of(context).msg42be43e6,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _selectedType == 'external'
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              L10n.of(context).msgd1fca831,
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_selectedType == 'external')
                        Icon(Icons.check_circle, color: theme.colorScheme.primary)
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(context, 'just_once_$_selectedType');
                      },
                      child: Text(L10n.of(context).msgdb75b769),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pop(context, 'always_$_selectedType');
                      },
                      child: Text(L10n.of(context).open_always),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「始终 + 外部」时可选的外部应用（原生 `getOpenWithApps` 经
/// `queryIntentActivities` 返回，第三方在前、系统应用在后）。
class ExternalOpenWithApp {
  final String packageName;
  final String label;
  final bool isSystem;

  const ExternalOpenWithApp({
    required this.packageName,
    required this.label,
    required this.isSystem,
  });

  static ExternalOpenWithApp? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final pkg = raw['packageName'];
    if (pkg is! String || pkg.isEmpty) return null;
    return ExternalOpenWithApp(
      packageName: pkg,
      label: (raw['label'] as String?) ?? pkg,
      isSystem: raw['isSystem'] == true,
    );
  }
}

/// 外部应用选择列表。
///
/// 为什么由本应用自己列应用（而不是把「始终」交给系统解析器记默认）：
/// 裸 `ACTION_VIEW` 在系统里视频/音频/图片普遍**预置了默认应用**，会被系统
/// 自带播放器/相册直接接管，用户根本没机会选第三方应用。列表选中后由
/// `FileManagerProvider` 按扩展名记 `external:<包名>`，之后按包名直开。
class ExternalAppPickerSheet extends StatelessWidget {
  /// 由调用方在 `showModalBottomSheet` **之前**创建好，避免重建重复查询。
  final Future<List<ExternalOpenWithApp>> appsFuture;

  const ExternalAppPickerSheet({super.key, required this.appsFuture});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.65,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  L10n.of(context).open_with_title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: FutureBuilder<List<ExternalOpenWithApp>>(
                future: appsFuture,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(40),
                      child: CircularProgressIndicator(),
                    );
                  }
                  final apps = snap.data ?? const <ExternalOpenWithApp>[];
                  if (apps.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(40),
                      child: Text(
                        L10n.of(context).open_with_no_apps,
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 20),
                    itemCount: apps.length,
                    itemBuilder: (context, i) {
                      final app = apps[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              theme.colorScheme.primary.withValues(alpha: 0.1),
                          child: Icon(
                            Icons.apps,
                            size: 20,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        title: Text(
                          app.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          app.packageName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color:
                                theme.colorScheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                        onTap: () => Navigator.pop(context, app),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
