// 局域网扫描「显示主机名」的解析回归测试。
//
// 背景（2026-09-19）：用户希望扫描结果像同类 App 的「局部网络」一样显示
// 计算机名而不是只有 IP。做法是扫描结束后对已响应主机发 NetBIOS NBSTAT
// （Node Status Request，UDP 137），从应答的名称表里取计算机名。
//
// 真实设备无法在单测里 mock（137 是特权端口，且需真实 NetBIOS 服务端），
// 因此把「应答报文 → 主机名」的解析逻辑单独钉住——这是最容易出偏移错误的部分：
//   ① 名称表每条 18 字节（15 名称 + 1 后缀 + 2 flags）
//   ② 必须跳过组名（工作组名也是后缀 0x00，但 G 位为 1）
//   ③ 答案段的名称通常是 0xC0 0x0C 压缩指针，但也可能重复完整名称
//   ④ 截断/非 NBSTAT 报文必须安静返回 null（不能抛异常拖垮整个扫描）

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/remote/lan_client.dart';

/// 构造名称表条目：15 字节空格补齐的名称 + 后缀 + 2 字节 flags。
List<int> _entry(String name, int suffix, {bool group = false}) {
  final n = List<int>.filled(15, 0x20);
  for (var i = 0; i < name.length && i < 15; i++) {
    n[i] = name.codeUnitAt(i);
  }
  return [...n, suffix, group ? 0x80 : 0x00, 0x00];
}

/// 构造一个 NBSTAT 应答报文。
List<int> _nbstatResponse({
  required List<List<int>> entries,
  bool compressAnswerName = true,
}) {
  final question = <int>[
    0x20,
    0x43,
    0x4B,
    ...List<int>.filled(30, 0x41),
    0x00,
    0x00,
    0x21,
    0x00,
    0x01,
  ];
  final rdata = <int>[entries.length, ...entries.expand((e) => e)];
  final answerName = compressAnswerName
      ? <int>[0xC0, 0x0C]
      : question.sublist(0, question.length - 4);
  return <int>[
    0x12,
    0x34, // transaction id
    0x84,
    0x00, // flags
    0x00,
    0x01, // QDCOUNT
    0x00,
    0x01, // ANCOUNT
    0x00,
    0x00, // NSCOUNT
    0x00,
    0x00, // ARCOUNT
    ...question,
    ...answerName,
    0x00,
    0x21, // TYPE = NBSTAT
    0x00,
    0x01, // CLASS = IN
    0x00,
    0x00,
    0x00,
    0x00, // TTL
    (rdata.length >> 8) & 0xFF,
    rdata.length & 0xFF,
    ...rdata,
  ];
}

void main() {
  group('NetBIOS NBSTAT 应答解析', () {
    test('解析出后缀 0x00 的唯一计算机名', () {
      final data = _nbstatResponse(entries: [
        _entry('ZENFILE-NAS', 0x00),
        _entry('WORKGROUP', 0x00, group: true),
      ]);
      expect(LanClient.parseNbstatNameForTest(data), 'ZENFILE-NAS');
    });

    test('组名（工作组）被跳过，仍取到后面的计算机名', () {
      final data = _nbstatResponse(entries: [
        _entry('WORKGROUP', 0x00, group: true),
        _entry('DESKTOP-7K3', 0x00),
        _entry('DESKTOP-7K3', 0x20),
      ]);
      expect(LanClient.parseNbstatNameForTest(data), 'DESKTOP-7K3');
    });

    test('没有 0x00 唯一条目时回退到 0x20 服务名', () {
      final data = _nbstatResponse(entries: [
        _entry('WORKGROUP', 0x00, group: true),
        _entry('MYNAS', 0x20),
      ]);
      expect(LanClient.parseNbstatNameForTest(data), 'MYNAS');
    });

    test('答案段名称未压缩（重复完整名称）也能解析', () {
      final data = _nbstatResponse(
        entries: [_entry('OPENWRT', 0x00)],
        compressAnswerName: false,
      );
      expect(LanClient.parseNbstatNameForTest(data), 'OPENWRT');
    });

    test('空名称表 / 非 NBSTAT 应答（ANCOUNT=0）返回 null', () {
      final noAnswer = _nbstatResponse(entries: []);
      noAnswer[7] = 0; // ANCOUNT = 0
      expect(LanClient.parseNbstatNameForTest(noAnswer), isNull);

      expect(
        LanClient.parseNbstatNameForTest(_nbstatResponse(entries: [])),
        isNull,
      );
    });

    test('报文截断或异常时安静返回 null，不抛异常', () {
      expect(LanClient.parseNbstatNameForTest(const <int>[]), isNull);
      expect(LanClient.parseNbstatNameForTest(List<int>.filled(13, 0)), isNull);

      final full = _nbstatResponse(entries: [_entry('ABC', 0x00)]);
      expect(LanClient.parseNbstatNameForTest(full.sublist(0, 30)), isNull);
      expect(LanClient.parseNbstatNameForTest(full.sublist(0, 58)), isNull);
    });
  });
}
