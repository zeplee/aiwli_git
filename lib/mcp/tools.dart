import 'dart:convert';

import '../core/hosting_api.dart';
import '../core/prefs.dart';
import '../engine/ffi.dart';
import 'tool_base.dart';
import 'tools_hosting.dart';

/// MCP tool catalogue: git-engine tools (1:1 with the Rust dispatch table)
/// plus hosting/platform tools merged in from tools_hosting.dart.
/// Handlers return JSON text (or engine text like diffs); engine errors
/// surface as exceptions and become `isError: true` results.

// Terse private aliases so the call sites below keep their shape; the
// canonical definitions live in tool_base.dart.
Map<String, dynamic> _obj(
  Map<String, dynamic> props, {
  List<String> required = const [],
}) => obj(props, required: required);
Map<String, dynamic> _str(String desc, {List<String>? enum_}) =>
    str(desc, enum_: enum_);
Map<String, dynamic> _bool(String desc) => boolean(desc);
Map<String, dynamic> _int(String desc) => integer(desc);
Map<String, dynamic> _list(String desc) => listOf(desc);
Future<String> _call(String method, Map<String, Object?> payload) =>
    call(method, payload);
String _p(Map<String, dynamic> a) => path(a);
List<String> _files(Map<String, dynamic> a) => filePaths(a);
int _num(Map<String, dynamic> a, String key, int def) => intArg(a, key, def);

Future<Map<String, Object?>?> _credForRepo(String path) async {
  try {
    final b = await branches(path: path);
    final current = b.local.firstWhere(
      (x) => x.isCurrent,
      orElse: () => b.local.first,
    );
    final upstream = current.upstream;
    if (upstream != null && upstream.contains('/')) {
      final remoteName = upstream.split('/').first;
      final rs = await remotes(path: path);
      final r = rs.firstWhere((x) => x.name == remoteName);
      return await Prefs.instance.credentialsForUrl(r.url);
    }
  } catch (_) {}
  return Prefs.instance.credentials();
}

Future<Map<String, Object?>?> _credForUrl(String url) =>
    Prefs.instance.credentialsForUrl(url);

/// App-managed SSH known_hosts path (engine checks host keys against it).
Future<String> _kh() => Prefs.instance.sshKnownHostsPath();
bool _acceptUnknown(Map<String, dynamic> a) =>
    (a['acceptUnknownHost'] as bool?) ?? false;

Future<Map<String, Object?>?> _credForRemote(String path, String remote) async {
  try {
    final rs = await remotes(path: path);
    final r = rs.firstWhere((x) => x.name == remote);
    return await Prefs.instance.credentialsForUrl(r.url);
  } catch (_) {
    return _credForRepo(path);
  }
}

