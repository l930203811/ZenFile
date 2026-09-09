/// 挂载点「用当前保险箱密码重建」回归测试
///
/// 历史 bug：`CryptMountPoint.copyWith(password: x)` 只传 password 时，
/// 旧实现执行 `config!.copyWith(...)`，而 config 为 null → 抛
/// `Null check operator used on a null value`。
/// 后果：只要存在任一加密挂载点，保险箱导入 / 原地加密列表加载全部失败。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';

void main() {
  group('CryptMountPoint.copyWith(password:)', () {
    test('仅传 password 不得抛异常，且密码被覆盖', () {
      final mount = CryptMountPoint(
        physicalPath: '/storage/emulated/0/crypt',
        config: const RcloneCryptConfig(password: 'old-pass'),
      );

      // 修复前这里会抛 Null check 异常
      final copy = mount.copyWith(password: 'new-pass');

      expect(copy.config.password, 'new-pass');
      expect(copy.physicalPath, mount.physicalPath);
      expect(copy.isSandboxMode, mount.isSandboxMode);
    });

    test('不传 password 时保留原 config', () {
      final mount = CryptMountPoint(
        physicalPath: '/storage/emulated/0/crypt',
        config: const RcloneCryptConfig(password: 'keep-me'),
      );
      final copy = mount.copyWith();
      expect(copy.config.password, 'keep-me');
    });
  });
}
