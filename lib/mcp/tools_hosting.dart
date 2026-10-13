/// Hosting-platform MCP tools — GitHub MVP.
///
/// Boundary: complements the git-engine tools, never replaces them. These
/// cover what libgit2 cannot do — issues, pull requests, releases, and
/// browsing a repository without cloning it. File sync stays on the engine.
/// Handlers mirror tools.dart style: friendly Chinese text or compact JSON.
library;

import 'dart:convert';

import '../core/hosting_api.dart';
import '../core/prefs.dart';
import '../engine/ffi.dart';
import 'tool_base.dart';

const JsonEncoder _enc = JsonEncoder.withIndent('  ');

/// Resolves the GitHub account for a tool call: explicit `accountLabel`,
/// else the first github-provider account that carries a token.
Future<Map<String, Object?>> _ghAccount(Map<String, dynamic> a) async {
  final label = ((a['accountLabel'] as String?) ?? '').trim();
  final all = (await Prefs.instance.accounts()).cast<Map<String, Object?>>();
  Map<String, Object?>? acc;
  if (label.isNotEmpty) {
    for (final x in all) {
      if ((x['label'] as String?) == label) acc = x;
    }
    if (acc == null) {
      throw HostingException('未找到账号「$label」（先用 git_accounts 查看可用账号）');
    }
  } else {
    for (final x in all) {
      if (accountProvider(x) == 'github' && accountToken(x) != null) {
        acc = x;
        break;
      }
    }
    if (acc == null) {
      // Fall back to a github account without a token so the error can name it.
      for (final x in all) {
        if (accountProvider(x) == 'github') {
          acc = x;
          break;
        }
      }
    }
    if (acc == null) {
      throw HostingException(
        '没有 GitHub 账号：请到「设置 → 账号管理」添加并授权 GitHub，或显式传 accountLabel',
      );
    }
  }
  if (accountProvider(acc) != 'github') {
    throw HostingException(
      '平台工具目前仅支持 GitHub，「${accountLabel(acc)}」是 ${accountProvider(acc)} 账号',
    );
  }
  if (accountToken(acc) == null) {
    throw HostingException(
      '账号「${accountLabel(acc)}」还没有访问令牌，请先在账号管理里完成授权',
    );
  }
  return acc;
}

/// `repo` argument → owner/name slug. An explicit value wins; otherwise the
/// opened repo's GitHub remote is inferred (origin first, then any) via the
/// shared [ghSlugPick] — the UI panel uses the same resolution.
Future<String> _ghSlug(Map<String, dynamic> a) async {
  final explicit = ((a['repo'] as String?) ?? '').trim();
  if (explicit.isNotEmpty) return checkGhSlug(explicit);
  final repoPath = ((a['path'] as String?) ?? '').trim();
  if (repoPath.isEmpty) {
    throw HostingException(
      '缺少 repo（owner/name），也未传本地仓库 path 以便自动识别 GitHub 远程',
    );
  }
  final rs = await remotes(path: repoPath);
  return ghSlugPick('', [for (final r in rs) (name: r.name, url: r.url)]);
}

Future<String> _gh(
  String method,
  Uri uri,
  Map<String, dynamic> a, {
  String? body,
  Map<String, String>? headers,
}) async {
  final acc = await _ghAccount(a);
  return ghRequest(
    method,
    uri,
    token: accountToken(acc)!,
    body: body,
    extraHeaders: headers,
  );
}

// Shared repo/repo-path schema fragments: repo first, local path as fallback.
Map<String, dynamic> _repoProps() => {
  'repo': str('owner/name（如 alice/demo；省略时从本地仓库 path 的 GitHub 远程推断）'),
  'path': str('本地仓库绝对路径（repo 省略时用来自动识别）'),
  'accountLabel': str('GitHub 账号 label（可选，默认第一个已授权的 GitHub 账号）'),
};

