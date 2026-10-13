import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:aiwli_git/core/hosting_api.dart';
import 'package:aiwli_git/core/url_util.dart';

void main() {
  group('githubSlugFromUrl', () {
    test('parses the usual remote URL shapes', () {
      expect(githubSlugFromUrl('https://github.com/alice/demo.git'), 'alice/demo');
      expect(githubSlugFromUrl('https://github.com/alice/demo'), 'alice/demo');
      expect(githubSlugFromUrl('git@github.com:alice/demo.git'), 'alice/demo');
      expect(githubSlugFromUrl('ssh://git@github.com/alice/demo'), 'alice/demo');
      expect(githubSlugFromUrl('github.com:alice/demo.git'), 'alice/demo');
    });

    test('rejects non-github hosts and malformed paths', () {
      expect(githubSlugFromUrl('https://gitlab.com/a/b.git'), isNull);
      expect(githubSlugFromUrl('git@codeup.aliyun.com:a/b.git'), isNull);
      expect(githubSlugFromUrl('https://github.com/alice'), isNull);
      expect(githubSlugFromUrl(''), isNull);
      expect(githubSlugFromUrl('not a url'), isNull);
    });
  });

  group('gh URI builders', () {
    test('issues list carries paging and state', () {
      final u = ghIssuesUri('a/b', page: 2, perPage: 300, state: 'closed');
      expect(u.host, 'api.github.com');
      expect(u.path, '/repos/a/b/issues');
      expect(u.queryParameters['page'], '2');
      expect(u.queryParameters['state'], 'closed');
      // per_page is clamped to the GitHub maximum.
      expect(u.queryParameters['per_page'], '100');
    });

    test('tree keeps slash-branches in the path and recurses', () {
      final u = ghTreeUri('a/b', 'feature/x');
      expect(u.path, '/repos/a/b/git/trees/feature/x');
      expect(u.queryParameters['recursive'], '1');
      expect(ghTreeUri('a/b', 'HEAD', recursive: false).queryParameters,
          isEmpty);
    });

    test('content strips a leading slash and keeps ref', () {
      final u = ghContentUri('a/b', '/README.md', ref: 'dev');
      expect(u.path, '/repos/a/b/contents/README.md');
      expect(u.queryParameters['ref'], 'dev');
    });

    test('search encodes the raw query', () {
      final u = ghSearchReposUri('flutter git', perPage: 5);
      expect(u.path, '/search/repositories');
      expect(u.queryParameters['q'], 'flutter git');
      expect(u.queryParameters['per_page'], '5');
    });

    test('bad slug is rejected everywhere', () {
      expect(() => ghRepoUri('no-slash'), throwsA(isA<HostingException>()));
      expect(() => ghIssuesUri('a/b extra'), throwsA(isA<HostingException>()));
    });
  });

  group('body builders', () {
    test('issue create keeps optional fields out', () {
      expect(ghIssueCreateBody('t'), '{"title":"t"}');
      final j = jsonDecode(
        ghIssueCreateBody('t', body: 'b', labels: ['x', 'y']),
      ) as Map;
      expect(j['title'], 't');
      expect(j['body'], 'b');
      expect(j['labels'], ['x', 'y']);
    });

    test('patch bodies reject empty payloads', () {
      expect(() => ghIssuePatchBody(), throwsA(isA<HostingException>()));
      expect(() => ghPrPatchBody(), throwsA(isA<HostingException>()));
    });

    test('pr merge validates the method', () {
      expect(jsonDecode(ghPrMergeBody(method: 'squash'))['merge_method'],
          'squash');
      expect(
        () => ghPrMergeBody(method: 'fast-forward'),
        throwsA(isA<HostingException>()),
      );
      // Empty optional fields must not leak into the payload.
      expect(jsonDecode(ghPrMergeBody())['commit_title'], isNull);
    });
  });

  group('ghCheck', () {
    HostingException err(void Function() f) {
      try {
        f();
      } on HostingException catch (e) {
        return e;
      }
      fail('expected HostingException');
    }

    test('2xx passes', () {
      ghCheck(http.Response('{}', 200), 'x');
      ghCheck(http.Response('', 204), 'x');
    });

    test('401 names the token fix', () {
      final e = err(
        () => ghCheck(http.Response('{"message":"Bad credentials"}', 401), 'x'),
      );
      expect(e.message, contains('令牌'));
    });

    test('403 with exhausted quota reports the reset time', () {
      final e = err(
        () => ghCheck(
          http.Response(
            '{"message":"API rate limit exceeded"}',
            403,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-reset': '1790000000',
            },
          ),
          'x',
        ),
      );
      expect(e.message, contains('速率'));
      expect(e.message, contains('2026'));
    });

    test('403 without quota headers is a plain refusal', () {
      final e = err(
        () => ghCheck(http.Response('{"message":"forbidden"}', 403), 'x'),
      );
      expect(e.message, isNot(contains('速率')));
      expect(e.message, contains('forbidden'));
    });

    test('404 / 405 / 409 / 422 get specific messages', () {
      expect(
        err(() => ghCheck(http.Response('{}', 404), 'x')).message,
        contains('404'),
      );
      expect(
        err(() => ghCheck(http.Response('{}', 405), 'x')).message,
        contains('合并'),
      );
      expect(
        err(() => ghCheck(http.Response('{}', 409), 'x')).message,
        contains('冲突'),
      );
      expect(
        err(() => ghCheck(http.Response('{}', 422), 'x')).message,
        contains('校验'),
      );
    });
  });

  group('parsers', () {
    test('parseGhIssues filters PRs out of the issue list', () {
      const body = '''
[
  {"number": 1, "title": "real issue", "state": "open", "user": {"login": "u"}},
  {"number": 2, "title": "a pr", "state": "open", "pull_request": {"url": "x"}}
]
''';
      final issues = parseGhIssues(body);
      expect(issues.length, 1);
      expect(issues[0]['number'], 1);
      expect(issues[0]['isPr'], isFalse);
    });

    test('parseGhIssue keeps PR fields when explicitly allowed', () {
      final j = jsonDecode('''
{"number": 2, "title": "a pr", "state": "open", "pull_request": {"url": "x"}}
''') as Map<String, dynamic>;
      final issue = parseGhIssue(j, includePullRequests: true);
      expect(issue, isNotNull);
      expect(issue!['isPr'], isTrue);
      expect(parseGhIssue(j), isNull);
    });

    test('parseGhPr maps head/base and counters', () {
      final pr = parseGhPr(
        jsonDecode('''
{
  "number": 7, "title": "feat: x", "state": "open", "draft": true,
  "merged": false, "user": {"login": "dev"},
  "head": {"ref": "feat", "sha": "abc123"},
  "base": {"ref": "main"},
  "mergeable": null, "changed_files": 3, "additions": 10, "deletions": 2,
  "body": "long body"
}
''') as Map<String, dynamic>,
      )!;
      expect(pr['headRef'], 'feat');
      expect(pr['headSha'], 'abc123');
      expect(pr['baseRef'], 'main');
      expect(pr['changedFiles'], 3);
      expect(pr['draft'], isTrue);
    });

    test('parseGhReleases keeps asset download urls', () {
      const body = '''
[{"tag_name": "v1.0", "name": "First", "prerelease": false,
  "assets": [{"name": "app.apk", "size": 9, "browser_download_url": "https://x/app.apk"}]}]
''';
      final rel = parseGhReleases(body);
      expect(rel.length, 1);
      expect(rel[0]['tagName'], 'v1.0');
      final assets = rel[0]['assets'] as List;
      expect(assets.single['downloadUrl'], 'https://x/app.apk');
    });

    test('parseGhTree caps entries and surfaces both truncation flags', () {
      const body = '''
{"sha": "s", "truncated": true, "tree": [
  {"path": "a", "type": "blob", "size": 1},
  {"path": "b", "type": "tree"},
  {"path": "c", "type": "blob", "size": 3}
]}
''';
      final t = parseGhTree(body, maxEntries: 2);
      expect((t['entries'] as List).length, 2);
      expect(t['clientOverflow'], 1);
      expect(t['serverTruncated'], isTrue);
    });

    test('parseGhFileContent decodes base64 text', () {
      final content = base64.encode(utf8.encode('# Hello 中文'));
      final f = parseGhFileContent(
        jsonEncode({
          'name': 'README.md',
          'path': 'README.md',
          'size': content.length,
          'encoding': 'base64',
          'content': content,
          'html_url': 'https://github.com/a/b/blob/main/README.md',
        }),
      )!;
      expect(f['text'], '# Hello 中文');
      expect(f['binary'], isFalse);
      expect(f['tooLargeForInline'], isFalse);
    });

    test('parseGhFileContent flags binary and huge files', () {
      final bin = base64.encode([0x50, 0x4b, 0x00, 0x01]);
      expect(
        parseGhFileContent(
          jsonEncode({'name': 'x.zip', 'encoding': 'base64', 'content': bin}),
        )!['binary'],
        isTrue,
      );
      expect(
        parseGhFileContent(
          jsonEncode({'name': 'big.bin', 'encoding': 'none', 'content': ''}),
        )!['tooLargeForInline'],
        isTrue,
      );
    });

    test('parseGhFileContent rejects directories with guidance', () {
      expect(
        () => parseGhFileContent('[]'),
        throwsA(
          isA<HostingException>().having(
            (e) => e.message,
            'msg',
            contains('gh_tree_list'),
          ),
        ),
      );
    });

    test('parseGhSearch maps compact items', () {
      const body = '''
{"total_count": 42, "items": [
  {"full_name": "a/b", "description": "d", "stargazers_count": 5,
   "default_branch": "main", "updated_at": "2026-01-01T00:00:00Z"}]}
''';
      final s = parseGhSearch(body)!;
      expect(s['totalCount'], 42);
      final item = (s['items'] as List).single as Map;
      expect(item['fullName'], 'a/b');
      expect(item['stars'], 5);
    });

    test('parseGhRepoDetail maps counters', () {
      final d = parseGhRepoDetail(
        jsonDecode('''
{"full_name": "a/b", "private": true, "fork": false, "default_branch": "main",
 "stargazers_count": 1, "forks_count": 2, "open_issues_count": 3,
 "clone_url": "https://github.com/a/b.git"}
''') as Map<String, dynamic>,
      )!;
      expect(d['defaultBranch'], 'main');
      expect(d['openIssues'], 3);
      expect(d['httpsUrl'], 'https://github.com/a/b.git');
    });
  });
}
