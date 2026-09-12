/// `VaultService`（保险箱解锁门禁）回归测试
///
/// 背景：旧版 V1/V2/V3 自研沙盒加密已**彻底移除**，`VaultService` 从
/// 1566 行瘦身为纯门禁服务，不再参与任何加解密。因此本文件只覆盖门禁行为：
/// - 设置 / 校验解锁密码
/// - 修改解锁密码（**瞬时**，不再重新加密任何文件）
/// - 旧版升级用户的「重设解锁密码」判定
///
/// ⚠️ 历史坑：门禁哈希必须保持 `sha256(password + salt)` 并使用
/// `vault_salt` / `vault_password_hash` 两个键，老用户原密码才能直接解锁。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/services/vault_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('解锁密码门禁', () {
    test('未设置时为 false，设置后为 true', () async {
      expect(await VaultService.isPasswordSet(), isFalse);
      await VaultService.setPassword('abcd');
      expect(await VaultService.isPasswordSet(), isTrue);
    });

    test('校验：正确通过、错误拒绝', () async {
      const pw = 'correct horse battery staple';
      await VaultService.setPassword(pw);
      expect(await VaultService.verifyPassword(pw), isTrue);
      expect(await VaultService.verifyPassword('wrong'), isFalse);
    });

    test('未设置密码时任何输入都不通过', () async {
      expect(await VaultService.verifyPassword('anything'), isFalse);
    });

    test('修改密码：旧密码失效、新密码生效，且旧密码错误时返回 false', () async {
      const oldPw = 'old-pw-123';
      const newPw = 'new-pw-456';
      await VaultService.setPassword(oldPw);

      // 旧密码错误 → 拒绝修改
      expect(await VaultService.changePassword('bad-pw', newPw), isFalse);
      expect(await VaultService.verifyPassword(oldPw), isTrue);

      expect(await VaultService.changePassword(oldPw, newPw), isTrue);
      expect(await VaultService.verifyPassword(oldPw), isFalse);
      expect(await VaultService.verifyPassword(newPw), isTrue);
    });

    test('改密不依赖任何文件系统操作（门禁与加密已完全解耦）', () async {
      // 旧实现会逐条重新加密已隐藏文件；现在只写一次 SharedPreferences。
      // 这里断言改密在「没有任何文件/挂载点」的情况下也能瞬时成功。
      await VaultService.setPassword('pw-0000');
      expect(await VaultService.changePassword('pw-0000', 'pw-1111'), isTrue);
      expect(await VaultService.verifyPassword('pw-1111'), isTrue);
    });
  });

  group('旧版升级用户判定', () {
    test('存在旧版 V2 校验令牌且无门禁凭据 → 需要重设', () async {
      SharedPreferences.setMockInitialValues({
        'vault_v2_pwcheck': 'legacy-token',
      });
      expect(await VaultService.isPasswordSet(), isFalse);
      expect(await VaultService.needsUnlockPasswordReset(), isTrue);
    });

    test('已设置门禁凭据 → 不需要重设', () async {
      await VaultService.setPassword('abcd');
      expect(await VaultService.needsUnlockPasswordReset(), isFalse);
    });

    test('全新用户（无任何旧键）→ 不需要「重设」，走首次设置流程', () async {
      expect(await VaultService.needsUnlockPasswordReset(), isFalse);
    });
  });
}
