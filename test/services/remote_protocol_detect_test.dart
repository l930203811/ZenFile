import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/network_connections_service.dart';

/// 连接类型识别（`NetworkConnectionModel.type`）。
///
/// ⚠️ 这个字段**取值不统一**，是踩过坑的地方：
///  - FTP / SFTP / WebDav / SAF 存固定英文常量；
///  - **SMB 存的是本地化标签**（中文「局域网/SMB」、英文「LAN/SMB」、繁体
///    「區域網/SMB」），历史版本还存过 `SMB` / `Samba` / `CIFS`。
/// 旧代码用 `type == 'FTP'` 这类等值比较，换语言 / 编辑老连接时会失配并抛
/// `ArgumentError('Unsupported connection type')` —— 表现为整条连接打不开。
void main() {
  group('detectRemoteProtocolKind（协议识别）', () {
    test('固定英文常量', () {
      expect(detectRemoteProtocolKind('FTP'), RemoteProtocolKind.ftp);
      expect(detectRemoteProtocolKind('WebDav'), RemoteProtocolKind.webdav);
      expect(detectRemoteProtocolKind('saf'), RemoteProtocolKind.saf);
    });

    test('SFTP 必须优先于 FTP 命中（sftp 本身含子串 ftp）', () {
      expect(detectRemoteProtocolKind('SFTP'), RemoteProtocolKind.sftp);
      expect(detectRemoteProtocolKind('sftp'), RemoteProtocolKind.sftp);
    });

    test('SMB 的本地化标签（三种语言）', () {
      expect(detectRemoteProtocolKind('局域网/SMB'), RemoteProtocolKind.smb);
      expect(detectRemoteProtocolKind('LAN/SMB'), RemoteProtocolKind.smb);
      expect(detectRemoteProtocolKind('區域網/SMB'), RemoteProtocolKind.smb);
    });

    test('SMB 的历史值（v1.x 存过 Samba / CIFS）', () {
      expect(detectRemoteProtocolKind('SMB'), RemoteProtocolKind.smb);
      expect(detectRemoteProtocolKind('Samba'), RemoteProtocolKind.smb);
      expect(detectRemoteProtocolKind('CIFS'), RemoteProtocolKind.smb);
      expect(detectRemoteProtocolKind('smb'), RemoteProtocolKind.smb);
    });

    test('WebDAV 的中文标签（WEB共享）', () {
      expect(detectRemoteProtocolKind('WEB共享'), RemoteProtocolKind.webdav);
      expect(detectRemoteProtocolKind('webdav'), RemoteProtocolKind.webdav);
    });

    test('SAF 目录（向导里叫 SAF Folder）', () {
      expect(detectRemoteProtocolKind('SAF Folder'), RemoteProtocolKind.saf);
    });

    test('未知 / 空值 → null（交给调用方抛 Unsupported connection type）', () {
      expect(detectRemoteProtocolKind(''), isNull);
      expect(detectRemoteProtocolKind(null), isNull);
      expect(detectRemoteProtocolKind('unknown-proto'), isNull);
    });
  });

  group('isSmbType（与带类型分支的旧调用点保持一致）', () {
    test('本地化标签 / 历史值 / 标准值都命中', () {
      for (final t in ['局域网/SMB', 'LAN/SMB', '區域網/SMB', 'SMB', 'Samba', 'CIFS']) {
        expect(NetworkConnectionsService.isSmbType(t), isTrue, reason: t);
      }
    });

    test('其它协议不受影响', () {
      for (final t in ['FTP', 'SFTP', 'WebDav', 'saf', '']) {
        expect(NetworkConnectionsService.isSmbType(t), isFalse, reason: t);
      }
    });
  });
}
