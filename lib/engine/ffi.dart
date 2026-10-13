import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

// ================= models =================

class FileStatus {
  final String path;
  final String code;
  FileStatus({required this.path, required this.code});
  factory FileStatus.fromJson(dynamic j) =>
      FileStatus(path: j['path'] as String, code: j['code'] as String);
}

class CommitInfo {
  final String id, shortId, summary, message, author, email;
  final int timeUnix;
  CommitInfo({
    required this.id,
    required this.shortId,
    required this.summary,
    required this.message,
    required this.author,
    required this.email,
    required this.timeUnix,
  });
  factory CommitInfo.fromJson(dynamic j) => CommitInfo(
    id: j['id'],
    shortId: j['shortId'] ?? '',
    summary: j['summary'] ?? '',
    message: j['message'] ?? '',
    author: j['author'] ?? '',
    email: j['email'] ?? '',
    timeUnix: (j['timeUnix'] ?? 0) as int,
  );
}

class RepoSnapshot {
  final String branch, headId;
  final bool hasMergeHead;
  final int ahead, behind;
  final List<FileStatus> staged, unstaged;
  final List<String> untracked, conflicted;
  final List<CommitInfo> recentCommits;
  RepoSnapshot({
    required this.branch,
    required this.headId,
    required this.hasMergeHead,
    required this.ahead,
    required this.behind,
    required this.staged,
    required this.unstaged,
    required this.untracked,
    required this.conflicted,
    required this.recentCommits,
  });
  factory RepoSnapshot.fromJson(dynamic j) => RepoSnapshot(
    branch: j['branch'] ?? '(detached)',
    headId: j['headId'] ?? '',
    hasMergeHead: (j['hasMergeHead'] ?? false) as bool,
    ahead: (j['ahead'] ?? 0) as int,
    behind: (j['behind'] ?? 0) as int,
    staged: [for (final x in (j['staged'] ?? [])) FileStatus.fromJson(x)],
    unstaged: [for (final x in (j['unstaged'] ?? [])) FileStatus.fromJson(x)],
    untracked: [for (final x in (j['untracked'] ?? [])) x as String],
    conflicted: [for (final x in (j['conflicted'] ?? [])) x as String],
    recentCommits: [
      for (final x in (j['recentCommits'] ?? [])) CommitInfo.fromJson(x),
    ],
  );
}

class CommitDiffEntry {
  final String path, code, patchText;
  final int additions, deletions;
  CommitDiffEntry({
    required this.path,
    required this.code,
    required this.additions,
    required this.deletions,
    required this.patchText,
  });
  factory CommitDiffEntry.fromJson(dynamic j) => CommitDiffEntry(
    path: j['path'],
    code: j['code'] ?? 'M',
    additions: (j['additions'] ?? 0) as int,
    deletions: (j['deletions'] ?? 0) as int,
    patchText: j['patchText'] ?? '',
  );
}

class LogEntry {
  final CommitInfo info;
  final List<String> parents, refs;
  LogEntry({required this.info, required this.parents, required this.refs});
  factory LogEntry.fromJson(dynamic j) => LogEntry(
    info: CommitInfo.fromJson(j),
    parents: [for (final x in (j['parents'] ?? [])) x as String],
    refs: [for (final x in (j['refs'] ?? [])) x as String],
  );
}

class BranchInfo {
  final String name, targetShort;
  final bool isCurrent;
  final String? upstream;
  final int ahead, behind;
  BranchInfo({
    required this.name,
    required this.isCurrent,
    required this.upstream,
    required this.ahead,
    required this.behind,
    required this.targetShort,
  });
  factory BranchInfo.fromJson(dynamic j) => BranchInfo(
    name: j['name'],
    isCurrent: (j['isCurrent'] ?? false) as bool,
    upstream: j['upstream'] as String?,
    ahead: (j['ahead'] ?? 0) as int,
    behind: (j['behind'] ?? 0) as int,
    targetShort: j['targetShort'] ?? '',
  );
}

