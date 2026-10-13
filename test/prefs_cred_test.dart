import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aiwli_git/core/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Prefs credentials (plaintext fallback path in tests)', () {
    // In `flutter test` the Android MethodChannel is absent, so SecureStore
    // returns null and Prefs stores the global credential as plaintext —
    // the same legacy path used to migrate old installs. The account-match
    // logic itself is covered by url_util_test + the device-side flows.
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('gitdeck_prefs_test_');
      Prefs.instance.setDir(tmp.path);
    });
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('set + get + clear round trip', () async {
      final p = Prefs.instance;
      expect(await p.credentials(), isNull);
      await p.setCredentials({'user': 'u', 'pass': 't'});
      expect(await p.credentials(), {'user': 'u', 'pass': 't'});
      await p.setCredentials(null);
      expect(await p.credentials(), isNull);
    });

    test('credentialsForUrl falls back to the global credential', () async {
      final p = Prefs.instance;
      await p.setCredentials({'user': 'g', 'pass': 't'});
      // No accounts bound → host match impossible → global fallback.
      final cred = await p.credentialsForUrl('https://github.com/a/b.git');
      expect(cred, {'user': 'g', 'pass': 't'});
    });

    test('lastRepo / recents round trip', () async {
      final p = Prefs.instance;
      await p.setLastRepo('/tmp/repo-a');
      expect(await p.lastRepo(), '/tmp/repo-a');
      expect(await p.recents(), ['/tmp/repo-a']);
      await p.setLastRepo('/tmp/repo-b');
      await p.setLastRepo('/tmp/repo-a');
      // dedup + most-recent-first
      expect(await p.recents(), ['/tmp/repo-a', '/tmp/repo-b']);
    });
  });
}
