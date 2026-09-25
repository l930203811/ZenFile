import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/cache_clean_service.dart';

/// 回归测试：缓存清理**只能清缓存**。
///
/// 背景（2026-09-25 真实事故）：清理范围曾是「除 `Backups` 外全删」，把
/// `crash/`（崩溃报告）和 `webdav_debug.log` 一起删掉了。后果有两条，都被用户
/// 直接撞上：
///  1. 「崩溃后拿不到报告」—— 报告导进公共目录后又被同一次会话的清理删掉；
///  2. 「每次启动都提示上次异常退出」—— 判据是「本次新增份数」，报告一被删，
///     下次启动就会把同一份报告重新导出、再次判成新增。
///
/// 因此这里钉住：**保留清单里的条目一个都不能少**，且删掉的必须是缓存。
void main() {
  late Directory tmp;

  File write(String relative, [String content = 'x']) {
    final f = File(p.join(tmp.path, relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zf_cache_clean_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('诊断数据与用户数据必须原样保留', () {
    final keep = <File>[
      write('crash/exit_1700000000000_4.txt', 'crash report'),
      write('crash/java_crash_1700000000001.txt', 'java crash'),
      write('Backups/Settings/x.json', '{}'),
      write('Receive/from-peer.bin', 'data'),
      write('webdav_debug.log', 'log line'),
    ];
    // 同一批里放一个真缓存，才能同时验证「该保的保住、该删的删掉」。
    final cache = write('cache/streaming/a.tmp');

    final deleted = CacheCleanService.wipeSync(tmp.path);

    for (final f in keep) {
      expect(f.existsSync(), isTrue, reason: '${f.path} 绝不能被缓存清理删掉');
    }
    expect(cache.existsSync(), isFalse, reason: '同样是清理，缓存放着不管就白清了');
    expect(keep.first.readAsStringSync(), 'crash report',
        reason: '保留目录内部的文件也要原样不动');
    expect(deleted, greaterThan(0), reason: '该删的缓存仍然要删');
  });

  test('缓存目录被清空，且清理后必要的运行目录被重建', () {
    write('cache/streaming/a.tmp');
    write('cache/streaming/deep/b.tmp');
    write('.remote_cache/thumb.png');
    write('RemoteDecrypted/plain.mp4');
    write('.crypt_tmp/1700000000000/part');
    write('some-remote-file.mkv'); // 根目录下的下载缓存

    CacheCleanService.wipeSync(tmp.path);

    for (final gone in [
      'cache/streaming/a.tmp',
      'cache/streaming/deep/b.tmp',
      '.remote_cache/thumb.png',
      'RemoteDecrypted/plain.mp4',
      '.crypt_tmp/1700000000000/part',
      'some-remote-file.mkv',
    ]) {
      expect(File(p.join(tmp.path, gone)).existsSync(), isFalse,
          reason: '$gone 是缓存，应该被清掉');
    }

    // 运行目录必须重建，否则调用方会因目录缺失而异常
    for (final sub in CacheCleanService.runtimeDirs) {
      expect(Directory(p.join(tmp.path, sub)).existsSync(), isTrue,
          reason: '$sub 必须被重建');
    }
    expect(File(p.join(tmp.path, '.nomedia', '.nomedia')).existsSync(), isTrue,
        reason: '.nomedia 标记文件必须重建（否则缩略图缓存会被媒体库索引）');
  });

  test('目录不存在时返回 0 且不抛（清理失败不能变成新的崩溃源）', () {
    final missing = p.join(tmp.path, 'not-exists');
    expect(CacheCleanService.wipeSync(missing), 0);
  });

  test('异步 wipe 在 isolate 中同样生效（注入目录，不碰真机路径）', () async {
    write('cache/streaming/a.tmp');
    final crash = write('crash/exit_1_4.txt', 'keep me');

    await CacheCleanService.wipe(basePathOverride: tmp.path);

    expect(File(p.join(tmp.path, 'cache', 'streaming', 'a.tmp')).existsSync(), isFalse);
    expect(crash.existsSync(), isTrue, reason: 'isolate 里也必须遵守保留清单');
  });

  test('默认路径就是 ZenFile 根目录（真机路径不得被改错）', () {
    expect(CacheCleanService.basePath, '/storage/emulated/0/ZenFile');
  });

  test('保留清单必须包含诊断与用户数据（防止被误删）', () {
    for (final name in ['Backups', 'crash', 'Receive', 'webdav_debug.log']) {
      expect(CacheCleanService.preservedNames, contains(name));
      expect(CacheCleanService.shouldPreserve(name), isTrue);
    }
    expect(CacheCleanService.shouldPreserve('cache'), isFalse);
  });
}
