import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/utils.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 单个存储卷信息卡片（可横向滚动，用于主存/双开存储并列布局）。
class StorageVolumeCard extends StatelessWidget {
  final StorageVolume volume;
  final VoidCallback? onTap;

  const StorageVolumeCard({
    super.key,
    required this.volume,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = volume.totalBytes > 0 ? volume.totalBytes : 0;
    final used = volume.usedBytes >= 0 ? volume.usedBytes : 0;
    final double usedPct = total > 0 ? used / total : 0;
    final int usedPctInt = (usedPct * 100).toInt();

    final totalStr = FileUtils.formatBytes(total.toInt(), 1);
    final usedStr = FileUtils.formatBytes(used.toInt(), 1);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          width: 260,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primary,
                theme.colorScheme.tertiary,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withOpacity(0.25),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        const Icon(Icons.sd_storage_rounded, color: Colors.white, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            volume.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints: const BoxConstraints(minWidth: 52),
                    alignment: Alignment.center,
                    child: Text(
                      '$usedPctInt%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: usedPct,
                  backgroundColor: Colors.white.withOpacity(0.3),
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  minHeight: 7,
                ),
              ),
              const SizedBox(height: 10),
              // 参考图片样式：下方显示「已用 / 总量」主文案，如 118 GB / 128 GB
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      '$usedStr / $totalStr',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    volume.isInternal ? '内' : '外',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
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

/// 水平滚动的存储卷卡片列表：用于分类页顶部，
/// 按参考图片并排展示「主存 / 双开存储」等多个存储卷。
class StorageVolumesOverview extends StatelessWidget {
  final void Function(int index)? onNavigateTab;

  const StorageVolumesOverview({super.key, this.onNavigateTab});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<FileManagerProvider>();
    final volumes = provider.storageVolumes;
    if (volumes.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 0, 8),
      child: SizedBox(
        height: 152,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: volumes.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final v = volumes[index];
            return StorageVolumeCard(
              volume: v,
              onTap: () {
                provider.loadDirectory(v.path);
                // Home tab = 0, FileManager tab = 1
                onNavigateTab?.call(1);
              },
            );
          },
        ),
      ),
    );
  }
}

/// 兼容旧调用：全屏宽的单张存储概览卡片（汇总所有卷）。
/// 目前分类页改用 [StorageVolumesOverview] 显示多卷并列卡片；
/// 保留此组件以兼容其他页面（设置、抽屉等）的旧调用。
class StorageOverviewCard extends StatelessWidget {
  const StorageOverviewCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<FileManagerProvider>();

    final double totalBytes = provider.totalStorageBytes > 0
        ? provider.totalStorageBytes.toDouble()
        : 128 * 1024 * 1024 * 1024.0;

    final double usedPercentage = provider.totalStorageBytes > 0
        ? provider.storageUsedPercentage
        : 0.65;

    final String totalStorageStr = FileUtils.formatBytes(totalBytes.toInt(), 1);
    final usedBytes = (totalBytes * usedPercentage).toInt();
    final String usedStorageStr = FileUtils.formatBytes(usedBytes, 1);
    final int usedPercentInt = (usedPercentage * 100).toInt();

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary,
            theme.colorScheme.tertiary,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withOpacity(0.3),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                L10n.of(context).msg21cefa9b,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '已用 $usedPercentInt%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: usedPercentage,
              backgroundColor: Colors.white.withOpacity(0.3),
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '已用 $usedStorageStr',
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '总计 $totalStorageStr',
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
