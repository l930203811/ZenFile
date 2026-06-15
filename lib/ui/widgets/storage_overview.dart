import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/file_manager_provider.dart';
import '../../core/utils.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class StorageOverviewCard extends StatelessWidget {
  const StorageOverviewCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<FileManagerProvider>();

    final double totalBytes = provider.totalStorageBytes > 0 
        ? provider.totalStorageBytes.toDouble() 
        : 128 * 1024 * 1024 * 1024.0;
    
    final double usedBytes = provider.usedStorageBytes > 0 
        ? provider.usedStorageBytes.toDouble() 
        : 82.4 * 1024 * 1024 * 1024.0;
        
    final double usedPercentage = provider.totalStorageBytes > 0 
        ? provider.storageUsedPercentage 
        : 0.65;

    final String totalStorageStr = FileUtils.formatBytes(totalBytes.toInt(), 1);
    final String usedStorageStr = FileUtils.formatBytes(usedBytes.toInt(), 1);
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
              const Text(
                'L10n.of(context).msg21cefa9b',
                style: TextStyle(
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
                  '已使用 $usedPercentInt%',
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
                '已使用 $usedStorageStr',
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
