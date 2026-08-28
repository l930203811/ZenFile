import 'package:flutter/material.dart';
import '../../services/recycle_bin_service.dart';
import '../../core/utils.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../widgets/archive_type_icon.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key});

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  List<RecycleBinItem> _allItems = [];
  List<RecycleBinItem> _filteredItems = [];
  final Set<String> _selectedIds = {};
  bool _isSelectionMode = false;
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  void _loadItems() {
    setState(() {
      _allItems = RecycleBinService.getTrashItems();
      _filterItems();
    });
  }

  void _filterItems() {
    if (_searchQuery.trim().isEmpty) {
      _filteredItems = List.from(_allItems);
    } else {
      _filteredItems = _allItems
          .where((item) =>
              item.name.toLowerCase().contains(_searchQuery.toLowerCase()))
          .toList();
    }
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }

      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
      } else {
        _isSelectionMode = true;
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selectedIds.clear();
      _isSelectionMode = false;
    });
  }

  Future<void> _restoreSelected() async {
    final itemsToRestore = _allItems.where((item) => _selectedIds.contains(item.id)).toList();
    if (itemsToRestore.isEmpty) return;

    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      for (final item in itemsToRestore) {
        await RecycleBinService.restoreItem(item);
      }
      if (mounted) Navigator.pop(context); // Dismiss loading
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).ui_recycle_restore_success(itemsToRestore.length)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (mounted) Navigator.pop(context); // Dismiss loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).ui_recycle_restore_failed(e.toString())),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    _clearSelection();
    _loadItems();
  }

  Future<void> _deleteSelectedPermanently() async {
    final itemsToDelete = _allItems.where((item) => _selectedIds.contains(item.id)).toList();
    if (itemsToDelete.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(L10n.of(context).ui_recycle_perm_delete_title),
        content: Text(L10n.of(context).ui_recycle_perm_delete_message(itemsToDelete.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L10n.of(context).ui_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.of(context).ui_delete),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      for (final item in itemsToDelete) {
        await RecycleBinService.deletePermanently(item);
      }
      if (mounted) Navigator.pop(context); // Dismiss loading

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).ui_recycle_perm_delete_success(itemsToDelete.length)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (mounted) Navigator.pop(context); // Dismiss loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).ui_recycle_perm_delete_failed(e.toString())),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    _clearSelection();
    _loadItems();
  }

  Future<void> _emptyRecycleBin() async {
    if (_allItems.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(L10n.of(context).ui_recycle_empty_title),
        content: Text(L10n.of(context).msg62187f1b),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(L10n.of(context).ui_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: Text(L10n.of(context).msg8cd6bc18),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // Show loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await RecycleBinService.emptyBin();
      if (mounted) Navigator.pop(context); // Dismiss loading
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).msga4dfc0c6),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (mounted) Navigator.pop(context); // Dismiss loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).ui_recycle_empty_failed(e.toString())),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    _clearSelection();
    _loadItems();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = RecycleBinService.isEnabled();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: _isSelectionMode
            ? Text(L10n.of(context).ui_recycle_selected_count(_selectedIds.length))
            : _isSearching
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: L10n.of(context).msg07d80ac5,
                      border: InputBorder.none,
                    ),
                    style: theme.textTheme.titleMedium,
                    onChanged: (val) {
                      setState(() {
                        _searchQuery = val;
                        _filterItems();
                      });
                    },
                  )
                : Text(L10n.of(context).ui_recycle_bin),
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: _clearSelection,
              )
            : IconButton(
                icon: const Icon(Broken.arrow_left),
                onPressed: () => Navigator.pop(context),
              ),
        actions: [
          if (!_isSelectionMode) ...[
            if (_isSearching)
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  setState(() {
                    _isSearching = false;
                    _searchQuery = "";
                    _searchController.clear();
                    _filterItems();
                  });
                },
              )
            else
              IconButton(
                icon: const Icon(Broken.search_normal),
                onPressed: () {
                  setState(() {
                    _isSearching = true;
                  });
                },
              ),
            IconButton(
              icon: const Icon(Broken.trash, color: Colors.redAccent),
              onPressed: _allItems.isEmpty ? null : _emptyRecycleBin,
              tooltip: L10n.of(context).msg8cd6bc18,
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 回收站开关（统一管理入口，从设置迁移至此）
            _buildRecycleBinCard(theme, enabled),
            // 列表 / 空状态 / 关闭提示
            Expanded(
              child: !enabled
                  ? _buildDisabledHint(theme)
                  : _allItems.isEmpty
                      ? _buildEmptyState(theme)
                      : Column(
                          children: [
                            Expanded(
                              child: ListView.builder(
                                physics: const BouncingScrollPhysics(),
                                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                                itemCount: _filteredItems.length,
                                itemBuilder: (context, index) {
                                  final item = _filteredItems[index];
                                  final isSelected = _selectedIds.contains(item.id);

                                  final icon = item.isDirectory
                                      ? FileUtils.getFolderIcon('default')
                                      : FileUtils.getIconForFile(item.name);
                                  final iconColor = item.isDirectory
                                      ? theme.colorScheme.primary
                                      : FileUtils.getColorForFile(item.name, context);

                                  return Card(
                                    margin: const EdgeInsets.symmetric(vertical: 6),
                                    color: isSelected
                                        ? theme.colorScheme.primaryContainer.withOpacity(0.4)
                                        : theme.colorScheme.surface,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                      side: BorderSide(
                                        color: isSelected
                                            ? theme.colorScheme.primary
                                            : theme.dividerColor.withOpacity(0.08),
                                        width: isSelected ? 1.5 : 1.0,
                                      ),
                                    ),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(16),
                                      onTap: () {
                                        if (_isSelectionMode) {
                                          _toggleSelection(item.id);
                                        } else {
                                          _showItemDetails(item);
                                        }
                                      },
                                      onLongPress: () => _toggleSelection(item.id),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                        child: Row(
                                          children: [
                                            // Leading Icon
                                            Container(
                                              width: 48,
                                              height: 48,
                                              decoration: BoxDecoration(
                                                color: isSelected
                                                    ? theme.colorScheme.primary
                                                    : theme.colorScheme.primary.withOpacity(0.08),
                                                borderRadius: BorderRadius.circular(12),
                                              ),
                                              child: isSelected
                                                  ? Icon(Broken.tick_circle,
                                                      color: theme.colorScheme.onPrimary, size: 24)
                                                  : (!item.isDirectory && FileUtils.isArchive(item.name)
                                                      ? ArchiveTypeIcon(label: FileUtils.getArchiveTypeLabel(item.name), color: iconColor, iconScale: 24 / 28)
                                                      : Icon(icon, color: iconColor, size: 24)),
                                            ),
                                            const SizedBox(width: 16),
                                            // Metadata details
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    item.name,
                                                    style: theme.textTheme.titleMedium?.copyWith(
                                                      fontWeight: FontWeight.w600,
                                                      fontSize: 14.5,
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    '${L10n.of(context).msg4c478216}: ${item.originalPath}',
                                                    style: theme.textTheme.bodySmall?.copyWith(
                                                      color: theme.colorScheme.onSurface.withOpacity(0.4),
                                                      fontSize: 11,
                                                    ),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    L10n.of(context).ui_recycle_deleted_at(
                                                      FileUtils.formatDate(item.deletedAt),
                                                      FileUtils.formatBytes(item.size, 1),
                                                    ),
                                                    style: theme.textTheme.bodySmall?.copyWith(
                                                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            // Trailing popup menu for quick actions
                                            if (!_isSelectionMode)
                                              PopupMenuButton<String>(
                                                icon: const Icon(Broken.more, size: 20),
                                                shape: RoundedRectangleBorder(
                                                    borderRadius: BorderRadius.circular(16)),
                                                position: PopupMenuPosition.under,
                                                onSelected: (action) async {
                                                  if (action == 'restore') {
                                                    _selectedIds.clear();
                                                    _selectedIds.add(item.id);
                                                    await _restoreSelected();
                                                  } else if (action == 'delete') {
                                                    _selectedIds.clear();
                                                    _selectedIds.add(item.id);
                                                    await _deleteSelectedPermanently();
                                                  }
                                                },
                                                itemBuilder: (context) => [
                                                  PopupMenuItem(
                                                    value: 'restore',
                                                    child: Row(
                                                      children: [
                                                        Icon(Icons.restore_rounded, size: 20),
                                                        SizedBox(width: 12),
                                                        Text(L10n.of(context).ui_recycle_restore,
                                                            style: TextStyle(fontWeight: FontWeight.w500)),
                                                      ],
                                                    ),
                                                  ),
                                                  PopupMenuItem(
                                                    value: 'delete',
                                                    child: Row(
                                                      children: [
                                                        Icon(Broken.trash,
                                                            size: 20, color: Colors.redAccent),
                                                        SizedBox(width: 12),
                                                        Text(L10n.of(context).msg96d2b75f,
                                                            style: TextStyle(
                                                                color: Colors.redAccent,
                                                                fontWeight: FontWeight.w500)),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            // Multi-Selection Bottom Action Bar
                            if (_isSelectionMode)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surface,
                                  border: Border(
                                    top: BorderSide(
                                      color: theme.dividerColor.withOpacity(0.12),
                                      width: 1,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(14),
                                          ),
                                        ),
                                        onPressed: _restoreSelected,
                                        icon: const Icon(Icons.restore_rounded),
                                        label: Text(L10n.of(context).ui_recycle_restore),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: FilledButton.icon(
                                        style: FilledButton.styleFrom(
                                          backgroundColor: Colors.redAccent,
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(14),
                                          ),
                                        ),
                                        onPressed: _deleteSelectedPermanently,
                                        icon: const Icon(Broken.trash),
                                        label: Text(L10n.of(context).ui_delete),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecycleBinCard(ThemeData theme, bool enabled) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withOpacity(0.08)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Broken.trash, color: theme.colorScheme.primary, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(L10n.of(context).msge99f4762,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(L10n.of(context).msg25792550,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.5))),
                  ],
                ),
              ),
              Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: enabled,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (val) {
                    setState(() {
                      RecycleBinService.setEnabled(val);
                    });
                  },
                ),
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            InkWell(
              onTap: () => _showAutoDeleteDaysPickerDialog(context, theme),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.only(top: 12.0),
                child: Row(
                  children: [
                    Icon(Icons.access_time_rounded,
                        size: 20, color: theme.colorScheme.onSurface.withOpacity(0.7)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(L10n.of(context).msgf0ef894a,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500)),
                    ),
                    Text(_getAutoDeleteDaysLabel(RecycleBinService.getAutoDeleteDays()),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.6))),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: theme.colorScheme.onSurface.withOpacity(0.4)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDisabledHint(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Broken.trash,
                size: 72,
                color: theme.colorScheme.primary.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              L10n.of(context).ui_recycle_disabled_hint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Broken.trash,
                size: 84,
                color: theme.colorScheme.primary.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              L10n.of(context).msg0d824a24,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              L10n.of(context).ui_recycle_empty_hint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _showItemDetails(RecycleBinItem item) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              _buildDetailRow(L10n.of(context).msg4c478216, item.originalPath),
              _buildDetailRow(L10n.of(context).ui_recycle_deleted_date, FileUtils.formatDate(item.deletedAt)),
              _buildDetailRow(L10n.of(context).msg396b7d3f, FileUtils.formatBytes(item.size, 2)),
              _buildDetailRow(L10n.of(context).ui_recycle_type, item.isDirectory ? L10n.of(context).msg1f4c1042 : L10n.of(context).ui_recycle_file),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () async {
                        Navigator.pop(context);
                        _selectedIds.clear();
                        _selectedIds.add(item.id);
                        await _restoreSelected();
                      },
                      child: Text(L10n.of(context).ui_recycle_restore),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () async {
                        Navigator.pop(context);
                        _selectedIds.clear();
                        _selectedIds.add(item.id);
                        await _deleteSelectedPermanently();
                      },
                      child: Text(L10n.of(context).msg96d2b75f),
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

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ),
    );
  }

  String _getAutoDeleteDaysLabel(int days) {
    if (days <= 0) return L10n.of(context).msg6a7c758f;
    if (days == 1) return L10n.of(context).ui_1_day_after;
    return L10n.of(context).days1(days);
  }

  void _showAutoDeleteDaysPickerDialog(BuildContext context, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        final current = RecycleBinService.getAutoDeleteDays();
        final options = [
          {'days': 7, 'label': L10n.of(context).msgfdef8c23},
          {'days': 15, 'label': L10n.of(context).msg25436ba3},
          {'days': 30, 'label': L10n.of(context).msg85e7f60c},
          {'days': 0, 'label': L10n.of(context).msgd61e706f},
        ];

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurface.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Text(
                    L10n.of(context).msgf0ef894a,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Text(
                    L10n.of(context).msg1200d6b7,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  ),
                ),
                const SizedBox(height: 16),
                ...options.map((opt) {
                  final days = opt['days'] as int;
                  final label = opt['label'] as String;
                  final isSelected = current == days;

                  return Card(
                    color: isSelected ? theme.colorScheme.primary.withOpacity(0.12) : theme.colorScheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: isSelected ? theme.colorScheme.primary : theme.dividerColor.withOpacity(0.08)),
                    ),
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        RecycleBinService.setAutoDeleteDays(days);
                        setState(() {});
                        Navigator.pop(ctx);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Row(
                          children: [
                            Icon(Icons.access_time_rounded, color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface.withOpacity(0.6)),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                                ),
                              ),
                            ),
                            if (isSelected) Icon(Icons.check_circle, color: theme.colorScheme.primary),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }
}
