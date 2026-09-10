import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/crypt/scrypt.dart';
import 'package:pinenacl/src/key_derivation/pbkdf2.dart';

String _toHex(Uint8List b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('PBKDF2-HMAC-SHA256 reference', () {
    final out = PBKDF2.hmac_sha256(
        Uint8List.fromList(utf8.encode('password')),
        Uint8List.fromList(utf8.encode('salt')),
        1,
        64);
    expect(
        _toHex(out),
        equals(
            '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b4'
            'dbf3a2f3dad3377264bb7b8e8330d4efc7451418617dabef683735361cdc18c'));
  });

  test('RFC 7914 scrypt("","",N=16,r=1,p=1,dkLen=64)', () {
    final out = scrypt(
      utf8.encode(''),
      utf8.encode(''),
      N: 16,
      r: 1,
      p: 1,
      keyLength: 64,
    );
    const expected =
        '77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442'
        'fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906';
    expect(_toHex(out), equals(expected));
  });

  test('RFC 7914 scrypt("password","salt",N=1024,r=8,p=1,dkLen=64)', () {
    final out = scrypt(
      utf8.encode('password'),
      utf8.encode('salt'),
      N: 1024,
      r: 8,
      p: 1,
      keyLength: 64,
    );
    const expected =
        '16dbc8906763c7f048977a68f9d305f7710e068ca2cd95dab372125bb3f19608'
        '175003c79f9cdee65d2e45fc1f169afde0a6806f5d4f2ba0584249d2e66c2c96';
    expect(_toHex(out), equals(expected));
  });

  test('RFC 7914 scrypt 80 字节派生（rclone 密钥拆分路径, N=1024,r=8）', () {
    // rclone crypt 用 keyLen=80，切分为 dataKey[0:32) + nameKey[32:64) +
    // nameTweak[64:80)。本用例验证 80 字节输出（含交织 blockMix 与正确
    // integerify 偏移），前 64 字节应与上面的 dkLen=64 向量一致。
    final out = scrypt(
      utf8.encode('password'),
      utf8.encode('salt'),
      N: 1024,
      r: 8,
      p: 1,
      keyLength: 80,
    );
    const expected =
        '16dbc8906763c7f048977a68f9d305f7710e068ca2cd95dab372125bb3f19608'
        '175003c79f9cdee65d2e45fc1f169afde0a6806f5d4f2ba0584249d2e66c2c96'
        'cee540dfeaecc8a9e9100148da804068';
    expect(_toHex(out), equals(expected));
  });
}