class TagInfo {
  final String name, targetShort;
  TagInfo({required this.name, required this.targetShort});
  factory TagInfo.fromJson(dynamic j) =>
      TagInfo(name: j['name'], targetShort: j['targetShort'] ?? '');
}

class BranchesResult {
  final String current;
  final bool detached;
  final List<BranchInfo> local;
  final List<String> remote;
  final List<TagInfo> tags;
  BranchesResult({
    required this.current,
    required this.detached,
    required this.local,
    required this.remote,
    required this.tags,
  });
  factory BranchesResult.fromJson(dynamic j) => BranchesResult(
    current: j['current'] ?? '',
    detached: (j['detached'] ?? false) as bool,
    local: [for (final x in (j['local'] ?? [])) BranchInfo.fromJson(x)],
    remote: [for (final x in (j['remote'] ?? [])) x as String],
    tags: [for (final x in (j['tags'] ?? [])) TagInfo.fromJson(x)],
  );
}

class MergeResult {
  final bool fastForward, upToDate;
  final String? commitId;
  final List<String> conflicts;
  MergeResult({
    required this.fastForward,
    required this.upToDate,
    required this.commitId,
    required this.conflicts,
  });
  factory MergeResult.fromJson(dynamic j) => MergeResult(
    fastForward: (j['fastForward'] ?? false) as bool,
    upToDate: (j['upToDate'] ?? false) as bool,
    commitId: j['commitId'] as String?,
    conflicts: [for (final x in (j['conflicts'] ?? [])) x as String],
  );
}

class StashEntry {
  final int index, timeUnix;
  final String id, message;
  StashEntry({
    required this.index,
    required this.id,
    required this.message,
    required this.timeUnix,
  });
  factory StashEntry.fromJson(dynamic j) => StashEntry(
    index: (j['index'] ?? 0) as int,
    id: j['id'] ?? '',
    message: j['message'] ?? '',
    timeUnix: (j['timeUnix'] ?? 0) as int,
  );
}

class RemoteInfo {
  final String name, url;
  RemoteInfo({required this.name, required this.url});
  factory RemoteInfo.fromJson(dynamic j) =>
      RemoteInfo(name: j['name'], url: j['url'] ?? '');
}

class ConfigInfo {
  final String userName, userEmail;
  ConfigInfo({required this.userName, required this.userEmail});
  factory ConfigInfo.fromJson(dynamic j) => ConfigInfo(
    userName: j['userName'] ?? '',
    userEmail: j['userEmail'] ?? '',
  );
}

class BlameLine {
  final int lineNo, timeUnix;
  final String commitId, shortId, author, summary, content;
  BlameLine({
    required this.lineNo,
    required this.commitId,
    required this.shortId,
    required this.author,
    required this.timeUnix,
    required this.summary,
    required this.content,
  });
  factory BlameLine.fromJson(dynamic j) => BlameLine(
    lineNo: (j['lineNo'] ?? 0) as int,
    commitId: j['commitId'] ?? '',
    shortId: j['shortId'] ?? '',
    author: j['author'] ?? '',
    timeUnix: (j['timeUnix'] ?? 0) as int,
    summary: j['summary'] ?? '',
    content: j['content'] ?? '',
  );
}

class ConflictFile {
  final String path;
  final bool hasOurs, hasTheirs;
  ConflictFile({
    required this.path,
    required this.hasOurs,
    required this.hasTheirs,
  });
  factory ConflictFile.fromJson(dynamic j) => ConflictFile(
    path: j['path'],
    hasOurs: (j['hasOurs'] ?? false) as bool,
    hasTheirs: (j['hasTheirs'] ?? false) as bool,
  );
}

