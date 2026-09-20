import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/ui/widgets/conflict_dialog.dart';

/// `resolveConflictFileInfo` —— 冲突弹窗「大小 / 修改时间」的唯一取值入口。
///
/// 这里的边界直接决定远程粘贴重名时弹窗显示什么：
/// - 远程条目由调用方带入（不做本地 stat）；
/// - 本地目标 stat 出真实值；
/// - **空路径 / 不存在路径必须是「未知」**：Dart 的 `File('').stat()` 不抛异常，
///   而是返回 `size: -1 / 1970-01-01`，旧实现直接把这两个伪值显示给用户
///   （弹窗上的「0 B · 1970-01-01」—— size=-1 经 formatBytes 会变成 0 B）。
void main() {
  test('调用方给了信息 → 原样采用，不做本地 stat', () async {
    final given = ConflictFileInfo(
      size: 12345,
      modified: DateTime(2026, 9, 19, 23, 40),
    );
    // 路径故意给一个不存在的东西，证明不会去 stat
    final resolved = await resolveConflictFileInfo(
      File('/definitely/not/here/zzz'),
      given,
    );
    expect(resolved.size, 12345);
    expect(resolved.modified, DateTime(2026, 9, 19, 23, 40));
  });

  test('本地真实文件 → 取到真实大小与修改时间', () async {
    final dir = await Directory.systemTemp.createTemp('conflict_info_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final file = File('${dir.path}/a.bin');
    await file.writeAsBytes(List.filled(2048, 3));

    final resolved = await resolveConflictFileInfo(file, null);
    expect(resolved.size, 2048);
    expect(resolved.modified, isNotNull);
    expect(resolved.modified!.millisecondsSinceEpoch, greaterThan(0));
  });

  test('路径不存在 → 未知（size/modified 均为 null，而不是 0/1970）', () async {
    final resolved = await resolveConflictFileInfo(
      File('${Directory.systemTemp.path}/zenfile_zzz_not_exists/a.bin'),
      null,
    );
    expect(resolved.size, isNull);
    expect(resolved.modified, isNull);
  });

  test('空路径（旧调用方传 File(\'\') 的远程场景）→ 未知，不是 -1 B / 1970-01-01', () async {
    final resolved = await resolveConflictFileInfo(File(''), null);
    expect(resolved.size, isNull, reason: 'Dart 会返回 -1，绝不能当真实大小');
    expect(resolved.modified, isNull, reason: 'Dart 会返回 1970-01-01，绝不能当真实时间');
  });
}