final hostingTools = <McpTool>[
  // ---- identity / browsing ----
  McpTool(
    'gh_whoami',
    '验证 GitHub 账号连通性，返回登录用户（平台写操作前建议先调用）',
    obj({
      'accountLabel': str('GitHub 账号 label（可选，默认第一个已授权的 GitHub 账号）'),
    }),
    (a) async => '已连接：${await testConnection(await _ghAccount(a))}',
  ),
  McpTool(
    'gh_token_scopes',
    '读取当前 GitHub 令牌的真实权限（GET /user 的 X-OAuth-Scopes 响应头）。'
        '用于推送前判断是否具备 workflow 权限 —— 缺它时推送含 .github/workflows/ '
        '的提交会被服务端拒绝。返回 scopes=null 表示无法自动判定（细粒度令牌/App 令牌）',
    obj({
      'accountLabel': str('GitHub 账号 label（可选，默认第一个已授权的 GitHub 账号）'),
    }),
    (a) async {
      final acc = await _ghAccount(a);
      final info = await ghTokenInfo(accountToken(acc)!);
      return _enc.convert({
        'account': accountLabel(acc),
        'login': info.login,
        'scopes': info.scopes,
        'canPushWorkflow': info.canPushWorkflow,
        'note': info.scopes == null
            ? '该令牌不返回 scope（细粒度 PAT / GitHub App），无法自动判定'
            : (info.canPushWorkflow == true
                  ? '含 workflow 权限'
                  : '缺 workflow 权限：推送含 .github/workflows/ 的提交会被拒绝'),
      });
    },
  ),
  McpTool(
    'gh_repo_get',
    '查看 GitHub 仓库详情（默认分支/可见性/star 数等），无需 clone',
    obj(_repoProps()),
    (a) async {
      final slug = await _ghSlug(a);
      final j = jsonDecode(await _gh('GET', ghRepoUri(slug), a));
      final d = j is Map
          ? parseGhRepoDetail(Map<String, dynamic>.from(j))
          : null;
      if (d == null) return '仓库响应无法解析';
      return _enc.convert({'repo': slug, ...d});
    },
  ),
  McpTool(
    'gh_repo_edit',
    '修改 GitHub 仓库设置：可见性（公开/私有）、描述、主页。PATCH /repos/{owner}/{repo}，需要具备 repo 管理权限的令牌',
    obj({
      ..._repoProps(),
      'private': boolean('true=转私有，false=转公开；省略则不修改可见性'),
      'description': str('新仓库描述；省略则不修改'),
      'homepage': str('新主页 URL；省略则不修改'),
    }),
    (a) async {
      final slug = await _ghSlug(a);
      final payload = <String, dynamic>{};
      if (a['private'] is bool) payload['private'] = a['private'];
      for (final k in const ['description', 'homepage']) {
        final v = ((a[k] as String?) ?? '').trim();
        if (v.isNotEmpty) payload[k] = v;
      }
      if (payload.isEmpty) {
        throw HostingException(
          '未提供任何要修改的字段（private / description / homepage）',
        );
      }
      final j = jsonDecode(
        await _gh(
          'PATCH',
          ghRepoUri(slug),
          a,
          body: jsonEncode(payload),
          headers: {'Accept': 'application/vnd.github+json'},
        ),
      );
      if (j is! Map) return '仓库响应无法解析';
      final vis = payload['private'];
      final note = vis == false
          ? '仓库已转为公开：Actions 免费不限量（含 macOS），代码与 Release 对所有人可见'
          : vis == true
          ? '仓库已转为私有'
          : '仓库设置已更新';
      return _enc.convert({
        'repo': slug,
        'updated': payload.keys.toList(),
        'private': (j['private'] ?? false) as bool,
        'fullName': j['full_name'],
        'httpsUrl': j['clone_url'],
        'note': note,
      });
    },
  ),
  McpTool(
    'gh_ref_delete',
    '删除 GitHub 远程引用（tag 或分支）：DELETE /repos/{owner}/{repo}/git/refs/{ref}。'
        'ref 形如 tags/v1.0.0 或 heads/feature-x。危险操作，调用前须与用户确认',
    obj({
      ..._repoProps(),
      'ref': str('引用路径：tags/<标签名> 或 heads/<分支名>'),
    }),
    (a) async {
      final slug = await _ghSlug(a);
      final ref = ((a['ref'] as String?) ?? '').trim();
      if (ref.isEmpty ||
          !(ref.startsWith('tags/') || ref.startsWith('heads/'))) {
        throw HostingException('ref 必须以 tags/ 或 heads/ 开头（如 tags/v1.0.0）');
      }
      await _gh(
        'DELETE',
        ghRefUri(slug, ref),
        a,
        headers: {'Accept': 'application/vnd.github+json'},
      );
      return _enc.convert({'repo': slug, 'deleted': ref});
    },
  ),
  McpTool(
    'gh_release_delete',
    '删除 GitHub release（按 tag 定位），可选连同远程 tag 一起删。'
        'GET /releases/tags/{tag} 定位 id → DELETE /releases/{id}。危险操作，调用前须与用户确认',
    obj({
      ..._repoProps(),
      'tag': str('release 的 tag 名，如 v1.0.0'),
      'deleteTag': boolean('true=同时删除远程 tag（默认 false）'),
    }),
    (a) async {
      final slug = await _ghSlug(a);
      final tag = ((a['tag'] as String?) ?? '').trim();
      if (tag.isEmpty) throw HostingException('缺少 tag');
      final rel = jsonDecode(await _gh('GET', ghReleaseByTagUri(slug, tag), a));
      if (rel is! Map || rel['id'] == null) {
        throw HostingException('找不到 tag $tag 对应的 release');
      }
      final id = rel['id'] as int;
      await _gh(
        'DELETE',
        ghReleaseUri(slug, id),
        a,
        headers: {'Accept': 'application/vnd.github+json'},
      );
      var tagNote = '';
      if (a['deleteTag'] == true) {
        await _gh(
          'DELETE',
          ghRefUri(slug, 'tags/$tag'),
          a,
          headers: {'Accept': 'application/vnd.github+json'},
        );
        tagNote = '，远程 tag $tag 已一并删除';
      }
      return _enc.convert({
        'repo': slug,
        'deletedRelease': tag,
        'releaseId': id,
        'note': 'release 已删除$tagNote',
      });
    },
  ),
  McpTool(
    'gh_search_repos',
    '搜索 GitHub 仓库（支持限定语法如 user:alice、topic:mcp、in:readme）',
    obj({
      'q': str('搜索关键字，如 "flutter git" 或 "user:alice topic:mcp"'),
      'limit': integer('返回条数（默认 20，最大 100）'),
      'accountLabel': str('GitHub 账号 label（可选）'),
    }, required: ['q']),
    (a) async {
      final body = await _gh(
        'GET',
        ghSearchReposUri(a['q'] as String, perPage: intArg(a, 'limit', 20)),
        a,
      );
      return _enc.convert(parseGhSearch(body));
    },
  ),
  McpTool(
    'gh_tree_list',
    '列出 GitHub 仓库远端文件树（无需 clone）',
    obj({
      ..._repoProps(),
      'ref': str('分支/标签/commit，默认 HEAD'),
      'limit': integer('最多返回条目数（默认 200，最大 1000）'),
    }),
    (a) async {
      final slug = await _ghSlug(a);
      final ref = ((a['ref'] as String?) ?? '').trim().isEmpty
          ? 'HEAD'
          : (a['ref'] as String).trim();
      final body = await _gh('GET', ghTreeUri(slug, ref), a);
      final t = parseGhTree(body, maxEntries: intArg(a, 'limit', 200));
      final note = (t['serverTruncated'] as bool? ?? false)
          ? 'GitHub 端已截断：树过大，结果不完整'
          : ((t['clientOverflow'] as int? ?? 0) > 0
                ? '超出 limit 未展示 ${t['clientOverflow']} 条，可提高 limit 或用更具体 ref'
                : '');
      final out = <String, Object?>{'repo': slug, 'ref': ref, ...t};
      if (note.isNotEmpty) out['note'] = note;
      return _enc.convert(out);
    },
  ),
  McpTool(
    'gh_file_read',
    '读取 GitHub 仓库远端单个文件（≤1MB 文本；二进制与大文件会给出指引）',
    obj({
      ..._repoProps(),
      'file': str('文件相对路径，如 README.md / src/main.rs'),
      'ref': str('分支/标签/commit，默认 HEAD'),
      'maxChars': integer('文本最多返回字符数（默认 16384）'),
    }, required: ['file']),
    (a) async {
      final slug = await _ghSlug(a);
      final file = (a['file'] as String).trim();
      final ref = ((a['ref'] as String?) ?? '').trim().isEmpty
          ? 'HEAD'
          : (a['ref'] as String).trim();
      final body = await _gh('GET', ghContentUri(slug, file, ref: ref), a);
      final f = parseGhFileContent(
        body,
        maxTextChars: intArg(a, 'maxChars', 16384),
      );
      if (f == null) return '文件响应无法解析';
      if (f['tooLargeForInline'] == true) {
        return '该文件超过 1MB，GitHub contents API 不内联返回内容。'
            '请用 git_clone / git_fetch 后读取本地文件。网页：${f['htmlUrl']}';
      }
      if (f['binary'] == true) {
        return '二进制文件（${f['size']} 字节），不在对话中展示。网页：${f['htmlUrl']}';
      }
      return _enc.convert({'repo': slug, 'ref': ref, ...f});
    },
  ),

  // ---- issues ----
  McpTool(
    'gh_issue_list',
    '列出 GitHub 仓库的 issue（不含 PR）',
    obj({
      ..._repoProps(),
      'state': str('open / closed / all（默认 open）', enum_: ['open', 'closed', 'all']),
      'page': integer('页码（默认 1）'),
      'limit': integer('每页条数（默认 30，最大 100）'),
    }),
    (a) async {
      final slug = await _ghSlug(a);
      final page = intArg(a, 'page', 1);
      final body = await _gh(
        'GET',
        ghIssuesUri(
          slug,
          page: page,
          perPage: intArg(a, 'limit', 30),
          state: (a['state'] as String?) ?? 'open',
        ),
        a,
      );
      return _enc.convert({'repo': slug, 'page': page, 'issues': parseGhIssues(body)});
    },
  ),
  McpTool(
    'gh_issue_get',
    '查看单个 issue（正文与评论）',
    obj({..._repoProps(), 'number': integer('issue 编号')}, required: ['number']),
    (a) async {
      final slug = await _ghSlug(a);
      final n = intArg(a, 'number', 0);
      final j = jsonDecode(await _gh('GET', ghIssueUri(slug, n), a));
      final issue = j is Map
          ? parseGhIssue(
              Map<String, dynamic>.from(j),
              includePullRequests: true,
            )
          : null;
      if (issue == null) return 'issue 响应无法解析';
      final comments = parseGhComments(
        await _gh('GET', ghIssueCommentsUri(slug, n), a),
      );
      return _enc.convert({'repo': slug, 'issue': issue, 'comments': comments});
    },
  ),
  McpTool(
    'gh_issue_create',
    '在 GitHub 仓库创建 issue（平台端生效，不影响本地仓库）',
    obj({
      ..._repoProps(),
      'title': str('issue 标题'),
      'body': str('issue 正文（Markdown）'),
      'labels': listOf('标签名列表（可选，需要仓库已有同名标签）'),
    }, required: ['title']),
    (a) async {
      final slug = await _ghSlug(a);
      final resp = await _gh(
        'POST',
        ghIssuesUri(slug),
        a,
        body: ghIssueCreateBody(
          a['title'] as String,
          body: a['body'] as String?,
          labels: [
            for (final l in (a['labels'] as List? ?? <Object?>[]))
              if (l is String) l,
          ],
        ),
      );
      final j = jsonDecode(resp);
      final issue = j is Map
          ? parseGhIssue(
              Map<String, dynamic>.from(j),
              includePullRequests: true,
            )
          : null;
      return issue == null
          ? '已创建（响应无法解析）'
          : '已创建 #${issue['number']}：${issue['title']}\n${issue['url']}';
    },
  ),
  McpTool(
    'gh_issue_update',
    '更新 GitHub issue：评论 / 关闭 / 重开 / 改标题正文',
    obj({
      ..._repoProps(),
      'number': integer('issue 编号'),
      'comment': str('追加评论内容（Markdown，可选）'),
      'state': str('open 重开 / closed 关闭（可选）', enum_: ['open', 'closed']),
      'title': str('新标题（可选）'),
      'body': str('新正文，整体替换（可选）'),
    }, required: ['number']),
    (a) async {
      final slug = await _ghSlug(a);
      final n = intArg(a, 'number', 0);
      final comment = ((a['comment'] as String?) ?? '').trim();
      final out = <String>[];
      if (comment.isNotEmpty) {
        await _gh('POST', ghIssueCommentsUri(slug, n), a, body: ghCommentBody(comment));
        out.add('已添加评论');
      }
      if ((a['state'] as String?) != null ||
          (a['title'] as String?) != null ||
          (a['body'] as String?) != null) {
        await _gh(
          'PATCH',
          ghIssueUri(slug, n),
          a,
          body: ghIssuePatchBody(
            title: a['title'] as String?,
            body: a['body'] as String?,
            state: a['state'] as String?,
          ),
        );
        out.add('已更新字段');
      }
      if (out.isEmpty) {
        return '没有要执行的修改：请提供 comment / state / title / body 之一';
      }
      return '${out.join('；')}（#$n）';
    },
  ),

  // ---- pull requests ----
  McpTool(
    'gh_pr_list',
    '列出 GitHub 仓库的 PR',
    obj({
      ..._repoProps(),
      'state': str('open / closed / all（默认 open）', enum_: ['open', 'closed', 'all']),
      'page': integer('页码（默认 1）'),
      'limit': integer('每页条数（默认 30，最大 100）'),
    }),
    (a) async {
      final slug = await _ghSlug(a);
      final page = intArg(a, 'page', 1);
      final body = await _gh(
        'GET',
        ghPullsUri(
          slug,
          page: page,
          perPage: intArg(a, 'limit', 30),
          state: (a['state'] as String?) ?? 'open',
        ),
        a,
      );
      return _enc.convert({'repo': slug, 'page': page, 'prs': parseGhPrs(body)});
    },
  ),
  McpTool(
    'gh_pr_get',
    '查看单个 PR（元信息与变更 diff）',
    obj({
      ..._repoProps(),
      'number': integer('PR 编号'),
      'includeDiff': boolean('是否返回 diff（默认 true，超长会截断）'),
    }, required: ['number']),
    (a) async {
      final slug = await _ghSlug(a);
      final n = intArg(a, 'number', 0);
      final j = jsonDecode(await _gh('GET', ghPullUri(slug, n), a));
      final pr = j is Map ? parseGhPr(Map<String, dynamic>.from(j)) : null;
      if (pr == null) return 'PR 响应无法解析';
      final out = <String, Object?>{'repo': slug, 'pr': pr};
      if ((a['includeDiff'] as bool?) ?? true) {
        final diff = await _gh(
          'GET',
          ghPullUri(slug, n),
          a,
          headers: {'Accept': 'application/vnd.github.diff'},
        );
        out['diff'] = clipText(diff, 8192);
      }
      return _enc.convert(out);
    },
  ),
  McpTool(
    'gh_pr_merge',
    '合并 GitHub PR（merge / squash / rebase；平台端生效）',
    obj({
      ..._repoProps(),
      'number': integer('PR 编号'),
      'method': str('合并方式（默认 merge）', enum_: ['merge', 'squash', 'rebase']),
      'commitTitle': str('合并提交标题（可选）'),
      'sha': str('期望的 head sha（可选，防止合并期间 PR 已变化）'),
    }, required: ['number']),
    (a) async {
      final slug = await _ghSlug(a);
      final n = intArg(a, 'number', 0);
      final resp = await _gh(
        'PUT',
        ghPullMergeUri(slug, n),
        a,
        body: ghPrMergeBody(
          method: (a['method'] as String?) ?? 'merge',
          commitTitle: a['commitTitle'] as String?,
          sha: a['sha'] as String?,
        ),
      );
      final j = resp.isEmpty ? null : jsonDecode(resp);
      if (j is Map && j['merged'] == true) {
        final msg = j['message'] as String?;
        return '已合并 PR #$n（${j['sha']}）${msg == null ? '' : '：$msg'}';
      }
      return '合并结果未知：$resp';
    },
  ),
  McpTool(
    'gh_pr_update',
    '更新 GitHub PR：评论 / 关闭 / 重开 / 改标题正文',
    obj({
      ..._repoProps(),
      'number': integer('PR 编号'),
      'comment': str('追加评论内容（Markdown，可选）'),
      'state': str('open 重开 / closed 关闭（可选）', enum_: ['open', 'closed']),
      'title': str('新标题（可选）'),
      'body': str('新正文，整体替换（可选）'),
    }, required: ['number']),
    (a) async {
      final slug = await _ghSlug(a);
      final n = intArg(a, 'number', 0);
      final comment = ((a['comment'] as String?) ?? '').trim();
      final out = <String>[];
      if (comment.isNotEmpty) {
        // PR comments live on the issue thread of the same number.
        await _gh('POST', ghIssueCommentsUri(slug, n), a, body: ghCommentBody(comment));
        out.add('已添加评论');
      }
      if ((a['state'] as String?) != null ||
          (a['title'] as String?) != null ||
          (a['body'] as String?) != null) {
        await _gh(
          'PATCH',
          ghPullUri(slug, n),
          a,
          body: ghPrPatchBody(
            title: a['title'] as String?,
            body: a['body'] as String?,
            state: a['state'] as String?,
          ),
        );
        out.add('已更新字段');
      }
      if (out.isEmpty) {
        return '没有要执行的修改：请提供 comment / state / title / body 之一';
      }
      return '${out.join('；')}（PR #$n）';
    },
  ),

  // ---- releases ----
  McpTool(
    'gh_release_list',
    '列出 GitHub 仓库的 release（含附件下载链接）',
    obj({
      ..._repoProps(),
      'limit': integer('返回条数（默认 10，最大 100）'),
    }),
    (a) async {
      final slug = await _ghSlug(a);
      final body = await _gh(
        'GET',
        ghReleasesUri(slug, perPage: intArg(a, 'limit', 10)),
        a,
      );
      return _enc.convert({'repo': slug, 'releases': parseGhReleases(body)});
    },
  ),
];
