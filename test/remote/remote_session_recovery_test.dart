import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/remote/remote_session_recovery.dart';

/// 远程会话自愈的两块基石：**失效判定**与**重建后重试一次**。
///
/// 背景（2026-09-20 论坛用户反馈）：SFTP 切后台后删除失败、必须退出连接重进。
/// 判定过宽会让「认证失败 / 文件不存在」也白等一次重连握手；判定过窄则
/// 「会话已被回收」的场景救不回来。重试次数同理必须恰好是 1 次。
void main() {
  group('isRemoteConnectionLostError（连接失效判定）', () {
    test('JSch 会话被回收 → 命中', () {
      expect(isRemoteConnectionLostError(Exception('Session is down')), isTrue);
      expect(
        isRemoteConnectionLostError(Exception('SFTP session not found: abc-123')),
        isTrue,
      );
    });

    test('smbj 会话未建立 → 命中', () {
      expect(
        isRemoteConnectionLostError(
          Exception('SMB session not established. Call connect() first.'),
        ),
        isTrue,
      );
    });

    test('dart:io / dartssh2 的连接类异常 → 命中', () {
      expect(isRemoteConnectionLostError(Exception('Broken pipe')), isTrue);
      expect(
        isRemoteConnectionLostError(Exception('Connection reset by peer')),
        isTrue,
      );
      expect(
        isRemoteConnectionLostError(Exception('SocketException: Connection closed')),
        isTrue,
      );
      expect(isRemoteConnectionLostError(Exception('channel is closed')), isTrue);
      expect(
        isRemoteConnectionLostError(Exception('unexpected end of file')),
        isTrue,
      );
    });

    test('FTP 控制连接被回收 → 命中', () {
      expect(
        isRemoteConnectionLostError(Exception('control connection closed')),
        isTrue,
      );
    });

    test('认证失败 / 权限不足 / 文件不存在 → 不命中（重连救不了，别白等）', () {
      expect(
        isRemoteConnectionLostError(
          Exception("SMB connect failed: STATUS_LOGON_FAILURE"),
        ),
        isFalse,
      );
      expect(
        isRemoteConnectionLostError(Exception('Permission denied (publickey)')),
        isFalse,
      );
      expect(
        isRemoteConnectionLostError(Exception('Failed to list directory: not found')),
        isFalse,
      );
      expect(isRemoteConnectionLostError(null), isFalse);
      expect(isRemoteConnectionLostError(''), isFalse);
    });
  });

  group('retryWithRemoteReconnect（重建后重试一次）', () {
    test('首次成功 → 不触发重连', () async {
      var attempts = 0;
      var reconnects = 0;
      final result = await retryWithRemoteReconnect<String>(
        attempt: () async {
          attempts++;
          return 'ok';
        },
        reconnect: () async {
          reconnects++;
          return true;
        },
      );
      expect(result, 'ok');
      expect(attempts, 1);
      expect(reconnects, 0);
    });

    test('非连接类错误 → 不重连，抛出原始错误', () async {
      var reconnects = 0;
      await expectLater(
        retryWithRemoteReconnect<void>(
          attempt: () async => throw Exception('Permission denied'),
          reconnect: () async {
            reconnects++;
            return true;
          },
        ),
        throwsA(predicate((e) => e.toString().contains('Permission denied'))),
      );
      expect(reconnects, 0);
    });

    test('连接失效 + 重连成功 → 重试一次并成功', () async {
      var attempts = 0;
      var reconnects = 0;
      final retryFlags = <bool>[];
      final result = await retryWithRemoteReconnect<String>(
        attempt: () async {
          attempts++;
          if (attempts == 1) throw Exception('Session is down');
          return 'recovered';
        },
        reconnect: () async {
          reconnects++;
          return true;
        },
        onError: (_, willRetry) => retryFlags.add(willRetry),
      );
      expect(result, 'recovered');
      expect(attempts, 2, reason: '只重试一次');
      expect(reconnects, 1);
      expect(retryFlags, [true], reason: '重连成功时应告知调用方「将重试」');
    });

    test('重连被冷却拦截（reconnect 返回 false）→ 立即抛出原始错误', () async {
      var attempts = 0;
      var reconnects = 0;
      final retryFlags = <bool>[];
      await expectLater(
        retryWithRemoteReconnect<void>(
          attempt: () async {
            attempts++;
            throw Exception('Session is down');
          },
          reconnect: () async {
            reconnects++;
            return false; // 冷却窗口内
          },
          onError: (_, willRetry) => retryFlags.add(willRetry),
        ),
        throwsA(predicate((e) => e.toString().contains('Session is down'))),
      );
      expect(attempts, 1, reason: '重连没成功就不该再试');
      expect(reconnects, 1);
      expect(retryFlags, [false]);
    });

    test('重连成功但重试仍失败 → 抛出第二次的错误，不再重试', () async {
      var attempts = 0;
      var reconnects = 0;
      await expectLater(
        retryWithRemoteReconnect<void>(
          attempt: () async {
            attempts++;
            if (attempts == 1) throw Exception('Session is down');
            throw Exception('Session is down again');
          },
          reconnect: () async {
            reconnects++;
            return true;
          },
        ),
        throwsA(predicate((e) => e.toString().contains('again'))),
      );
      expect(attempts, 2);
      expect(reconnects, 1);
    });

    test('maxRetries=2 → 允许连续两次重建', () async {
      var attempts = 0;
      var reconnects = 0;
      final result = await retryWithRemoteReconnect<String>(
        attempt: () async {
          attempts++;
          if (attempts <= 2) throw Exception('Broken pipe');
          return 'ok-after-2';
        },
        reconnect: () async {
          reconnects++;
          return true;
        },
        maxRetries: 2,
      );
      expect(result, 'ok-after-2');
      expect(attempts, 3);
      expect(reconnects, 2);
    });
  });
}
