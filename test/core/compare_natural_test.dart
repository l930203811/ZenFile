import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/core/utils.dart';

/// 旧版 BigInt 实现（v3.8.3 及以前），作为语义对照基准。
int _legacyCompareNatural(String a, String b) {
  int i = 0;
  int j = 0;
  final aLower = a.toLowerCase();
  final bLower = b.toLowerCase();
  bool isDigit(int c) => c >= 48 && c <= 57;

  while (i < aLower.length && j < bLower.length) {
    final charA = aLower.codeUnitAt(i);
    final charB = bLower.codeUnitAt(j);
    if (isDigit(charA) && isDigit(charB)) {
      final startA = i;
      while (i < aLower.length && isDigit(aLower.codeUnitAt(i))) {
        i++;
      }
      final startB = j;
      while (j < bLower.length && isDigit(bLower.codeUnitAt(j))) {
        j++;
      }
      final subA = aLower.substring(startA, i);
      final subB = bLower.substring(startB, j);
      final numA = BigInt.tryParse(subA);
      final numB = BigInt.tryParse(subB);
      if (numA != null && numB != null) {
        final cmp = numA.compareTo(numB);
        if (cmp != 0) return cmp;
        if (subA.length != subB.length) {
          return subA.length.compareTo(subB.length);
        }
      } else {
        final cmp = subA.compareTo(subB);
        if (cmp != 0) return cmp;
      }
    } else {
      if (charA != charB) return charA.compareTo(charB);
      i++;
      j++;
    }
  }
  if (i < aLower.length) return 1;
  if (j < bLower.length) return -1;
  return a.compareTo(b);
}

int _sign(int x) => x == 0 ? 0 : (x > 0 ? 1 : -1);

void main() {
  group('compareNatural 与旧 BigInt 实现语义一致', () {
    const edgeCases = <String>[
      '', 'a', 'A', 'a1', 'a01', 'a001', 'a1b', 'a01b',
      'file2.txt', 'file10.txt', 'file0002.txt', 'file02.txt',
      '0', '00', '000', '1', '01', '9', '10', '0009', '0010',
      'IMG_0001.JPG', 'img_1.jpg', 'IMG_2.jpg', 'img_0002.JPG',
      'v1.2.10', 'v1.2.9', 'v1.10.0', 'v1.9.0',
      '第2集', '第10集', '第02集', ' Track 3', 'track 03',
      '123456789012345678901234567890', '123456789012345678901234567891',
      '99999999999999999999', '100000000000000000000',
      'a0b0', 'a00b00', 'x', 'X1', 'x1', 'x01',
    ];

    test('固定边界用例两两对拍', () {
      for (final a in edgeCases) {
        for (final b in edgeCases) {
          expect(
            _sign(FileUtils.compareNatural(a, b)),
            _sign(_legacyCompareNatural(a, b)),
            reason: 'compareNatural("$a", "$b")',
          );
          expect(
            _sign(FileUtils.compareNaturalLower(
                a, b, a.toLowerCase(), b.toLowerCase())),
            _sign(_legacyCompareNatural(a, b)),
            reason: 'compareNaturalLower("$a", "$b")',
          );
        }
      }
    });

    test('随机字符串对拍（含数字段/前导零/大小写/中文）', () {
      final rng = Random(20261126);
      const alphabet = 'abcXYZ0123456789 ._-文件集';
      String randStr() {
        final len = rng.nextInt(14);
        return String.fromCharCodes(Iterable.generate(
            len, (_) => alphabet.codeUnitAt(rng.nextInt(alphabet.length))));
      }

      for (var n = 0; n < 20000; n++) {
        final a = randStr();
        final b = randStr();
        expect(
          _sign(FileUtils.compareNatural(a, b)),
          _sign(_legacyCompareNatural(a, b)),
          reason: 'compareNatural("$a", "$b")',
        );
      }
    });

    test('排序结果与旧实现一致（大列表）', () {
      final rng = Random(42);
      final names = List.generate(3000, (i) {
        final prefix = ['IMG_', 'file', 'Track ', '第'][rng.nextInt(4)];
        final num = rng.nextInt(10000).toString().padLeft(rng.nextInt(6), '0');
        final suffix = ['.jpg', '.txt', '', '.MP4'][rng.nextInt(4)];
        return '$prefix$num$suffix';
      });
      final actual = [...names]..sort(FileUtils.compareNatural);
      final expected = [...names]..sort(_legacyCompareNatural);
      expect(actual, expected);
    });
  });
}