class CommitDetail {
  final CommitInfo info;
  final List<String> parents;
  final List<CommitDiffEntry> files;
  CommitDetail({
    required this.info,
    required this.parents,
    required this.files,
  });
  factory CommitDetail.fromJson(dynamic j) => CommitDetail(
    info: CommitInfo.fromJson(j['info']),
    parents: [for (final x in (j['parents'] ?? [])) x as String],
    files: [for (final x in (j['files'] ?? [])) CommitDiffEntry.fromJson(x)],
  );
}

// ================= transport =================

/// Platform-aware library loading (Android / iOS / macOS / Windows / Linux).
DynamicLibrary? _cachedLib;
DynamicLibrary _openLib() {
  if (_cachedLib != null) return _cachedLib!;
  final lib = Platform.isIOS
      ? DynamicLibrary.process() // statically linked into the app
      : DynamicLibrary.open(
          Platform.isMacOS
              ? 'librust_lib_gitdeck.dylib'
              : Platform.isWindows
              ? 'rust_lib_gitdeck.dll'
              : 'librust_lib_gitdeck.so',
        );
  return _cachedLib = lib;
}

/// Synchronous FFI dispatch executed inside an isolate.
String _callSync(String method, Map<String, Object?> payload) {
  final lib = _openLib();
  final callFn = lib
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Uint8>, Pointer<Uint8>),
        Pointer<Uint8> Function(Pointer<Uint8>, Pointer<Uint8>)
      >('gitdeck_call');
  final freeFn = lib
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('gitdeck_free');

  final m = method.toNativeUtf8().cast<Uint8>();
  final p = jsonEncode(payload).toNativeUtf8().cast<Uint8>();
  final result = callFn(m, p);
  final cstr = result.cast<Utf8>().toDartString();
  malloc.free(m);
  malloc.free(p);
  freeFn(result);
  final json = jsonDecode(cstr);
  if (json is Map && json.containsKey('__err')) {
    throw Exception(json['__err']);
  }
  return cstr;
}

class RustLib {
  /// Raw dispatch; returns decoded JSON. Errors surface as exceptions.
  static Future<dynamic> call(
    String method, [
    Map<String, Object?> payload = const {},
  ]) async {
    final json = await Isolate.run(() => _callSync(method, payload));
    return jsonDecode(json);
  }
}

// ================= typed helpers (UI calls these) =================

Future<String> openRepo({required String path}) async =>
    (await RustLib.call('openRepo', {'path': path})) as String;

/// git init on an existing folder — adopts it as a repository (main branch).
Future<String> initRepo({required String path}) async =>
    (await RustLib.call('initRepo', {'path': path})) as String;

Future<RepoSnapshot> getSnapshot({
  required String path,
  int commitLimit = 50,
}) async => RepoSnapshot.fromJson(
  await RustLib.call('snapshot', {'path': path, 'commitLimit': commitLimit}),
);

Future<String> getWorkdirDiff({
  required String path,
  required String file,
  required bool staged,
}) async => (await RustLib.call('workdirDiff', {
  'path': path,
  'file': file,
  'staged': staged,
})) as String;

Future<List<CommitDiffEntry>> getCommitDiff({
  required String path,
  required String commitId,
}) async => [
  for (final x in (await RustLib.call('commitDiff', {
    'path': path,
    'commitId': commitId,
  }) as List))
    CommitDiffEntry.fromJson(x),
];

Future<void> stagePaths({
  required String path,
  required List<String> files,
}) async => await RustLib.call('stage', {'path': path, 'files': files});

Future<void> unstagePaths({
  required String path,
  required List<String> files,
}) async => await RustLib.call('unstage', {'path': path, 'files': files});

Future<void> discardPaths({
  required String path,
  required List<String> files,
}) async => await RustLib.call('discard', {'path': path, 'files': files});

Future<String> commitStaged({
  required String path,
  required String message,
  bool amend = false,
}) async => (await RustLib.call('commit', {
  'path': path,
  'message': message,
  'amend': amend,
})) as String;

