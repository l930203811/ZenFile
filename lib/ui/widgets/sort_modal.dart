import 'package:flutter/material.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../providers/file_manager_provider.dart';

class SortModal {
  static void show(BuildContext context, FileManagerProvider provider) {
    final theme = Theme.of(context);
    bool isAppearanceExpanded = false;
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateModal) {
            return SafeArea(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(L10n.of(context).msg97301f64, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                          IconButton(icon: const Icon(Broken.close_circle), onPressed: () => Navigator.pop(context)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(L10n.of(context).ui_layout_mode, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: () {
                                provider.setGridView(false);
                                setStateModal(() {});
                              },
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: !provider.isGridView ? theme.colorScheme.primary : theme.colorScheme.surfaceVariant,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Broken.row_vertical, color: !provider.isGridView ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface),
                                    const SizedBox(width: 8),
                                    Text(L10n.of(context).msg829cb1dd, style: TextStyle(fontWeight: FontWeight.bold, color: !provider.isGridView ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: InkWell(
                              onTap: () {
                                provider.setGridView(true);
                                setStateModal(() {});
                              },
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: provider.isGridView ? theme.colorScheme.primary : theme.colorScheme.surfaceVariant,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Broken.element_3, color: provider.isGridView ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface),
                                    const SizedBox(width: 8),
                                    Text(L10n.of(context).ui_grid_view, style: TextStyle(fontWeight: FontWeight.bold, color: provider.isGridView ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Theme(
                        data: theme.copyWith(dividerColor: Colors.transparent),
                        child: Container(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceVariant.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: theme.dividerColor.withOpacity(0.1)),
                          ),
                          child: ExpansionTile(
                            initiallyExpanded: isAppearanceExpanded,
                            onExpansionChanged: (exp) {
                              isAppearanceExpanded = exp;
                            },
                            leading: Icon(Broken.setting_2, color: theme.colorScheme.primary),
                            title: Text(L10n.of(context).msg0a4ebb8d, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                            childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(L10n.of(context).msg88062f93, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                                  Text('${(provider.iconScale * 100).round()}%', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                                ],
                              ),
                              Slider(
                                value: provider.iconScale,
                                min: 0.7,
                                max: 1.5,
                                divisions: 8,
                                activeColor: theme.colorScheme.primary,
                                onChanged: (val) {
                                  provider.setIconScale(val);
                                  setStateModal(() {});
                                },
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(L10n.of(context).msga7c781f5, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                                  Text('${(provider.itemPaddingMultiplier * 100).round()}%', style: TextStyle(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                                ],
                              ),
                              Slider(
                                value: provider.itemPaddingMultiplier,
                                min: 0.4,
                                max: 2.0,
                                divisions: 16,
                                activeColor: theme.colorScheme.primary,
                                onChanged: (val) {
                                  provider.setItemPaddingMultiplier(val);
                                  setStateModal(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(L10n.of(context).msga2946a1a, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildSortChip(context, provider, setStateModal, L10n.of(context).ui_name_asc, FileSortType.nameAsc),
                          _buildSortChip(context, provider, setStateModal, L10n.of(context).za, FileSortType.nameDesc),
                          _buildSortChip(context, provider, setStateModal, L10n.of(context).ui_newest, FileSortType.dateNewest),
                          _buildSortChip(context, provider, setStateModal, L10n.of(context).ui_oldest, FileSortType.dateOldest),
                          _buildSortChip(context, provider, setStateModal, L10n.of(context).msg2e2a26bb, FileSortType.sizeLargest),
                          _buildSortChip(context, provider, setStateModal, L10n.of(context).ui_size_small, FileSortType.sizeSmallest),
                          _buildSortChip(context, provider, setStateModal, L10n.of(context).ui_type, FileSortType.type),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: provider.isFolderOverrideEnabled(provider.currentPath)
                              ? theme.colorScheme.primary.withOpacity(0.08)
                              : theme.colorScheme.surfaceVariant.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: provider.isFolderOverrideEnabled(provider.currentPath)
                                ? theme.colorScheme.primary.withOpacity(0.25)
                                : theme.dividerColor.withOpacity(0.08),
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Broken.folder_favorite,
                              color: provider.isFolderOverrideEnabled(provider.currentPath)
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface.withOpacity(0.65),
                              size: 24,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    L10n.of(context).msgf437ace4,
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    L10n.of(context).msg4dfc167a,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurface.withOpacity(0.55),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: provider.isFolderOverrideEnabled(provider.currentPath),
                              activeColor: theme.colorScheme.primary,
                              onChanged: (val) {
                                provider.setFolderOverrideEnabled(provider.currentPath, val);
                                setStateModal(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  static Widget _buildSortChip(
    BuildContext context,
    FileManagerProvider provider,
    void Function(void Function()) setStateModal,
    String label,
    FileSortType type,
  ) {
    final theme = Theme.of(context);
    final isSelected = provider.sortType == type;
    return InkWell(
      onTap: () {
        provider.setSortType(type);
        setStateModal(() {});
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.primary : theme.colorScheme.surfaceVariant.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary.withOpacity(0.25) : theme.dividerColor.withOpacity(0.08),
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: isSelected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface.withOpacity(0.8),
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}