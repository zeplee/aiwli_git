import 'package:flutter_test/flutter_test.dart';

import 'package:aiwli_git/pages/publish_remote.dart';

void main() {
  group('validRepoName（发布用远程仓库名）', () {
    test('常规名合法', () {
      expect(validRepoName('demo'), isTrue);
      expect(validRepoName('my_app.v2'), isTrue);
      expect(validRepoName('app-1.0'), isTrue);
    });
    test('空名与非法字符拒绝', () {
      expect(validRepoName(''), isFalse);
      expect(validRepoName(' '), isFalse);
      expect(validRepoName('a/b'), isFalse); // 含路径分隔
      expect(validRepoName('a b'), isFalse); // 空格
      expect(validRepoName('中文名'), isFalse); // 非ASCII
      expect(validRepoName('a?b'), isFalse); // 注入字符
      expect(validRepoName('..'), isFalse); // 点段（防路径穿越）
    });
  });
}