final mcpTools = <McpTool>[
  // ---- discovery ----
  McpTool(
    'git_recents',
    '列出 AiwliGit 最近打开的仓库（含 lastRepo），用于发现可操作的仓库路径',
    _obj({}),
    (a) async {
      return const JsonEncoder.withIndent('  ').convert({
        'lastRepo': await Prefs.instance.lastRepo(),
        'recents': await Prefs.instance.recents(),
      });
    },
  ),
  McpTool(
    'git_open',
    '打开一个本地 Git 仓库',
    _obj({'path': _str('仓库绝对路径，如 /sdcard/Projects/demo')}, required: ['path']),
    (a) async {
      return '已打开 ${await openRepo(path: _p(a))}';
    },
  ),
  McpTool(
    'git_accounts',
    '列出本机绑定的代码托管账号（GitHub / GitLab / Codeup / 其他；绝不返回令牌明文）',
    _obj({}),
    (a) async {
      final list = await Prefs.instance.accounts();
      return const JsonEncoder.withIndent('  ').convert([
        for (final x in list)
          {
            'label': x['label'],
            'provider': x['provider'],
            'host': x['host'],
            'org': x['org'],
            'user': x['user'],
            'hasToken': (x['pass'] as String?)?.isNotEmpty == true,
            'sshKeyPath': x['keyPath'],
          },
      ]);
    },
  ),
  McpTool(
    'git_cloud_repos',
    '列出某个绑定账号名下的云端仓库（GitHub / GitLab / 云效 Codeup）',
    _obj(
      {
        'accountLabel': _str('要使用的账号 label（先 git_accounts 查看）'),
        'limit': _int('返回条数，默认 30'),
      },
      required: ['accountLabel'],
    ),
    (a) async {
      final label = a['accountLabel'] as String;
      final list = await Prefs.instance.accounts();
      final acc = list.cast<Map<String, Object?>?>().firstWhere(
        (x) => (x?['label'] as String?) == label,
        orElse: () => null,
      );
      if (acc == null) return '未找到账号：$label（先 git_accounts 查看）';
      try {
        final repos = await listCloudRepos(acc);
        return const JsonEncoder.withIndent('  ').convert([
          for (final r in repos.take(_num(a, 'limit', 30))) r.toJson(),
        ]);
      } catch (e) {
        return '列出云端仓库失败：$e';
      }
    },
  ),
  McpTool(
    'git_clone',
    '克隆远程仓库到本地目录',
    _obj(
      {
        'url': _str('远程 URL，如 https://github.com/user/repo.git'),
        'path': _str('本地目标目录'),
        'branch': _str('分支（可选，默认远程 HEAD）'),
      },
      required: ['url', 'path'],
    ),
    (a) async {
      return await cloneRepo(
        url: a['url'] as String,
        path: a['path'] as String,
        branch: a['branch'] as String?,
        cred: await _credForUrl(a['url'] as String),
      );
    },
  ),

  // ---- workbench ----
  McpTool(
    'git_status',
    '仓库状态：当前分支、领先/落后、已暂存/未暂存/未跟踪文件、冲突',
    _obj(
      {'path': _str('仓库绝对路径'), 'commitLimit': _int('返回的最近提交数（默认 20）')},
      required: ['path'],
    ),
    (a) async {
      return _call('snapshot', {
        'path': _p(a),
        'commitLimit': _num(a, 'commitLimit', 20),
      });
    },
  ),
  McpTool(
    'git_stage',
    '暂存指定文件',
    _obj(
      {'path': _str('仓库绝对路径'), 'files': _list('要暂存的文件路径列表')},
      required: ['path', 'files'],
    ),
    (a) async {
      await stagePaths(path: _p(a), files: _files(a));
      return '已暂存 ${_files(a).length} 个文件';
    },
  ),
  McpTool(
    'git_unstage',
    '取消暂存指定文件',
    _obj(
      {'path': _str('仓库绝对路径'), 'files': _list('要取消暂存的文件路径列表')},
      required: ['path', 'files'],
    ),
    (a) async {
      await unstagePaths(path: _p(a), files: _files(a));
      return '已取消暂存 ${_files(a).length} 个文件';
    },
  ),
  McpTool(
    'git_discard',
    '丢弃指定文件的未暂存修改（危险：未提交内容通常无法恢复）',
    _obj(
      {'path': _str('仓库绝对路径'), 'files': _list('要丢弃修改的文件路径列表')},
      required: ['path', 'files'],
    ),
    (a) async {
      await discardPaths(path: _p(a), files: _files(a));
      return '已丢弃 ${_files(a).length} 个文件的修改';
    },
  ),
  McpTool(
    'git_commit',
    '提交已暂存的变更',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'message': _str('提交信息'),
        'amend': _bool('修改上一次提交而不是新建（默认 false）'),
      },
      required: ['path', 'message'],
    ),
    (a) async {
      return '已提交 ${await commitStaged(path: _p(a), message: a['message'] as String, amend: (a['amend'] as bool?) ?? false)}';
    },
  ),
  McpTool(
    'git_diff_file',
    '查看单个文件的差异（未暂存或已暂存）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'file': _str('文件路径'),
        'staged': _bool(
          'true 查看已暂存差异（HEAD→index），false 未暂存（index→工作树），默认 false',
        ),
      },
      required: ['path', 'file'],
    ),
    (a) async {
      return getWorkdirDiff(
        path: _p(a),
        file: a['file'] as String,
        staged: (a['staged'] as bool?) ?? false,
      );
    },
  ),

  // ---- history ----
  McpTool(
    'git_log',
    '提交历史（可搜索）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'skip': _int('跳过条数（分页），默认 0'),
        'limit': _int('返回条数，默认 30'),
        'query': _str('搜索关键字（可选）'),
      },
      required: ['path'],
    ),
    (a) async {
      return _call('log', {
        'path': _p(a),
        'skip': _num(a, 'skip', 0),
        'limit': _num(a, 'limit', 30),
        'query': a['query'] as String?,
        'start': a['start'] as String?,
      });
    },
  ),
  McpTool(
    'git_commit_detail',
    '单个提交的详情与变更文件列表',
    _obj(
      {'path': _str('仓库绝对路径'), 'commitId': _str('提交 ID')},
      required: ['path', 'commitId'],
    ),
    (a) async {
      return _call('commitDetail', {
        'path': _p(a),
        'commitId': a['commitId'] as String,
      });
    },
  ),
  McpTool(
    'git_diff_revs',
    '比较两个提交之间的差异',
    _obj(
      {'path': _str('仓库绝对路径'), 'from': _str('起始提交'), 'to': _str('目标提交')},
      required: ['path', 'from', 'to'],
    ),
    (a) async {
      return _call('diffRevs', {
        'path': _p(a),
        'from': a['from'] as String,
        'to': a['to'] as String,
      });
    },
  ),
  McpTool(
    'git_blame',
    '逐行追溯文件的修改来源',
    _obj(
      {'path': _str('仓库绝对路径'), 'file': _str('文件路径')},
      required: ['path', 'file'],
    ),
    (a) async {
      return _call('blame', {'path': _p(a), 'file': a['file'] as String});
    },
  ),

  // ---- branches ----
  McpTool(
    'git_branches',
    '列出本地/远程分支和标签',
    _obj({'path': _str('仓库绝对路径')}, required: ['path']),
    (a) async {
      return _call('branches', {'path': _p(a)});
    },
  ),
  McpTool(
    'git_checkout',
    '切换分支',
    _obj(
      {'path': _str('仓库绝对路径'), 'branch': _str('目标分支名（远程分支名也可）')},
      required: ['path', 'branch'],
    ),
    (a) async {
      await checkout(path: _p(a), branch: a['branch'] as String);
      return '已切换到 ${a['branch']}';
    },
  ),
  McpTool(
    'git_branch_create',
    '新建分支（不切换）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'name': _str('新分支名'),
        'from': _str('起点提交（可选，默认当前 HEAD）'),
      },
      required: ['path', 'name'],
    ),
    (a) async {
      await branchCreate(
        path: _p(a),
        name: a['name'] as String,
        fromCommit: a['from'] as String?,
      );
      return '已创建 ${a['name']}';
    },
  ),
  McpTool(
    'git_branch_delete',
    '删除分支',
    _obj(
      {'path': _str('仓库绝对路径'), 'name': _str('分支名')},
      required: ['path', 'name'],
    ),
    (a) async {
      await branchDelete(path: _p(a), name: a['name'] as String);
      return '已删除 ${a['name']}';
    },
  ),
  McpTool(
    'git_branch_rename',
    '重命名分支',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'oldName': _str('旧分支名'),
        'newName': _str('新分支名'),
      },
      required: ['path', 'oldName', 'newName'],
    ),
    (a) async {
      await branchRename(
        path: _p(a),
        oldName: a['oldName'] as String,
        newName: a['newName'] as String,
      );
      return '已重命名为 ${a['newName']}';
    },
  ),
  McpTool(
    'git_branch_set_upstream',
    '设置分支的上游跟踪（如 origin/main）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'branch': _str('本地分支名'),
        'upstream': _str('上游引用，如 origin/main'),
      },
      required: ['path', 'branch', 'upstream'],
    ),
    (a) async {
      await branchSetUpstream(
        path: _p(a),
        branch: a['branch'] as String,
        upstream: a['upstream'] as String,
      );
      return '已设置 ${a['branch']} → ${a['upstream']}';
    },
  ),
  McpTool(
    'git_merge',
    '合并指定分支到当前分支',
    _obj(
      {'path': _str('仓库绝对路径'), 'branch': _str('要合入的分支名')},
      required: ['path', 'branch'],
    ),
    (a) async {
      final r = await merge(path: _p(a), branch: a['branch'] as String);
      if (r.upToDate) return '当前分支已包含该分支';
      if (r.conflicts.isNotEmpty) {
        return '合并产生 ${r.conflicts.length} 个冲突：${r.conflicts.join(', ')}';
      }
      return '合并完成';
    },
  ),
  McpTool(
    'git_tag_create',
    '在提交上创建标签',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'name': _str('标签名'),
        'commitId': _str('提交 ID（可选，默认当前 HEAD）'),
      },
      required: ['path', 'name'],
    ),
    (a) async {
      await tagCreate(
        path: _p(a),
        name: a['name'] as String,
        commitId: a['commitId'] as String?,
      );
      return '已创建标签 ${a['name']}';
    },
  ),
  McpTool(
    'git_tag_delete',
    '删除标签',
    _obj(
      {'path': _str('仓库绝对路径'), 'name': _str('标签名')},
      required: ['path', 'name'],
    ),
    (a) async {
      await tagDelete(path: _p(a), name: a['name'] as String);
      return '已删除标签 ${a['name']}';
    },
  ),
  McpTool(
    'git_tag_push',
    '推送标签到远程（轻量/附注都支持；标签无上游概念）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'remote': _str('远程名（默认 origin）'),
        'name': _str('标签名'),
        'force': _bool('远端已有同名标签时覆盖（默认 false）'),
      },
      required: ['path', 'remote', 'name'],
    ),
    (a) async {
      return await tagPush(
        path: _p(a),
        remote: a['remote'] as String,
        name: a['name'] as String,
        force: (a['force'] as bool?) ?? false,
        cred: await _credForRemote(_p(a), a['remote'] as String),
        knownHostsPath: await _kh(),
        acceptUnknownHost: _acceptUnknown(a),
      );
    },
  ),
  McpTool(
    'git_reset',
    '回退当前分支（危险：hard 会丢弃修改）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'commitId': _str('目标提交（可选，默认 HEAD）'),
        'mode': _str('mixed 保留修改（默认）/ soft 保留修改并暂存 / hard 丢弃修改'),
      },
      required: ['path'],
    ),
    (a) async {
      await reset(
        path: _p(a),
        commitId: a['commitId'] as String?,
        mode: (a['mode'] as String?) ?? 'mixed',
      );
      return '已回退（${(a['mode'] as String?) ?? 'mixed'}）';
    },
  ),
  McpTool(
    'git_revert',
    '生成一个反向提交来撤销指定提交',
    _obj(
      {'path': _str('仓库绝对路径'), 'commitId': _str('要撤销的提交 ID')},
      required: ['path', 'commitId'],
    ),
    (a) async {
      return await revert(path: _p(a), commitId: a['commitId'] as String);
    },
  ),
  McpTool(
    'git_cherry_pick',
    '摘取一个提交到当前分支',
    _obj(
      {'path': _str('仓库绝对路径'), 'commitId': _str('要摘取的提交 ID')},
      required: ['path', 'commitId'],
    ),
    (a) async {
      return await cherryPick(path: _p(a), commitId: a['commitId'] as String);
    },
  ),

  // ---- stash ----
  McpTool(
    'git_stash_list',
    '列出临时保存（stash）',
    _obj({'path': _str('仓库绝对路径')}, required: ['path']),
    (a) async {
      return _call('stashList', {'path': _p(a)});
    },
  ),
  McpTool(
    'git_stash_push',
    '把当前修改临时保存到 stash',
    _obj(
      {'path': _str('仓库绝对路径'), 'message': _str('说明（可选）')},
      required: ['path'],
    ),
    (a) async {
      return await stashPush(
        path: _p(a),
        message: a['message'] as String?,
        includeUntracked: true,
      );
    },
  ),
  McpTool(
    'git_stash_apply',
    '恢复一条 stash（不删除）',
    _obj(
      {'path': _str('仓库绝对路径'), 'index': _int('stash 序号（默认 0，最新）')},
      required: ['path'],
    ),
    (a) async {
      await stashApply(path: _p(a), index: _num(a, 'index', 0));
      return '已恢复 stash@{${_num(a, 'index', 0)}}';
    },
  ),
  McpTool(
    'git_stash_pop',
    '恢复并删除一条 stash',
    _obj(
      {'path': _str('仓库绝对路径'), 'index': _int('stash 序号（默认 0）')},
      required: ['path'],
    ),
    (a) async {
      await stashPop(path: _p(a), index: _num(a, 'index', 0));
      return '已弹出 stash@{${_num(a, 'index', 0)}}';
    },
  ),
  McpTool(
    'git_stash_drop',
    '丢弃一条 stash（危险）',
    _obj(
      {'path': _str('仓库绝对路径'), 'index': _int('stash 序号（默认 0）')},
      required: ['path'],
    ),
    (a) async {
      await stashDrop(path: _p(a), index: _num(a, 'index', 0));
      return '已丢弃 stash@{${_num(a, 'index', 0)}}';
    },
  ),

  // ---- remotes / sync ----
  McpTool(
    'git_remotes',
    '列出远程仓库',
    _obj({'path': _str('仓库绝对路径')}, required: ['path']),
    (a) async {
      return _call('remotes', {'path': _p(a)});
    },
  ),
  McpTool(
    'git_remote_add',
    '添加一个远程仓库（支持多个）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'name': _str('远程名，如 origin / upstream'),
        'url': _str('远程 URL'),
      },
      required: ['path', 'name', 'url'],
    ),
    (a) async {
      await remoteAdd(
        path: _p(a),
        name: a['name'] as String,
        url: a['url'] as String,
      );
      return '已添加远程 ${a['name']}';
    },
  ),
  McpTool(
    'git_remote_set_url',
    '修改远程仓库的 URL',
    _obj(
      {'path': _str('仓库绝对路径'), 'name': _str('远程名'), 'url': _str('新 URL')},
      required: ['path', 'name', 'url'],
    ),
    (a) async {
      await remoteSetUrl(
        path: _p(a),
        name: a['name'] as String,
        url: a['url'] as String,
      );
      return '已更新 ${a['name']} 的 URL';
    },
  ),
  McpTool(
    'git_remote_delete',
    '删除一个远程仓库（本地提交不受影响）',
    _obj(
      {'path': _str('仓库绝对路径'), 'name': _str('远程名')},
      required: ['path', 'name'],
    ),
    (a) async {
      await remoteDelete(path: _p(a), name: a['name'] as String);
      return '已删除远程 ${a['name']}';
    },
  ),
  McpTool(
    'git_fetch',
    '获取远程更新（不改工作区）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'remote': _str('远程名（默认 origin；多远程时建议先 git_remotes 查看）'),
      },
      required: ['path'],
    ),
    (a) async {
      return await fetch(
        path: _p(a),
        remote: (a['remote'] as String?) ?? 'origin',
        cred: await _credForRemote(_p(a), (a['remote'] as String?) ?? 'origin'),
        knownHostsPath: await _kh(),
        acceptUnknownHost: _acceptUnknown(a),
      );
    },
  ),
  McpTool(
    'git_push',
    '推送提交到远程',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'remote': _str('远程名（默认 origin）'),
        'branch': _str('分支名（默认当前分支由引擎决定，建议显式传）'),
        'setUpstream': _bool('绑定上游（默认 true）'),
        'force': _bool('强制覆盖远程（危险，默认 false）'),
      },
      required: ['path', 'remote', 'branch'],
    ),
    (a) async {
      return await push(
        path: _p(a),
        remote: a['remote'] as String,
        branch: a['branch'] as String,
        setUpstream: (a['setUpstream'] as bool?) ?? true,
        force: (a['force'] as bool?) ?? false,
        cred: await _credForRemote(_p(a), a['remote'] as String),
        knownHostsPath: await _kh(),
        acceptUnknownHost: _acceptUnknown(a),
      );
    },
  ),
  McpTool(
    'git_pull',
    '拉取并合并远程更新（走当前分支的上游）',
    _obj({'path': _str('仓库绝对路径')}, required: ['path']),
    (a) async {
      final r = await pull(
        path: _p(a),
        cred: await _credForRepo(_p(a)),
        knownHostsPath: await _kh(),
        acceptUnknownHost: _acceptUnknown(a),
      );
      if (r.upToDate) return '已是最新';
      if (r.conflicts.isNotEmpty) {
        return '拉取产生 ${r.conflicts.length} 个冲突：${r.conflicts.join(', ')}';
      }
      return '拉取完成';
    },
  ),
  McpTool(
    'git_conflicts',
    '列出当前合并冲突的文件',
    _obj({'path': _str('仓库绝对路径')}, required: ['path']),
    (a) async {
      return _call('conflicts', {'path': _p(a)});
    },
  ),
  McpTool(
    'git_resolve_conflict',
    '解决冲突：采用我方或对方',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'file': _str('冲突文件路径'),
        'side': _str('ours 采用我方 / theirs 采用对方', enum_: ['ours', 'theirs']),
      },
      required: ['path', 'file', 'side'],
    ),
    (a) async {
      await resolveConflict(
        path: _p(a),
        file: a['file'] as String,
        side: a['side'] as String,
      );
      return '已采用${a['side'] == 'ours' ? '我方' : '对方'}';
    },
  ),

  // ---- config ----
  McpTool(
    'git_config_get',
    '读取仓库身份（user.name / user.email）',
    _obj({'path': _str('仓库绝对路径')}, required: ['path']),
    (a) async {
      return _call('configGet', {'path': _p(a)});
    },
  ),
  McpTool(
    'git_config_set',
    '设置仓库身份（提交作者）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'userName': _str('user.name'),
        'userEmail': _str('user.email'),
      },
      required: ['path'],
    ),
    (a) async {
      await configSet(
        path: _p(a),
        userName: a['userName'] as String?,
        userEmail: a['userEmail'] as String?,
      );
      return '已保存仓库身份';
    },
  ),
  McpTool(
    'git_ignore_get',
    '读取 .gitignore 内容',
    _obj({'path': _str('仓库绝对路径')}, required: ['path']),
    (a) async {
      return await ignoreGet(path: _p(a));
    },
  ),
  McpTool(
    'git_ignore_set',
    '写入 .gitignore 内容（整体替换）',
    _obj(
      {'path': _str('仓库绝对路径'), 'content': _str('完整的 .gitignore 文本')},
      required: ['path', 'content'],
    ),
    (a) async {
      await ignoreSet(path: _p(a), content: a['content'] as String);
      return '已保存 .gitignore';
    },
  ),

  // ---- 引擎能力补全（v1.5.24）：此前引擎有而 MCP 未暴露的工具 ----
  McpTool(
    'git_checkout_commit',
    '检出指定提交（分离 HEAD，不重置分支）',
    _obj(
      {'path': _str('仓库绝对路径'), 'commitId': _str('提交 ID')},
      required: ['path', 'commitId'],
    ),
    (a) async {
      await checkoutCommit(path: _p(a), commitId: a['commitId'] as String);
      return '已检出 ${a['commitId']}（分离 HEAD）';
    },
  ),
  McpTool(
    'git_hunks',
    '列出单个文件的 hunk 列表（配合 git_hunk_op 做 hunk 级暂存/撤销）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'file': _str('文件相对路径'),
        'staged': _bool('true=已暂存区的 hunk（默认 false=未暂存）'),
      },
      required: ['path', 'file'],
    ),
    (a) async => _call('hunks', {
      'path': _p(a),
      'file': a['file'] as String,
      'staged': (a['staged'] as bool?) ?? false,
    }),
  ),
  McpTool(
    'git_hunk_op',
    '对指定 hunk 执行操作：stage 暂存 / unstage 取消暂存 / discard 丢弃（危险）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'file': _str('文件相对路径'),
        'indexes': _list('hunk 序号列表（来自 git_hunks 返回的 index）'),
        'op': _str('stage | unstage | discard'),
      },
      required: ['path', 'file', 'indexes', 'op'],
    ),
    (a) async {
      final idx = [for (final x in (a['indexes'] as List)) (x as num).toInt()];
      await hunkOp(
        path: _p(a),
        file: a['file'] as String,
        indexes: idx,
        op: a['op'] as String,
      );
      return '已对 ${idx.length} 个 hunk 执行 ${a['op']}';
    },
  ),
  McpTool(
    'git_commit_diff',
    '单个提交的变更文件列表与差异（path/code/additions/deletions/patchText）',
    _obj(
      {'path': _str('仓库绝对路径'), 'commitId': _str('提交 ID')},
      required: ['path', 'commitId'],
    ),
    (a) async => _call('commitDiff', {
      'path': _p(a),
      'commitId': a['commitId'] as String,
    }),
  ),
  McpTool(
    'git_workdir_diff',
    '单个文件的工作区差异文本',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'file': _str('文件相对路径'),
        'staged': _bool('true=已暂存差异（默认 false）'),
      },
      required: ['path', 'file'],
    ),
    (a) async => await getWorkdirDiff(
      path: _p(a),
      file: a['file'] as String,
      staged: (a['staged'] as bool?) ?? false,
    ),
  ),
  McpTool(
    'git_merge_abort',
    '中止当前合并并恢复合并前状态',
    _obj({'path': _str('仓库绝对路径')}, required: ['path']),
    (a) async {
      await mergeAbort(path: _p(a));
      return '已中止合并';
    },
  ),
  McpTool(
    'git_merge_commit',
    '冲突解决完成后提交合并（生成合并提交）',
    _obj(
      {
        'path': _str('仓库绝对路径'),
        'message': _str('合并提交信息（可选，默认引擎生成）'),
      },
      required: ['path'],
    ),
    (a) async =>
        await mergeCommit(path: _p(a), message: a['message'] as String?),
  ),
  McpTool(
    'git_init_repo',
    '在已有文件夹上 git init（收编为仓库，主分支 main）',
    _obj({'path': _str('目标文件夹绝对路径')}, required: ['path']),
    (a) async => await initRepo(path: _p(a)),
  ),
  McpTool(
    'git_tls_status',
    '查看 TLS 配置状态（CA 目录/是否跳过校验/自定义证书列表）',
    _obj({}, required: []),
    (a) async => jsonEncode(await tlsStatus()),
  ),
  McpTool(
    'git_ca_import',
    '导入 PEM 证书（可含多张，导入后当场生效，无需重启）',
    _obj(
      {'label': _str('证书标签'), 'pem': _str('PEM 文本（可含多张证书）')},
      required: ['label', 'pem'],
    ),
    (a) async => jsonEncode(
      await caImport(label: a['label'] as String, pem: a['pem'] as String),
    ),
  ),
  McpTool(
    'git_ca_list',
    '列出已导入的自定义 CA',
    _obj({}, required: []),
    (a) async => jsonEncode(await caList()),
  ),
  McpTool(
    'git_ca_remove',
    '删除一个已导入的 CA（当次进程不撤销信任，重启应用后完全生效）',
    _obj({'id': _str('CA 条目 id（来自 git_ca_list）')}, required: ['id']),
    (a) async => jsonEncode(await caRemove(a['id'] as String)),
  ),
  McpTool(
    'git_set_ca_dir',
    '设置自定义 CA 目录',
    _obj({'dir': _str('CA 目录绝对路径')}, required: ['dir']),
    (a) async => jsonEncode(await setCaDir(a['dir'] as String)),
  ),
  McpTool(
    'git_set_skip_tls_verify',
    '跳过 TLS 证书校验（危险，仅自签名/调试环境临时使用）',
    _obj({'skip': _bool('true=跳过校验')}, required: ['skip']),
    (a) async =>
        jsonEncode(await setSkipTlsVerify((a['skip'] as bool?) ?? false)),
  ),

  // ---- hosting / platform (GitHub) — see tools_hosting.dart ----
  ...hostingTools,
];

/// O(1) tool lookup; the index is built once per process.
final _toolIndex = {for (final t in mcpTools) t.name: t};
McpTool? toolByName(String name) => _toolIndex[name];
