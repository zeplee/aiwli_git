import 'package:flutter_test/flutter_test.dart';

import 'package:aiwli_git/widgets/dialogs.dart';

/// `friendlyError` 的分类回归测试。
///
/// 这个分类器已经**两次**在同一个位置把真因带偏，两次原始串都取自真机实测：
///
///  1. 1.5.17 之前：网络分支对**裸 `'网络'`** 做子串匹配，而证书失败时引擎会
///     追加一段含「设置 → 网络安全」的提示 → 证书错误被报成"网络连接失败"，
///     排障成本全花在这上面（见 docs/14）。
///  2. 1.5.17：把证书判定提到网络之前时，证书关键字里放了**裸 `'ssl'`**，
///     而 libgit2 会把**传输层**失败也包成
///     `SSL error: syscall failure: Connection reset by peer; class=Os (2)`
///     → 网络故障被报成"HTTPS 证书校验失败"，给出的处置（导 CA / 关校验）
///     全都不对症（见 docs/15）。
///
/// 两次的根因是同一个错误做法：**对过短的裸子串做匹配**。所以这里把两类
/// 真实串直接钉住，并且强制"真因不能被分类文案吞掉"。
void main() {
  group('friendlyError：证书 vs 网络 不能互相误判', () {
    test('传输层被重置（class=Os）必须判为网络，不能判成证书', () {
      // 真机原始串：App 走了 VPN 分流的隧道，握手被 RST
      final msg = friendlyError(
        Exception(
          'push 失败: SSL error: syscall failure: Connection reset by peer; class=Os (2)',
        ),
      );
      expect(msg, contains('网络连接失败'));
      expect(msg, isNot(contains('证书校验失败')));
      // 提示必须可照做（真机验证过：直连正常、走隧道被重置）
      expect(msg, contains('分流'));
      // 真因必须保留 —— 分类文案不能把原始错误吞掉
      expect(msg, contains('Connection reset by peer'));
      expect(msg, contains('class=Os'));
    });

    test('证书失败（class=Ssl）必须判为证书', () {
      final msg = friendlyError(
        Exception(
          'push 失败: the SSL certificate is invalid; class=Ssl (16)',
        ),
      );
      expect(msg, contains('证书校验失败'));
      expect(msg, isNot(contains('网络连接失败')));
      expect(msg, contains('class=Ssl'));
    });

    test('含 certificate 字样的失败判为证书', () {
      final msg = friendlyError(
        Exception('fetch 失败: SSL certificate problem: self signed certificate'),
      );
      expect(msg, contains('证书校验失败'));
    });

    test('域名解析失败判为网络', () {
      final msg = friendlyError(
        Exception('push 失败: failed to resolve address for github.com; class=Net (12)'),
      );
      expect(msg, contains('网络连接失败'));
      expect(msg, isNot(contains('证书校验失败')));
    });

    test('握手被掐断（class=Ssl + unknown error）必须判为网络，不能判成证书', () {
      // 真机原始串：第三次推送时抓到（OpenSSL SSL_ERROR_SYSCALL 无 errno）
      final msg = friendlyError(
        Exception('push 失败: SSL error: unknown error; class=Ssl (16)'),
      );
      expect(msg, contains('网络连接失败'));
      expect(msg, isNot(contains('证书校验失败')));
      expect(msg, contains('class=Ssl')); // 真因必须保留
    });

    test('Software caused connection abort 判为网络', () {
      final msg = friendlyError(
        Exception('push 失败: failed to connect to github.com: '
            'Software caused connection abort; class=Os (2)'),
      );
      expect(msg, contains('网络连接失败'));
      expect(msg, isNot(contains('证书校验失败')));
    });
  });

  group('分类只看第一行：引擎追加的提示文案不得污染分类', () {
    // 引擎（Rust 的 transport_hint）会在原始错误后追加一段「提示：…」，
    // 里面含「网络安全」「证书校验失败」等字样。1.5.16 之前是把整段拿去匹配，
    // 于是证书错误被判成"网络连接失败"（docs/14）。现在只看第一行，
    // 从结构上隔离 —— 不管提示文案里写了什么词都不影响分类。
    const hint = '\n提示：HTTPS 证书校验失败。已自动加载 Android 系统信任库'
        '（设置 → 网络安全 可查看状态）；若仍失败，通常是自签证书，'
        '或 VPN / 代理做了 TLS 拦截。可依次尝试：1) 关掉代理重试；'
        '2) 远程改用 SSH（git@主机:用户/仓库.git，不走证书校验）；'
        '3) 确知风险时，到「设置 → 网络安全」临时打开「跳过证书校验」'
        '—— （3）会让中间人无法被发现，能用 SSH 就别用它。';

    // 注意：这里必须用 startsWith 断言分类结果 —— 因为展示文案里会附原始错误，
    // 而原始错误里就含提示原文（含「证书校验失败」四字）。
    test('网络错误 + 证书提示 → 仍判网络', () {
      final msg = friendlyError(
        Exception('push 失败: SSL error: unknown error; class=Ssl (16)$hint'),
      );
      expect(msg, startsWith('网络连接失败'));
    });

    test('证书错误 + 证书提示 → 仍判证书', () {
      final msg = friendlyError(
        Exception('push 失败: the SSL certificate is invalid; class=Ssl (16)$hint'),
      );
      expect(msg, startsWith('HTTPS 证书校验失败'));
    });
  });

  group('friendlyError：其它类别不被网络/证书抢走', () {
    test('认证失败判为认证（含 401/403）', () {
      expect(
        friendlyError(Exception('push 失败: 401 Unauthorized; class=Http (34)')),
        contains('远程认证失败'),
      );
      expect(
        friendlyError(Exception('authentication required but no callback set')),
        contains('远程认证失败'),
      );
    });

    test('非快进拒绝判为推送被拒，不是网络', () {
      final msg = friendlyError(
        Exception('push 失败: cannot push because a reference that you are trying '
            'to update does not have the expected value; class=Reference (4)'),
      );
      expect(msg, contains('推送被拒绝'));
      expect(msg, isNot(contains('网络连接失败')));
    });

    test('存储权限被拒判为权限类', () {
      final msg = friendlyError(
        Exception('读取 HEAD 失败: /storage/emulated/0/x/.git: Permission denied; '
            'class=Os (2); code=Locked (-14)'),
      );
      expect(msg, contains('所有文件访问'));
    });

    test('无法识别时原样返回，不吞真因', () {
      const raw = 'some brand new engine failure nobody classified yet';
      expect(friendlyError(Exception(raw)), raw);
    });
  });

  group('rawTail：原始错误摘要', () {
    test('长错误被截断但仍可辨认', () {
      final long = 'x' * 500;
      final t = rawTail(long);
      expect(t, startsWith('（原始：'));
      expect(t, contains('…'));
      expect(t.length, lessThan(280));
    });

    test('空错误不产出尾巴', () {
      expect(rawTail('   '), isEmpty);
    });
  });
}