import 'package:flutter/material.dart';

import '../core/ssh_hosts.dart';
import '../core/prefs.dart';
import '../engine/ffi.dart' as engine;
import 'dialogs.dart';

/// Remote-binding flows shared by the repos page and the workbench sync menu.
///
/// 「拉取/推送但还没有远程」不再只报错：先弹窗引导绑定，成功后原操作自动继续。
/// 多远程也在这里收口：推送目标 = 分支上游 > 唯一远程 > 选择器。

/// 绑定远程仓库弹窗（名称 + URL）。返回 true 表示已成功添加。
Future<bool> bindRemoteDialog(
  BuildContext context,
  String repoPath, {
  String? title,
}) async {
  final nameCtrl = TextEditingController(text: 'origin');
  final urlCtrl = TextEditingController();
  var ok = false;
  String name = '';
  String url = '';
  try {
    ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(
              title ?? '绑定远程仓库',
              style: const TextStyle(fontSize: 16),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '远程名称',
                      hintText: 'origin / upstream / fork',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: urlCtrl,
                    decoration: const InputDecoration(
                      labelText: '远程 URL',
                      hintText: 'https://github.com/user/repo.git',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '绑定后即可拉取 / 推送；多远程可随时在「远程与仓库设置」增删。',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('绑定'),
              ),
            ],
          ),
        ) ==
        true;
    // capture before dispose — a disposed controller must not be read.
    name = nameCtrl.text.trim();
    url = urlCtrl.text.trim();
  } finally {
    nameCtrl.dispose();
    urlCtrl.dispose();
  }
  if (!ok || !context.mounted) return false;
  if (name.isEmpty || url.isEmpty) {
    showSnack(context, '远程名称和 URL 不能为空', error: true);
    return false;
  }
  try {
    await engine.remoteAdd(path: repoPath, name: name, url: url);
    if (context.mounted) showSnack(context, '已绑定远程 $name');
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(e), error: true);
    return false;
  }
}

/// 多远程选择器（SimpleDialog 列表）。
Future<String?> pickRemoteDialog(
  BuildContext context,
  List<engine.RemoteInfo> remotes,
) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('选择远程仓库', style: TextStyle(fontSize: 14)),
      children: [
        for (final r in remotes)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, r.name),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.cloud, size: 18),
              title: Text(r.name, style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                r.url,
                style: const TextStyle(fontSize: 10),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    ),
  );
}

/// 推送/获取的目标远程：分支已绑定上游 → 用上游远程；唯一远程 → 直接用；
/// 多远程且无上游 → 让用户选。
Future<String?> resolveTargetRemote(
  BuildContext context,
  String repoPath,
  List<engine.RemoteInfo> remotes, {
  String? branch,
}) async {
  if (remotes.length == 1) return remotes.first.name;
  try {
    final bs = await engine.branches(path: repoPath);
    final up = branch == null
        ? bs.local.where((b) => b.isCurrent).firstOrNull?.upstream
        : bs.local.where((b) => b.name == branch).firstOrNull?.upstream;
    if (up != null && up.isNotEmpty) {
      final r = up.split('/').first;
      if (remotes.any((x) => x.name == r)) return r;
    }
  } catch (_) {}
  if (!context.mounted) return null;
  return pickRemoteDialog(context, remotes);
}

/// 拉取前置检查：确保远程与上游存在；缺失时引导绑定 / 设置上游。
/// 返回是否可以继续 pull（上游已就绪）。
Future<bool> ensurePullTarget(
  BuildContext context,
  String repoPath, {
  required String branch,
  required Map<String, Object?>? cred,
}) async {
  if (branch.isEmpty || branch == '(detached)') return false;
  final remotes = await engine.remotes(path: repoPath);
  if (!context.mounted) return false;
  if (remotes.isEmpty) {
    final bound = await bindRemoteDialog(context, repoPath);
    if (!bound) return false;
  }
  // 分支还没有上游 → 绑定/选择远程后先 fetch 再设置跟踪：
  // refs/remotes/<remote>/<branch> 存在后高层 set_upstream 才能成功，
  // 拉取内部的合并也才有目标可对。
  final bs = await engine.branches(path: repoPath);
  final cur = bs.local.where((b) => b.isCurrent).firstOrNull;
  final hasUpstream = cur?.upstream != null && cur!.upstream!.isNotEmpty;
  if (!hasUpstream) {
    final rs = await engine.remotes(path: repoPath);
    if (!context.mounted) return false;
    final remote = await resolveTargetRemote(context, repoPath, rs);
    if (remote == null) return false;
    try {
      final kh = await knownHostsPath();
      if (!context.mounted) return false;
      final selected = rs.firstWhere((x) => x.name == remote);
      final selectedCred = await Prefs.instance.credentialsForUrl(selected.url);
      if (!context.mounted) return false;
      await runSshGuarded<String>(
        context,
        (a) => engine.fetch(
          path: repoPath,
          remote: remote,
          cred: selectedCred ?? cred,
          knownHostsPath: kh,
          acceptUnknownHost: a,
        ),
      );
    } catch (_) {
      // fetch 失败（如无网络）不阻断：config 级兜底仍会设置跟踪，
      // pull 阶段会给出自己的明确错误。
    }
    try {
      await engine.branchSetUpstream(
        path: repoPath,
        branch: branch,
        upstream: '$remote/$branch',
      );
      if (context.mounted) {
        showSnack(context, '已设置跟踪：$branch → $remote/$branch');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, friendlyError(e), error: true);
      return false;
    }
  }
  return true;
}