Future<List<Map<String, dynamic>>> hunkList({
  required String path,
  required String file,
  bool staged = false,
}) async => [
  for (final x in (await RustLib.call('hunks', {
    'path': path,
    'file': file,
    'staged': staged,
  }) as List))
    Map<String, dynamic>.from(x),
];

Future<void> hunkOp({
  required String path,
  required String file,
  required List<int> indexes,
  required String op,
}) async => await RustLib.call('hunkOp', {
  'path': path,
  'file': file,
  'indexes': indexes,
  'op': op,
});

Future<BranchesResult> branches({required String path}) async =>
    BranchesResult.fromJson(await RustLib.call('branches', {'path': path}));

Future<void> checkout({required String path, required String branch}) async =>
    await RustLib.call('checkout', {'path': path, 'branch': branch});

/// Detached-HEAD checkout of an arbitrary commit (no branch reset).
Future<void> checkoutCommit({
  required String path,
  required String commitId,
}) async =>
    await RustLib.call('checkoutCommit', {'path': path, 'commitId': commitId});

/// Point a local branch's tracking upstream at e.g. `origin/main`.
Future<void> branchSetUpstream({
  required String path,
  required String branch,
  required String upstream,
}) async => await RustLib.call('branchSetUpstream', {
  'path': path,
  'branch': branch,
  'upstream': upstream,
});

Future<void> branchCreate({
  required String path,
  required String name,
  String? fromCommit,
}) async => await RustLib.call('branchCreate', {
  'path': path,
  'name': name,
  'fromCommit': fromCommit,
});

Future<void> branchDelete({required String path, required String name}) async =>
    await RustLib.call('branchDelete', {'path': path, 'name': name});

Future<void> branchRename({
  required String path,
  required String oldName,
  required String newName,
}) async => await RustLib.call('branchRename', {
  'path': path,
  'oldName': oldName,
  'newName': newName,
});

Future<void> tagCreate({
  required String path,
  required String name,
  String? commitId,
}) async => await RustLib.call('tagCreate', {
  'path': path,
  'name': name,
  'commitId': commitId,
});

Future<void> tagDelete({required String path, required String name}) async =>
    await RustLib.call('tagDelete', {'path': path, 'name': name});

Future<List<LogEntry>> log({
  required String path,
  int skip = 0,
  int limit = 60,
  String? query,
  String? start,
}) async => [
  for (final x in (await RustLib.call('log', {
    'path': path,
    'skip': skip,
    'limit': limit,
    'query': query,
    'start': start,
  }) as List))
    LogEntry.fromJson(x),
];

Future<CommitDetail> commitDetail({
  required String path,
  required String commitId,
}) async => CommitDetail.fromJson(
  await RustLib.call('commitDetail', {'path': path, 'commitId': commitId}),
);

Future<List<CommitDiffEntry>> diffRevs({
  required String path,
  required String from,
  required String to,
}) async => [
  for (final x in (await RustLib.call('diffRevs', {
    'path': path,
    'from': from,
    'to': to,
  }) as List))
    CommitDiffEntry.fromJson(x),
];

Future<List<BlameLine>> blame({
  required String path,
  required String file,
}) async => [
  for (final x
      in (await RustLib.call('blame', {'path': path, 'file': file}) as List))
    BlameLine.fromJson(x),
];

Future<void> reset({
  required String path,
  String? commitId,
  String mode = 'mixed',
}) async => await RustLib.call('reset', {
  'path': path,
  'commitId': commitId,
  'mode': mode,
});

Future<String> revert({required String path, required String commitId}) async =>
    (await RustLib.call('revert', {'path': path, 'commitId': commitId}))
        as String;

Future<String> cherryPick({
  required String path,
  required String commitId,
}) async =>
    (await RustLib.call('cherryPick', {'path': path, 'commitId': commitId}))
        as String;

Future<MergeResult> merge({
  required String path,
  required String branch,
}) async => MergeResult.fromJson(
  await RustLib.call('merge', {'path': path, 'branch': branch}),
);

