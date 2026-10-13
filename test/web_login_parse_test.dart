// 网页登录自动绑定的纯函数测试（2026-10-04）。
// 覆盖 GitHub 令牌抓取、云效组织 ID 提取、剪贴板兜底判定三条正则/规则路径。
import 'package:flutter_test/flutter_test.dart';
import 'package:aiwli_git/pages/web_login_page.dart';

void main() {
  group('extractGithubToken', () {
    test('抓经典 ghp_ 令牌', () {
      final t = List.filled(36, 'a').join();
      expect(
        extractGithubToken('Make sure to copy your token: ghp_$t now!'),
        'ghp_$t',
      );
    });
    test('抓细粒度 github_pat_ 令牌', () {
      final t = List.filled(70, 'x').join();
      expect(extractGithubToken('token github_pat_$t end'), 'github_pat_$t');
    });
    test('页面没有令牌返回 null', () {
      expect(extractGithubToken('no tokens here'), isNull);
    });
    test('不会把 32 位 ghp_ 截断匹配', () {
      expect(extractGithubToken('ghp_${List.filled(20, "b").join()}'), isNull);
    });
  });

  group('extractAliyunOrg', () {
    test('devops.aliyun.com/{orgId}/…', () {
      expect(
        extractAliyunOrg('https://devops.aliyun.com/6666666/all/projects'),
        '6666666',
      );
    });
    test('codeup.aliyun.com/{orgId}（无尾斜杠）', () {
      expect(extractAliyunOrg('https://codeup.aliyun.com/12345678'), '12345678');
    });
    test('登录页（无数字段）返回 null', () {
      expect(extractAliyunOrg('https://login.aliyun.com/login.htm'), isNull);
      expect(extractAliyunOrg('https://devops.aliyun.com/'), isNull);
    });
    test('非 aliyun 域一律拒绝', () {
      expect(
        extractAliyunOrg('https://evil.example.com/devops.aliyun.com/6666666'),
        isNull,
      );
    });
  });

  group('plausibleToken', () {
    test('接受常规令牌', () {
      expect(plausibleToken('abcdef1234567890'), isTrue);
      expect(plausibleToken('  abcdef1234567890 \n'), isTrue); // 去空白后接受
    });
    test('拒绝 URL / 空白 / 过短 / 空值', () {
      expect(plausibleToken('https://github.com/xxx'), isFalse);
      expect(plausibleToken('ab cd 1234'), isFalse);
      expect(plausibleToken('1234567'), isFalse);
      expect(plausibleToken(''), isFalse);
      expect(plausibleToken(null), isFalse);
    });
  });
}
