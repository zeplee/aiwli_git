import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:aiwli_git/pages/github_panel.dart';

/// Offline MockClient: dispatches canned GitHub API responses by path so the
/// panel's widget tests never touch the network or the engine.
http.Client _mock() => MockClient((req) async {
  final p = req.url.path;
  final isDiff = req.headers.entries.any(
    (e) =>
        e.key.toLowerCase() == 'accept' &&
        e.value == 'application/vnd.github.diff',
  );
  if (p == '/repos/a/b') {
    return http.Response(
      jsonEncode({
        'full_name': 'a/b',
        'description': 'demo repo',
        'private': true,
        'fork': false,
        'default_branch': 'main',
        'stargazers_count': 5,
        'forks_count': 1,
        'open_issues_count': 2,
        'updated_at': '2026-10-01T10:00:00Z',
        'clone_url': 'https://github.com/a/b.git',
        'ssh_url': 'git@github.com:a/b.git',
      }),
      200,
    );
  }
  if (p.startsWith('/repos/a/b/git/trees/')) {
    return http.Response(
      jsonEncode({
        'sha': 's',
        'truncated': false,
        'tree': [
          {'path': 'lib', 'type': 'tree'},
          {'path': 'README.md', 'type': 'blob', 'size': 12},
        ],
      }),
      200,
    );
  }
  if (p == '/repos/a/b/issues' && req.method == 'POST') {
    return http.Response(jsonEncode({'number': 9, 'title': 't'}), 201);
  }
  if (p == '/repos/a/b/issues') {
    return http.Response(
      jsonEncode([
        {
          'number': 1,
          'title': 'real issue',
          'state': 'open',
          'user': {'login': 'u'},
          'labels': [
            {'name': 'bug'},
          ],
          'updated_at': '2026-10-01T10:00:00Z',
        },
        {
          'number': 2,
          'title': 'a pr',
          'state': 'open',
          'pull_request': {'url': 'x'},
        },
      ]),
      200,
    );
  }
  if (p == '/repos/a/b/issues/1') {
    return http.Response(
      jsonEncode({
        'number': 1,
        'title': 'real issue',
        'state': 'open',
        'user': {'login': 'u'},
        'body': 'issue body',
        'updated_at': '2026-10-01T10:00:00Z',
      }),
      200,
    );
  }
  if (p == '/repos/a/b/issues/1/comments') {
    if (req.method == 'POST') {
      return http.Response(jsonEncode({'id': 5}), 201);
    }
    return http.Response(
      jsonEncode([
        {
          'id': 5,
          'user': {'login': 'v'},
          'created_at': '2026-10-02T10:00:00Z',
          'body': 'hi',
        },
      ]),
      200,
    );
  }
  if (p == '/repos/a/b/pulls') {
    return http.Response(
      jsonEncode([
        {
          'number': 7,
          'title': 'feat: x',
          'state': 'open',
          'draft': false,
          'merged': false,
          'user': {'login': 'dev'},
          'head': {
            'ref': 'feat',
            'sha': 'abc',
          },
          'base': {'ref': 'main'},
          'changed_files': 2,
        },
      ]),
      200,
    );
  }
  if (p == '/repos/a/b/pulls/7') {
    if (isDiff) return http.Response('diff --git a/x b/x', 200);
    return http.Response(
      jsonEncode({
        'number': 7,
        'title': 'feat: x',
        'state': 'open',
        'draft': false,
        'merged': false,
        'user': {'login': 'dev'},
        'head': {
          'ref': 'feat',
          'sha': 'abc',
        },
        'base': {'ref': 'main'},
        'mergeable': true,
        'changed_files': 2,
        'additions': 5,
        'deletions': 1,
        'body': 'pr body',
      }),
      200,
    );
  }
  if (p == '/repos/a/b/pulls/7/merge') {
    return http.Response(jsonEncode({'merged': true, 'sha': 'def'}), 200);
  }
  if (p == '/repos/a/b/releases') {
    return http.Response(
      jsonEncode([
        {
          'tag_name': 'v1.0',
          'name': 'First',
          'prerelease': false,
          'published_at': '2026-10-01T10:00:00Z',
          'assets': [
            {
              'name': 'app.apk',
              'size': 9,
              'browser_download_url': 'https://x/app.apk',
            },
          ],
          'body': 'release notes',
        },
      ]),
      200,
    );
  }
  if (p.startsWith('/repos/a/b/contents/')) {
    return http.Response(
      jsonEncode({
        'name': 'README.md',
        'path': 'README.md',
        'size': 12,
        'encoding': 'base64',
        'content': base64.encode(utf8.encode('# hello')),
        'html_url': 'https://github.com/a/b/blob/main/README.md',
      }),
      200,
    );
  }
  return http.Response('{"message":"unexpected: ${req.url}"}', 404);
});