Future<String> mergeCommit({required String path, String? message}) async =>
    (await RustLib.call('mergeCommit', {'path': path, 'message': message}))
        as String;

Future<void> mergeAbort({required String path}) async =>
    await RustLib.call('mergeAbort', {'path': path});

Future<List<ConflictFile>> conflicts({required String path}) async => [
  for (final x in (await RustLib.call('conflicts', {'path': path}) as List))
    ConflictFile.fromJson(x),
];

Future<void> resolveConflict({
  required String path,
  required String file,
  required String side,
}) async => await RustLib.call('resolveConflict', {
  'path': path,
  'file': file,
  'side': side,
});

Future<List<StashEntry>> stashList({required String path}) async => [
  for (final x in (await RustLib.call('stashList', {'path': path}) as List))
    StashEntry.fromJson(x),
];

Future<String> stashPush({
  required String path,
  String? message,
  bool includeUntracked = true,
}) async => (await RustLib.call('stashPush', {
  'path': path,
  'message': message,
  'includeUntracked': includeUntracked,
})) as String;

Future<void> stashApply({required String path, required int index}) async =>
    await RustLib.call('stashApply', {'path': path, 'index': index});

Future<void> stashPop({required String path, required int index}) async =>
    await RustLib.call('stashPop', {'path': path, 'index': index});

Future<void> stashDrop({required String path, required int index}) async =>
    await RustLib.call('stashDrop', {'path': path, 'index': index});

Future<List<RemoteInfo>> remotes({required String path}) async => [
  for (final x in (await RustLib.call('remotes', {'path': path}) as List))
    RemoteInfo.fromJson(x),
];

Future<String> cloneRepo({
  required String url,
  required String path,
  String? branch,
  Map<String, Object?>? cred,
  String? knownHostsPath,
  bool acceptUnknownHost = false,
}) async => (await RustLib.call('clone', {
  'url': url,
  'path': path,
  'branch': branch,
  'cred': cred,
  'knownHostsPath': knownHostsPath,
  'acceptUnknownHost': acceptUnknownHost,
})) as String;

Future<void> remoteAdd({
  required String path,
  required String name,
  required String url,
}) async =>
    await RustLib.call('remoteAdd', {'path': path, 'name': name, 'url': url});

Future<void> remoteSetUrl({
  required String path,
  required String name,
  required String url,
}) async => await RustLib.call('remoteSetUrl', {
  'path': path,
  'name': name,
  'url': url,
});

Future<void> remoteDelete({required String path, required String name}) async =>
    await RustLib.call('remoteDelete', {'path': path, 'name': name});

Future<String> fetch({
  required String path,
  required String remote,
  Map<String, Object?>? cred,
  String? knownHostsPath,
  bool acceptUnknownHost = false,
}) async => (await RustLib.call('fetch', {
  'path': path,
  'remote': remote,
  'cred': cred,
  'knownHostsPath': knownHostsPath,
  'acceptUnknownHost': acceptUnknownHost,
})) as String;

Future<String> push({
  required String path,
  required String remote,
  required String branch,
  bool setUpstream = false,
  bool force = false,
  Map<String, Object?>? cred,
  String? knownHostsPath,
  bool acceptUnknownHost = false,
}) async => (await RustLib.call('push', {
  'path': path,
  'remote': remote,
  'branch': branch,
  'setUpstream': setUpstream,
  'force': force,
  'cred': cred,
  'knownHostsPath': knownHostsPath,
  'acceptUnknownHost': acceptUnknownHost,
})) as String;

/// 推送单个标签到远程（`refs/tags/<name>`）。轻量/附注都支持；标签无上游概念。
Future<String> tagPush({
  required String path,
  required String remote,
  required String name,
  bool force = false,
  Map<String, Object?>? cred,
  String? knownHostsPath,
  bool acceptUnknownHost = false,
}) async => (await RustLib.call('tagPush', {
  'path': path,
  'remote': remote,
  'name': name,
  'force': force,
  'cred': cred,
  'knownHostsPath': knownHostsPath,
  'acceptUnknownHost': acceptUnknownHost,
})) as String;

