import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/core/utils.dart';

/// `uniqueNameAgainst` 是本地/远程各粘贴链路「保留两者 / 重命名」共用的取名函数。
///
/// 远程目标无法用「路径是否存在」探测（每文件一次请求太贵），只能拿目标目录列表
/// 里的名字集合判重 —— 因此这里的边界（扩展名、无扩展名目录、前导点隐藏文件、
/// 多级递增）直接决定远程粘贴会不会把用户的文件覆盖掉。
void main() {
  group('uniqueNameAgainst（目标目录判重取名）', () {
    test('无冲突 → 原样返回（不无谓改名）', () {
      expect(uniqueNameAgainst({'a.txt', 'b.txt'}, 'c.txt'), 'c.txt');
      expect(uniqueNameAgainst(<String>{}, 'c.txt'), 'c.txt');
    });

    test('有冲突 → 追加 (1)、(2)……，括号插在扩展名前', () {
      expect(uniqueNameAgainst({'a.txt'}, 'a.txt'), 'a (1).txt');
      expect(uniqueNameAgainst({'a.txt', 'a (1).txt'}, 'a.txt'), 'a (2).txt');
      expect(
        uniqueNameAgainst({'a.txt', 'a (1).txt', 'a (2).txt'}, 'a.txt'),
        'a (3).txt',
      );
    });

    test('无扩展名的目录 → 直接追加 (n)', () {
      expect(uniqueNameAgainst({'Movies'}, 'Movies'), 'Movies (1)');
      expect(
        uniqueNameAgainst({'Movies', 'Movies (1)'}, 'Movies'),
        'Movies (2)',
      );
    });

    test('多后缀文件名只按最后一段扩展名处理', () {
      expect(
        uniqueNameAgainst({'app-arm64-v8a-release.apk'}, 'app-arm64-v8a-release.apk'),
        'app-arm64-v8a-release (1).apk',
      );
      expect(
        uniqueNameAgainst({'a.tar.gz'}, 'a.tar.gz'),
        'a.tar (1).gz',
      );
    });

    test('前导点的隐藏文件按「无扩展名」处理', () {
      expect(uniqueNameAgainst({'.nomedia'}, '.nomedia'), '.nomedia (1)');
    });

    test('只有「点」或点结尾的名字不会产生空 base', () {
      expect(uniqueNameAgainst({'..'}, '..'), '.. (1)');
      expect(uniqueNameAgainst({'x.'}, 'x.'), 'x. (1)');
    });

    test('名字里的空格/中文/emoji 原样保留', () {
      expect(
        uniqueNameAgainst({'我的 照片 🎉.jpg'}, '我的 照片 🎉.jpg'),
        '我的 照片 🎉 (1).jpg',
      );
    });

    test('大小写不同视为不同名（远程服务端多数区分大小写）', () {
      expect(uniqueNameAgainst({'A.txt'}, 'a.txt'), 'a.txt');
    });
  });
}
