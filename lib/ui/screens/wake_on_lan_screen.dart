import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../services/wake_on_lan_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 局域网唤醒页面：管理设备列表并发送魔术包唤醒
class WakeOnLanScreen extends StatefulWidget {
  const WakeOnLanScreen({super.key});

  @override
  State<WakeOnLanScreen> createState() => _WakeOnLanScreenState();
}

class _WakeOnLanScreenState extends State<WakeOnLanScreen> {
  List<WolDevice> _devices = [];
  final Set<String> _waking = {}; // 正在唤醒的设备 id

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final devices = await WakeOnLanService.loadDevices();
    if (!mounted) return;
    setState(() => _devices = devices);
  }

  Future<void> _wake(WolDevice device) async {
    final l10n = L10n.of(context);
    setState(() => _waking.add(device.id));
    try {
      final err = await WakeOnLanService.sendPacket(device);
      if (!mounted) return;
      final msg = err == 'invalid_mac'
          ? l10n.wol_invalid_mac
          : err != null
              ? l10n.wol_send_failed
              : l10n.wol_sent;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          backgroundColor: err == null
              ? Theme.of(context).colorScheme.primary
              : Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _waking.remove(device.id));
    }
  }

  Future<void> _showDeviceSheet({WolDevice? existing}) async {
    final l10n = L10n.of(context);
    final nameCtl =
        TextEditingController(text: existing?.name ?? '');
    final macCtl = TextEditingController(text: existing?.mac ?? '');
    final bcastCtl =
        TextEditingController(text: existing?.broadcast ?? '');
    final portCtl =
        TextEditingController(text: (existing?.port ?? 9).toString());

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            decoration: BoxDecoration(
              color: theme.scaffoldBackgroundColor,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  existing == null
                      ? l10n.wol_add_device
                      : l10n.wol_edit_device,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameCtl,
                  decoration: InputDecoration(
                    labelText: l10n.wol_name,
                    hintText: l10n.wol_name_hint,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: macCtl,
                  decoration: InputDecoration(
                    labelText: l10n.wol_mac,
                    hintText: 'AA:BB:CC:DD:EE:FF',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                        RegExp(r'[0-9A-Fa-f:.\-\s]')),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bcastCtl,
                  decoration: InputDecoration(
                    labelText: l10n.wol_broadcast,
                    hintText: '192.168.1.255',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: portCtl,
                  decoration: InputDecoration(
                    labelText: l10n.wol_port,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(l10n.ui_save),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (saved != true) return;
    final mac = WolDevice.normalizeMac(macCtl.text);
    if (mac == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.wol_invalid_mac),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }
    final device = existing ??
        WolDevice(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: '',
          mac: '',
        );
    device
      ..name = nameCtl.text.trim().isEmpty
          ? mac
          : nameCtl.text.trim()
      ..mac = mac
      ..broadcast = bcastCtl.text.trim()
      ..port = int.tryParse(portCtl.text.trim()) ?? 9;
    if (existing == null) {
      _devices.add(device);
    }
    await WakeOnLanService.saveDevices(_devices);
    if (mounted) setState(() {});
  }

  Future<void> _deleteDevice(WolDevice device) async {
    final l10n = L10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(l10n.ui_delete,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Text(l10n.wol_delete_confirm(device.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.ui_cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white),
            child: Text(l10n.ui_delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _devices.removeWhere((d) => d.id == device.id);
      await WakeOnLanService.saveDevices(_devices);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.wol_title),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showDeviceSheet(),
        child: const Icon(Broken.add),
      ),
      body: _devices.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Broken.electricity,
                      size: 56,
                      color: theme.colorScheme.onSurface.withOpacity(0.2)),
                  const SizedBox(height: 12),
                  Text(
                    l10n.wol_empty,
                    style: TextStyle(
                        color:
                            theme.colorScheme.onSurface.withOpacity(0.5)),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _devices.length,
              itemBuilder: (context, index) {
                final device = _devices[index];
                final isWaking = _waking.contains(device.id);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        theme.colorScheme.primary.withOpacity(0.12),
                    child: Icon(Broken.monitor,
                        color: theme.colorScheme.primary),
                  ),
                  title: Text(device.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '${device.mac}  ·  ${device.broadcast.isEmpty ? '255.255.255.255' : device.broadcast}:${device.port}',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      isWaking
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              tooltip: l10n.wol_wake,
                              icon: Icon(Broken.electricity,
                                  color: theme.colorScheme.primary),
                              onPressed: () => _wake(device),
                            ),
                      PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'edit') {
                            _showDeviceSheet(existing: device);
                          } else if (v == 'delete') {
                            _deleteDevice(device);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'edit',
                            child: Row(
                              children: [
                                Icon(Broken.edit,
                                    size: 18,
                                    color: theme.colorScheme.primary),
                                const SizedBox(width: 10),
                                Text(l10n.drawer_edit_connection),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                const Icon(Broken.trash,
                                    size: 18, color: Colors.red),
                                const SizedBox(width: 10),
                                Text(l10n.ui_delete),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
