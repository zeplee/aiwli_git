import 'package:flutter_test/flutter_test.dart';

import 'package:aiwli_git/widgets/dialogs.dart';

void main() {
  group('isStorageDeniedError / friendlyError 存储权限识别', () {
    // 实机原文（v1.5.6 更新安装后 app-op 被重置时的报错）
    const real =
        "读取 HEAD 失败: failed open - '/storage/emulated/0/Projects/"
        "aiwli_cast/.git/HEAD' is locked: Permission denied; "
        "class=Os (2); code=Locked (-14)";

    test('识别实机报错', () {
      expect(isStorageDeniedError(real), isTrue);
      expect(friendlyError(real), contains('所有文件访问'));
      expect(friendlyError(real), contains('存储访问权限'));
    });

    test('识别 sdcard 路径与 code=Locked 变体', () {
      expect(
        isStorageDeniedError('open /sdcard/x/.git/HEAD: Permission denied'),
        isTrue,
      );
      expect(
        isStorageDeniedError(
          'failed open - x; Permission denied; code=Locked (-14)',
        ),
        isTrue,
      );
      // 只有 code=Locked 而没有 Permission denied 时不能当成权限问题：
      // 那可能是真正的引用锁冲突，误报会把用户引到错误的设置页
      expect(
        isStorageDeniedError('failed to lock ref refs/heads/main; code=Locked (-14)'),
        isFalse,
      );
    });

    test('不误判其他错误', () {
      expect(isStorageDeniedError('network timeout'), isFalse);
      expect(isStorageDeniedError('没有设置上游'), isFalse);
      // 远程 403 不该被当成存储权限问题
      final auth = friendlyError('auth failed: 403');
      expect(auth, contains('认证失败'));
    });
  });
}