Future<MergeResult> pull({
  required String path,
  Map<String, Object?>? cred,
  String? knownHostsPath,
  bool acceptUnknownHost = false,
}) async => MergeResult.fromJson(
  await RustLib.call('pull', {
    'path': path,
    'cred': cred,
    'knownHostsPath': knownHostsPath,
    'acceptUnknownHost': acceptUnknownHost,
  }),
);

Future<ConfigInfo> configGet({required String path}) async =>
    ConfigInfo.fromJson(await RustLib.call('configGet', {'path': path}));

Future<void> configSet({
  required String path,
  String? userName,
  String? userEmail,
}) async => await RustLib.call('configSet', {
  'path': path,
  'userName': userName,
  'userEmail': userEmail,
});

Future<String> ignoreGet({required String path}) async =>
    (await RustLib.call('ignoreGet', {'path': path})) as String;

Future<void> ignoreSet({required String path, required String content}) async =>
    await RustLib.call('ignoreSet', {'path': path, 'content': content});

// ================= TLS 信任库 / 证书校验 =================

/// 把 app 私有目录交给 Rust 侧：Android 系统 CA 会被拼成
/// `gitdeck_ca_bundle.pem` 落到那里，再用 `set_ssl_cert_file` 加载。
///
/// 为什么要绕这一圈：Android 的 CA 文件名是 MD5(subject)，而 OpenSSL 3.x 的
/// 哈希目录查找器按 SHA1 查找 —— 把 CA **目录**交给 libgit2
/// （`set_ssl_cert_dir`）在 Android 上永远找不到证书，且因为查找是惰性的，
/// `is_ok()` 还会返回成功（静默失效）。见 docs/13。
///
/// 必须早于任何远程操作；`main()` 的启动流程里调用。
Future<Map<String, dynamic>> setCaDir(String dir) async =>
    Map<String, dynamic>.from(
      await RustLib.call('setCaDir', {'dir': dir}) as Map,
    );

/// 逃生口：跳过 TLS 证书校验（**默认关闭**）。
/// 开启后等价于「无条件放行证书」的方案，任何中间人都无法被发现 —— 有风险，见 docs/13。
Future<Map<String, dynamic>> setSkipTlsVerify(bool skip) async =>
    Map<String, dynamic>.from(
      await RustLib.call('setSkipTlsVerify', {'skip': skip}) as Map,
    );

/// 信任库诊断：{ok, bundle, error, skipVerify, detail}。
Future<Map<String, dynamic>> tlsStatus() async =>
    Map<String, dynamic>.from(await RustLib.call('tlsStatus') as Map);

// ---- 导入自签 / 内网 CA ----
// 与「跳过证书校验」的区别：导入 CA 后**校验仍然开启**，只是多了一个信任锚 ——
// 这是自签仓库的正解；逃生口是最后手段。

/// 已导入的 CA 列表：{dir, items:[{id, label, count}]}。
Future<Map<String, dynamic>> caList() async =>
    Map<String, dynamic>.from(await RustLib.call('caList') as Map);

/// 导入一段 PEM（可含多张证书）。返回 {dir, items, imported}。
/// 导入后**当场生效**（无需重启）：Rust 侧重建 bundle 并重新 apply
/// （`set_ssl_cert_file` 是追加语义）。
Future<Map<String, dynamic>> caImport({
  required String label,
  required String pem,
}) async => Map<String, dynamic>.from(
  await RustLib.call('caImport', {'label': label, 'pem': pem}) as Map,
);

/// 删除一个已导入的 CA。
/// ⚠️ 当次进程内**不会**撤销信任（OpenSSL 的 store 只能加不能减），需重启应用。
Future<Map<String, dynamic>> caRemove(String id) async =>
    Map<String, dynamic>.from(await RustLib.call('caRemove', {'id': id}) as Map);
