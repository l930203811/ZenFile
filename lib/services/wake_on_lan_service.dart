import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// 局域网唤醒设备模型
class WolDevice {
  final String id;
  String name;
  String mac; // 支持 : - 或无分隔符输入，内部规范化为大写冒号分隔
  String broadcast; // 广播地址，如 192.168.1.255（留空则用 255.255.255.255）
  int port; // UDP 端口，默认 9

  WolDevice({
    required this.id,
    required this.name,
    required this.mac,
    this.broadcast = '',
    this.port = 9,
  });

  /// 规范化 MAC（大写、冒号分隔），非法返回 null
  static String? normalizeMac(String input) {
    final cleaned = input.trim().replaceAll(RegExp(r'[\s:.\-]'), '');
    if (!RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(cleaned)) return null;
    final upper = cleaned.toUpperCase();
    return RegExp(r'.{2}').allMatches(upper).map((m) => m.group(0)!).join(':');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mac': mac,
        'broadcast': broadcast,
        'port': port,
      };

  factory WolDevice.fromJson(Map<String, dynamic> json) => WolDevice(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        mac: json['mac'] as String? ?? '',
        broadcast: json['broadcast'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 9,
      );
}

/// 局域网唤醒服务：设备列表持久化 + 魔术包发送
class WakeOnLanService {
  static const _prefKey = 'wol_devices';

  /// 读取已保存设备列表
  static Future<List<WolDevice>> loadDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => WolDevice.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存设备列表
  static Future<void> saveDevices(List<WolDevice> devices) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefKey, jsonEncode(devices.map((d) => d.toJson()).toList()));
    } catch (_) {}
  }

  /// 构造魔术包：6×0xFF + 16×MAC（共 102 字节）
  static Uint8List buildMagicPacket(String normalizedMac) {
    final macBytes = normalizedMac
        .split(':')
        .map((s) => int.parse(s, radix: 16))
        .toList();
    final packet = BytesBuilder();
    for (var i = 0; i < 6; i++) {
      packet.addByte(0xFF);
    }
    for (var i = 0; i < 16; i++) {
      packet.add(macBytes);
    }
    return packet.toBytes();
  }

  /// 发送唤醒包。同一广播地址连发 3 次提高可靠性。
  /// 返回 null 表示成功，否则返回错误信息（由调用方本地化）。
  static Future<String?> sendPacket(WolDevice device) async {
    final mac = WolDevice.normalizeMac(device.mac);
    if (mac == null) return 'invalid_mac';
    final addr = device.broadcast.trim().isEmpty
        ? '255.255.255.255'
        : device.broadcast.trim();
    final port = device.port <= 0 || device.port > 65535 ? 9 : device.port;
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind('0.0.0.0', 0);
      socket.broadcastEnabled = true;
      final packet = buildMagicPacket(mac);
      for (var i = 0; i < 3; i++) {
        socket.send(packet, InternetAddress(addr), port);
      }
      return null;
    } on SocketException {
      return 'send_failed';
    } catch (_) {
      return 'send_failed';
    } finally {
      socket?.close();
    }
  }
}
