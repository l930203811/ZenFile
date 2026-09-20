import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/remote/lan_client.dart';

/// SMB 匿名登录的**候选身份序列**。
///
/// 背景（2026-09-20 论坛用户反馈）：旧实现把匿名写死成 `guest`（原生
/// SmbService 里硬编码），碰上「匿名账号不叫 guest」的 OpenWrt 固件就被
/// STATUS_LOGON_FAILURE 直接拒绝 —— 用户描述为「文件管理器能匿名进，ZenFile 不行」。
/// 现在按「最标准 → 最特殊」依次尝试；顺序错了会拖慢连接或改变既有行为，
/// 因此这里把序列钉死。
void main() {
  group('smbUsernameAttempts（SMB 登录身份候选）', () {
    test('匿名（空用户名）→ 标准空用户名优先，其后依次兜底', () {
      expect(
        smbUsernameAttempts(''),
        equals(<String>['', 'guest', 'anonymous', 'nobody']),
      );
    });

    test('匿名候选里第一位必须是空用户名（NTLMSSP anonymous 才是标准做法）', () {
      expect(smbUsernameAttempts('').first, isEmpty);
    });

    test('纯空白用户名同样按匿名处理（输入框可能只敲了空格）', () {
      expect(smbUsernameAttempts('   '), equals(kSmbAnonymousUsernames));
    });

    test('用户填了用户名 → 只试一次（不静默降级成匿名，避免"填错也能进"的安全错觉）', () {
      expect(smbUsernameAttempts('root'), equals(<String>['root']));
      expect(smbUsernameAttempts('  admin  '), equals(<String>['admin']));
    });

    test('用户填的名字恰好是匿名账号名 → 仍然只试一次', () {
      expect(smbUsernameAttempts('guest'), equals(<String>['guest']));
      expect(smbUsernameAttempts('anonymous'), equals(<String>['anonymous']));
    });

    test('候选常量覆盖 guest / anonymous / nobody 三种常见固件配置', () {
      expect(kSmbAnonymousUsernames, contains('guest'));
      expect(kSmbAnonymousUsernames, contains('anonymous'));
      expect(kSmbAnonymousUsernames, contains('nobody'));
      expect(kSmbAnonymousUsernames.length, greaterThanOrEqualTo(4));
    });
  });
}
