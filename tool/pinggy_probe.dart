// 诊断脚本：精确复刻 ZenFile 的 Pinggy 隧道流程（dartssh2），
// 观察服务端实际输出（stdout/stderr），确认是否还有真实隧道 URL。
// 用法：cd D:\Xiangmu\ZenFile-main && dart run tool/pinggy_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

Future<void> main() async {
  stdout.writeln('== pinggy probe start ==');
  final stopwatch = Stopwatch()..start();
  try {
    final socket = await SSHSocket.connect('a.pinggy.io', 443,
        timeout: const Duration(seconds: 15));
    stdout.writeln('socket connected: ${stopwatch.elapsed}');
    final client = SSHClient(
      socket,
      username: 'free',
      onPasswordRequest: () => '',
    );
    await client.authenticated;
    stdout.writeln('authenticated: ${stopwatch.elapsed}');

    await client.forwardRemote(port: 0);
    stdout.writeln('forwardRemote done: ${stopwatch.elapsed}');

    final session = await client.execute('');
    stdout.writeln('session started: ${stopwatch.elapsed}');

    session.stdout.cast<List<int>>().transform(utf8.decoder).listen((d) {
      stdout.writeln('STDOUT>>> $d');
    });
    session.stderr.cast<List<int>>().transform(utf8.decoder).listen((d) {
      stdout.writeln('STDERR>>> $d');
    });

    // 观察 12 秒后关闭
    await Future.delayed(const Duration(seconds: 12));
    stdout.writeln('== closing after ${stopwatch.elapsed} ==');
    try {
      session.close();
    } catch (_) {}
    try {
      client.close();
    } catch (_) {}
  } catch (e, st) {
    stdout.writeln('ERROR: $e');
    stdout.writeln(st);
  }
  stdout.writeln('== pinggy probe end ==');
  exit(0);
}
