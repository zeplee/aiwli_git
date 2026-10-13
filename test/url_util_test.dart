import 'package:flutter_test/flutter_test.dart';
import 'package:aiwli_git/core/url_util.dart';

void main() {
  group('hostFromUrl', () {
    test('https URLs', () {
      expect(hostFromUrl('https://github.com/user/repo.git'), 'github.com');
      expect(
        hostFromUrl('https://codeup.aliyun.com/org/repo.git'),
        'codeup.aliyun.com',
      );
      expect(hostFromUrl('HTTPS://GitHub.COM/x'), 'github.com');
    });

    test('ssh scheme URLs', () {
      expect(
        hostFromUrl('ssh://git@github.com:22/user/repo.git'),
        'github.com',
      );
      expect(hostFromUrl('ssh://gitlab.internal/team/repo'), 'gitlab.internal');
    });

    test('SCP style git@host:path', () {
      expect(hostFromUrl('git@github.com:user/repo.git'), 'github.com');
      expect(
        hostFromUrl('me@codeup.aliyun.com:org/repo.git'),
        'codeup.aliyun.com',
      );
    });

    test('bare host:path', () {
      expect(hostFromUrl('github.com:user/repo.git'), 'github.com');
    });

    test('junk returns null', () {
      expect(hostFromUrl(''), isNull);
      expect(hostFromUrl('   '), isNull);
      expect(hostFromUrl('not a url'), isNull);
    });

    test('lowercases the host', () {
      expect(
        hostFromUrl('ssh://git@GitLab.Example.COM/x'),
        'gitlab.example.com',
      );
    });
  });

  group('defaultHostFor', () {
    test('known providers', () {
      expect(defaultHostFor('github'), 'github.com');
      expect(defaultHostFor('codeup'), 'codeup.aliyun.com');
      expect(defaultHostFor('gitlab'), 'gitlab.com');
      expect(defaultHostFor('generic'), isNull);
    });
  });
}