const _account = {'label': 't', 'provider': 'github', 'pass': 'tok'};

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _pumpPanel(
  WidgetTester tester, {
  Map<String, Object?>? account = _account,
  http.Client? client,
}) async {
  await tester.pumpWidget(
    _wrap(
      GithubSheet(
        repoPath: '/x',
        initialRepo: 'a/b',
        accountOverride: account,
        httpClient: client ?? _mock(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('初始渲染:概览数据与五个分区', (tester) async {
    await _pumpPanel(tester);
    expect(find.text('概览'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('Issues'), findsOneWidget);
    expect(find.text('PR'), findsOneWidget);
    expect(find.text('发布'), findsOneWidget);
    expect(find.text('a/b'), findsWidgets); // slug 输入框 + 概览标题
    expect(find.text('demo repo'), findsOneWidget);
    expect(find.text('私有'), findsOneWidget);
  });

  testWidgets('Issues 列表渲染并过滤 PR 条目', (tester) async {
    await _pumpPanel(tester);
    await tester.tap(find.text('Issues'));
    await tester.pumpAndSettle();
    expect(find.text('real issue'), findsOneWidget);
    expect(find.textContaining('bug'), findsOneWidget);
    expect(find.text('a pr'), findsNothing);
  });

  testWidgets('Issue 详情:正文与评论', (tester) async {
    await _pumpPanel(tester);
    await tester.tap(find.text('Issues'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('real issue'));
    await tester.pumpAndSettle();
    expect(find.text('issue body'), findsOneWidget);
    expect(find.text('评论 1'), findsOneWidget);
    expect(find.text('hi'), findsOneWidget);
  });

  testWidgets('PR 列表与详情(含 diff)', (tester) async {
    await _pumpPanel(tester);
    await tester.tap(find.text('PR'));
    await tester.pumpAndSettle();
    expect(find.text('feat: x'), findsOneWidget);
    await tester.tap(find.text('feat: x'));
    await tester.pumpAndSettle();
    expect(find.text('pr body'), findsOneWidget);
    expect(find.textContaining('diff --git'), findsOneWidget);
    expect(find.text('合并'), findsWidgets); // 操作按钮
  });

  testWidgets('发布列表渲染 tag 与附件', (tester) async {
    await _pumpPanel(tester);
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    expect(find.text('v1.0 · First'), findsOneWidget);
  });

  testWidgets('文件树:点文件打开内容查看', (tester) async {
    await _pumpPanel(tester);
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(find.text('README.md'), findsOneWidget);
    await tester.tap(find.text('README.md'));
    await tester.pumpAndSettle();
    expect(find.text('# hello'), findsOneWidget);
  });

  testWidgets('无令牌账号:分区报错并给出授权引导', (tester) async {
    await _pumpPanel(tester, account: {'label': 't', 'provider': 'github'});
    await tester.pumpAndSettle();
    expect(find.textContaining('访问令牌'), findsWidgets);
  });
}
