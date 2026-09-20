import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/restricted_dir_parser.dart';

/// 受限目录（Android/data、Android/obb）列目录输出的解析逻辑。
///
/// 这层逻辑直接决定「root / Shizuku 列受限目录到底显不显示内容」：
/// shell 输出会因 ROM 差异混入 stderr、格式也不同（find+stat / ls -la），
/// 解析过松会把错误文本当成文件，过严又会把合法条目丢掉。
void main() {
  group('FUSE 路径转换', () {
    test('Android 区路径转底层后可原样还原', () {
      const visible = '/storage/emulated/0/Android/data/com.tencent.mm';
      final raw = toFuseBypassPath(visible);
      expect(raw, '/data/media/0/Android/data/com.tencent.mm');
      expect(fromFuseBypassPath(raw), visible);
    });

    test('非 Android 路径不转换（避免制造系统里不存在的底层路径）', () {
      expect(toFuseBypassPath('/storage/emulated/0/Download'),
          '/storage/emulated/0/Download');
      // Android 目录本身不转：只有 data/obb 需要绕 FUSE。
      expect(toFuseBypassPath('/storage/emulated/0/Android'),
          '/storage/emulated/0/Android');
      expect(fromFuseBypassPath('/data/media/0/Download'),
          '/data/media/0/Download');
    });

    test('重复斜杠被归一化', () {
      expect(toFuseBypassPath('/storage/emulated/0//Android//data'),
          '/data/media/0/Android/data');
    });
  });

  group('parseStatPipeLines（find + stat 主链路）', () {
    test('解析类型/大小/时间/路径四段', () {
      const out = 'directory|4096|1700000000|/data/media/0/Android/data/com.tencent.mm\n'
          'regular file|123|1700000100|/data/media/0/Android/data/note.txt\n';
      final items = parseStatPipeLines(out, showHiddenFiles: false);

      expect(items.length, 2);
      expect(items[0].name, 'com.tencent.mm');
      expect(items[0].isDirectory, isTrue);
      expect(items[0].path, '/storage/emulated/0/Android/data/com.tencent.mm');
      expect(items[0].size, 4096);
      expect(items[1].name, 'note.txt');
      expect(items[1].isDirectory, isFalse);
      expect(items[1].size, 123);
    });

    test('过滤掉混进来的 stderr（不再 2>/dev/null 后必须成立）', () {
      const out = 'find: /data/media/0/Android/data: Permission denied\n'
          'stat: not found\n'
          'directory|4096|1700000000|/data/media/0/Android/data/com.a\n';
      final items = parseStatPipeLines(out, showHiddenFiles: false);
      expect(items.length, 1);
      expect(items[0].name, 'com.a');
    });

    test('字段非数字的行被丢弃', () {
      const out = 'directory|abc|1700000000|/data/media/0/Android/data/x\n'
          'directory|4096|xyz|/data/media/0/Android/data/y\n';
      expect(parseStatPipeLines(out, showHiddenFiles: false), isEmpty);
    });

    test('文件名里的竖线不被截断', () {
      const out = 'regular file|10|1700000000|/data/media/0/Android/data/a|b.txt\n';
      final items = parseStatPipeLines(out, showHiddenFiles: false);
      expect(items.length, 1);
      expect(items[0].name, 'a|b.txt');
    });

    test('隐藏文件按开关过滤', () {
      const out = 'regular file|1|1700000000|/data/media/0/Android/data/.nomedia\n';
      expect(parseStatPipeLines(out, showHiddenFiles: false), isEmpty);
      expect(parseStatPipeLines(out, showHiddenFiles: true).length, 1);
    });

    test('空输出与纯空白返回空表', () {
      expect(parseStatPipeLines('', showHiddenFiles: false), isEmpty);
      expect(parseStatPipeLines('\n\n  \n', showHiddenFiles: false), isEmpty);
    });
  });

  group('parseLsLongOutput（find 不可用时的兜底）', () {
    const dir = '/data/media/0/Android/data';

    test('解析 toybox ls -la 的 yyyy-MM-dd HH:mm 格式', () {
      const out = 'total 24\n'
          'drwxrwx--x  3 u0_a123 u0_a123 4096 2024-01-02 12:34 com.tencent.mm\n'
          '-rw-r--r--  1 u0_a123 u0_a123  123 2024-01-02 12:34 note.txt\n';
      final items = parseLsLongOutput(out, dir: dir, showHiddenFiles: false);

      expect(items.length, 2);
      expect(items[0].name, 'com.tencent.mm');
      expect(items[0].isDirectory, isTrue);
      expect(items[0].path, '/storage/emulated/0/Android/data/com.tencent.mm');
      expect(items[0].size, 4096);
      expect(items[0].modified.year, 2024);
      expect(items[0].modified.month, 1);
      expect(items[1].name, 'note.txt');
      expect(items[1].isDirectory, isFalse);
    });

    test('解析 Mon DD HH:mm（当年）与 Mon DD YYYY', () {
      const out = '-rw-r--r-- 1 u0_a1 u0_a1 5 Jan  2 12:34 a.txt\n'
          '-rw-r--r-- 1 u0_a1 u0_a1 5 Jan  2  2023 b.txt\n';
      final items = parseLsLongOutput(out, dir: dir, showHiddenFiles: false);
      expect(items.length, 2);
      expect(items[1].modified.year, 2023);
      expect(items[1].modified.month, 1);
    });

    test('符号链接取链接名，且不当作目录', () {
      const out = 'lrwxrwxrwx 1 root root 10 2024-01-02 12:34 link -> /data/x\n';
      final items = parseLsLongOutput(out, dir: dir, showHiddenFiles: false);
      expect(items.length, 1);
      expect(items[0].name, 'link');
      expect(items[0].isDirectory, isFalse);
    });

    test('跳过 total、. 、.. 与非 ls 行', () {
      const out = 'total 8\n'
          'drwxrwx--x 2 root root 4096 2024-01-02 12:34 .\n'
          'drwxrwx--x 2 root root 4096 2024-01-02 12:34 ..\n'
          'garbage line\n';
      expect(parseLsLongOutput(out, dir: dir, showHiddenFiles: false), isEmpty);
    });

    test('权限串带 ACL 标记（+）也能解析', () {
      const out = 'drwxr-xr-x+ 2 u0_a1 u0_a1 4096 2024-01-02 12:34 com.a\n';
      final items = parseLsLongOutput(out, dir: dir, showHiddenFiles: false);
      expect(items.length, 1);
      expect(items[0].name, 'com.a');
    });

    test('目录参数以斜杠结尾时拼接不产生双斜杠', () {
      const out = '-rw-r--r-- 1 u0_a1 u0_a1 5 2024-01-02 12:34 a.txt\n';
      final items = parseLsLongOutput(out,
          dir: '/data/media/0/Android/data/', showHiddenFiles: false);
      expect(items[0].path, '/storage/emulated/0/Android/data/a.txt');
    });

    test('隐藏文件按开关过滤', () {
      const out = '-rw-r--r-- 1 u0_a1 u0_a1 5 2024-01-02 12:34 .nomedia\n';
      expect(parseLsLongOutput(out, dir: dir, showHiddenFiles: false), isEmpty);
      expect(parseLsLongOutput(out, dir: dir, showHiddenFiles: true).length, 1);
    });

    test('带空格的文件名完整保留', () {
      const out = '-rw-r--r-- 1 u0_a1 u0_a1 5 2024-01-02 12:34 my file.txt\n';
      final items = parseLsLongOutput(out, dir: dir, showHiddenFiles: false);
      expect(items.length, 1);
      expect(items[0].name, 'my file.txt');
    });
  });
}
