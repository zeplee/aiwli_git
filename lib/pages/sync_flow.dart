import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/hosting_api.dart';
import '../core/operation.dart';
import '../core/prefs.dart';
import '../core/ssh_hosts.dart';
import '../core/url_util.dart';
import '../engine/ffi.dart' as engine;
import '../widgets/dialogs.dart';
import '../widgets/remote_dialogs.dart';

/// 「点击 → 结果」之间的空白（v1.5.20 补齐）。
///
/// 原来 [runSync] 从 `await engine.push(...)` 到 `showSnack` 之间没有任何状态
/// 变更，UI 拿不到任何可显示的中间事实——用户看到的就是「点了没反应」。
/// 现在所有进行状态与终态都进 [OperationController]，由工作台顶部的常驻
/// 操作条渲染：
/// - 点击即出现「进行中」，带**阶段文字**与**已用时间**；
/// - 同一时刻只允许一个写操作（并发推送同分支会互相踩：实测连点两次
///   真发出两次 push，第二次的链路抖动还被我误判成了证书问题）；
/// - 失败常驻并给「重试」，原始错误可展开长按复制。
///
/// 阶段粒度是诚实的：打点只落在**我们自己调用的步骤边界**上。「连接 /
/// 认证 / 上传」的细分需要 Rust 侧 progress 回调（docs/16 的 P2）——
/// 在此之前不假装知道引擎内部进度。

/// begin 时的粗粒度标题；解析出目标后再 [OperationController.retitle]。
const _opTitles = <String, String>{
  'pull': '拉取更新',
  'push': '推送提交',
  'fetch': '获取远程更新',
  'forcePush': '强制推送',
  'stash': '临时保存修改',
  'pushTag': '推送标签',
};

/// 同步操作流（拉取 / 推送 / 获取 / 强制推送 / stash），从工作台菜单与
/// 改动页按钮触发。
///
/// 与仓库卡片同一套交互约定：
/// - 缺少远程 → 弹窗引导绑定，成功后原操作自动继续；
/// - 推送目标远程 = 分支上游 > 唯一远程 > 选择器；
/// - 拉取缺少上游 → 绑定后自动设置跟踪；
/// - 任何变更完成后回调 [onChanged]（宿主据此刷新子页与角标）。
Future<void> runSync(
  BuildContext context, {
  required String repoPath,
  required String what,
  required VoidCallback onChanged,
  String? tag,
}) async {
  if (!context.mounted) return;
  final op = OperationController.instance;
  // 单飞：并发写同一分支会互相踩，且失败原因会被链路抖动掩盖。
  if (op.isRunning) {
    showSnack(context, '已有操作正在进行：${op.value.title}', error: true);
    return;
  }
  op.begin(_opTitles[what] ?? '同步操作');

  /// 重试入口。闭包捕获本次参数，但**每次调用前重新检查 mounted**——
  /// 否则用户切走仓库后再点「重试」会作用在已卸载的树上。
  void retry() {
    if (!context.mounted) return;
    runSync(context, repoPath: repoPath, what: what, onChanged: onChanged, tag: tag);
  }

  try {
    await _runSync(
      context,
      repoPath: repoPath,
      what: what,
      onChanged: onChanged,
      retry: retry,
      tag: tag,
    );
  } catch (e) {
    // _runSync 内部已按类型分类；这里兜住漏网的（对话框、快照等抛出的错）。
    if (isSshDecline(e)) {
      op.notice('已取消：未接受该主机的 SSH 指纹');
    } else {
      op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
    }
  } finally {
    // 兜底不变量：任何提前 return（用户取消、目标未就绪）都不允许把操作条
    // 永久留在「进行中」——那会同时锁死按钮，变成新的「点了没反应」。
    if (op.isRunning) op.dismiss();
  }
}

Future<void> _runSync(
  BuildContext context, {
  required String repoPath,
  required String what,
  required VoidCallback onChanged,
  required VoidCallback retry,
  String? tag,
}) async {
  final op = OperationController.instance;
  op.phase('读取凭据…');
  final fallbackCred = await Prefs.instance.credentials();
  if (!context.mounted) return;
  // Resolve credentials from the actual upstream URL for pull too. The
  // fallback remains available for repositories whose remote cannot be read.
  Future<Map<String, Object?>?> credForCurrentRemote() async {
    try {
      final bs = await engine.branches(path: repoPath);
      final current = bs.local.firstWhere(
        (b) => b.isCurrent,
        orElse: () => bs.local.first,
      );
      final upstream = current.upstream;
      if (upstream != null && upstream.contains('/')) {
        final remoteName = upstream.split('/').first;
        final rs = await engine.remotes(path: repoPath);
        final r = rs.firstWhere((x) => x.name == remoteName);
        return await Prefs.instance.credentialsForUrl(r.url);
      }
    } catch (_) {}
    return fallbackCred;
  }

  switch (what) {
    case 'pushTag':
      final tagName = (tag ?? '').trim();
      if (tagName.isEmpty) {
        op.fail('缺少标签名');
        return;
      }
      op.phase('读取远程列表…');
      var tagRemotes = <engine.RemoteInfo>[];
      try {
        tagRemotes = await engine.remotes(path: repoPath);
      } catch (e) {
        op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
        return;
      }
      if (!context.mounted) return;
      if (tagRemotes.isEmpty) {
        final bound = await bindRemoteDialog(context, repoPath);
        if (!bound) return; // 用户取消
        if (!context.mounted) return;
        try {
          tagRemotes = await engine.remotes(path: repoPath);
        } catch (_) {}
        if (tagRemotes.isEmpty) return;
      }
      if (!context.mounted) return;
      op.phase('确认推送目标…');
      final tagRemote = await resolveTargetRemote(context, repoPath, tagRemotes);
      if (tagRemote == null) return; // 用户取消选择器
      if (!context.mounted) return;
      op.retitle('推送标签 $tagName → $tagRemote');
      op.phase('读取凭据…');
      final tagCred = await Prefs.instance.credentialsForUrl(
        tagRemotes.firstWhere((r) => r.name == tagRemote).url,
      );
      if (!context.mounted) return;
      try {
        op.phase('检查 SSH 主机…');
        final kh = await knownHostsPath();
        if (!context.mounted) return;
        op.phase('连接远程并上传…');
        await runSshGuarded<String>(
          context,
          (a) => engine.tagPush(
            path: repoPath,
            remote: tagRemote,
            name: tagName,
            cred: tagCred,
            knownHostsPath: kh,
            acceptUnknownHost: a,
          ),
        );
        op.succeed('已推送标签 $tagName → $tagRemote');
        onChanged();
      } catch (e) {
        if (isSshDecline(e)) {
          op.notice('已取消：未接受该主机的 SSH 指纹');
        } else {
          op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
        }
      }
    case 'pull':
      op.phase('确认上游分支…');
      final branch = await currentBranch(repoPath);
      if (branch.isEmpty || branch == '(detached)') {
        op.fail('分离 HEAD，无法拉取：先检出一个分支再拉取。');
        return;
      }
      if (!context.mounted) return;
      final ok = await ensurePullTarget(
        context,
        repoPath,
        branch: branch,
        cred: fallbackCred,
      );
      // 上游未就绪：ensurePullTarget 内部对「设置跟踪失败」已给具体原因，
      // 这里不再叠一层文案，交给 finally 收起操作条。
      if (!ok) return;
      if (!context.mounted) return;
      try {
        op.phase('连接远程并合并…');
        final r = await engine.pull(
          path: repoPath,
          cred: await credForCurrentRemote(),
        );
        if (r.upToDate) {
          op.succeed('已经是最新');
        } else if (r.conflicts.isNotEmpty) {
          op.fail(
            '拉取产生 ${r.conflicts.length} 个冲突，请在改动页解决',
            onRetry: retry,
          );
        } else {
          op.succeed(r.fastForward ? '拉取完成（快进合并）' : '拉取完成');
        }
        onChanged();
      } catch (e) {
        if (isSshDecline(e)) {
          op.notice('已取消：未接受该主机的 SSH 指纹');
        } else {
          op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
        }
      }
    case 'push':
      op.phase('读取远程列表…');
      var remotes = <engine.RemoteInfo>[];
      try {
        remotes = await engine.remotes(path: repoPath);
      } catch (e) {
        op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
        return;
      }
      if (!context.mounted) return;
      if (remotes.isEmpty) {
        final bound = await bindRemoteDialog(context, repoPath);
        if (!bound) return; // 用户取消
        if (!context.mounted) return;
        try {
          remotes = await engine.remotes(path: repoPath);
        } catch (_) {}
        if (remotes.isEmpty) return;
      }
      final branch = await currentBranch(repoPath);
      if (branch.isEmpty || branch == '(detached)') {
        op.fail('分离 HEAD，无法推送：先检出一个分支再推送。');
        return;
      }
      if (!context.mounted) return;
      op.phase('确认推送目标…');
      final remote = await resolveTargetRemote(
        context,
        repoPath,
        remotes,
        branch: branch,
      );
      if (remote == null) return; // 用户取消选择器
      if (!context.mounted) return;
      op.retitle('推送 $branch → $remote');
      op.phase('读取凭据…');
      final remoteUrl = remotes.firstWhere((r) => r.name == remote).url;
      final cred = await Prefs.instance.credentialsForUrl(remoteUrl);
      if (!context.mounted) return;
      // 推送前预检（v1.5.24）：令牌明确缺 workflow、且这次确实动了
      // .github/workflows/ 时提前拦下 —— 否则要等几十秒上传跑完才被服务端拒绝，
      // 而旧版连这个拒绝都看不到（显示成「推送成功」）。
      op.phase('检查推送前置条件…');
      final proceed = await preflightWorkflowPush(
        context,
        repoPath: repoPath,
        remoteName: remote,
        remoteUrl: remoteUrl,
        branch: branch,
      );
      if (!proceed) {
        op.notice('已取消：远端会拒绝含 workflow 文件的更新，先补令牌权限');
        return;
      }
      if (!context.mounted) return;
      try {
        op.phase('检查 SSH 主机…');
        final kh = await knownHostsPath();
        if (!context.mounted) return;
        op.phase('连接远程并上传…');
        await runSshGuarded<String>(
          context,
          (a) => engine.push(
            path: repoPath,
            remote: remote,
            branch: branch,
            setUpstream: true,
            cred: cred,
            knownHostsPath: kh,
            acceptUnknownHost: a,
          ),
        );
        op.succeed('已推送 $branch → $remote');
        onChanged();
      } catch (e) {
        if (isSshDecline(e)) {
          op.notice('已取消：未接受该主机的 SSH 指纹');
        } else {
          op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
        }
      }
    case 'fetch':
      op.phase('读取远程列表…');
      var remotes = <engine.RemoteInfo>[];
      try {
        remotes = await engine.remotes(path: repoPath);
      } catch (e) {
        op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
        return;
      }
      if (!context.mounted) return;
      if (remotes.isEmpty) {
        final bound = await bindRemoteDialog(context, repoPath);
        if (!bound) return; // 用户取消
        if (!context.mounted) return;
        try {
          remotes = await engine.remotes(path: repoPath);
        } catch (_) {}
        if (remotes.isEmpty) return;
      }
      if (!context.mounted) return;
      op.phase('确认远程…');
      final remote = await resolveTargetRemote(context, repoPath, remotes);
      if (remote == null) return; // 用户取消选择器
      if (!context.mounted) return;
      op.retitle('获取 $remote');
      op.phase('读取凭据…');
      final selectedRemote = remotes.firstWhere((r) => r.name == remote);
      final cred = await Prefs.instance.credentialsForUrl(selectedRemote.url);
      try {
        op.phase('检查 SSH 主机…');
        final kh = await knownHostsPath();
        if (!context.mounted) return;
        op.phase('下载远程更新…');
        await runSshGuarded<String>(
          context,
          (a) => engine.fetch(
            path: repoPath,
            remote: remote,
            cred: cred,
            knownHostsPath: kh,
            acceptUnknownHost: a,
          ),
        );
        op.succeed('已获取 $remote');
        onChanged();
      } catch (e) {
        if (isSshDecline(e)) {
          op.notice('已取消：未接受该主机的 SSH 指纹');
        } else {
          op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
        }
      }
    case 'forcePush':
      op.phase('读取远程列表…');
      var remotes = <engine.RemoteInfo>[];
      try {
        remotes = await engine.remotes(path: repoPath);
      } catch (e) {
        op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
        return;
      }
      if (!context.mounted) return;
      if (remotes.isEmpty) {
        op.fail('还没有配置远程仓库：先在「远程与仓库设置」里添加。');
        return;
      }
      final branch = await currentBranch(repoPath);
      if (branch.isEmpty || branch == '(detached)') {
        op.fail('分离 HEAD，无法推送：先检出一个分支再推送。');
        return;
      }
      if (!context.mounted) return;
      op.phase('确认推送目标…');
      final remote = await resolveTargetRemote(
        context,
        repoPath,
        remotes,
        branch: branch,
      );
      if (remote == null) return; // 用户取消选择器
      if (!context.mounted) return;
      op.retitle('强制推送 $branch → $remote');
      op.phase('读取凭据…');
      final cred = await Prefs.instance.credentialsForUrl(
        remotes.firstWhere((r) => r.name == remote).url,
      );
      if (!context.mounted) return;
      op.phase('等待确认…');
      if (!await confirmDialog(
        context,
        '强制推送',
        '将用本地 $branch 覆盖远程 $remote 的 $branch，远程上未被本地包含的提交会丢失。确定？',
        action: '强制推送',
        danger: true,
      )) {
        return; // 用户取消
      }
      try {
        op.phase('检查 SSH 主机…');
        final kh = await knownHostsPath();
        if (!context.mounted) return;
        op.phase('连接远程并强制上传…');
        await runSshGuarded<String>(
          context,
          (a) => engine.push(
            path: repoPath,
            remote: remote,
            branch: branch,
            setUpstream: false,
            force: true,
            cred: cred,
            knownHostsPath: kh,
            acceptUnknownHost: a,
          ),
        );
        op.succeed('已强制推送 $branch → $remote');
        onChanged();
      } catch (e) {
        if (isSshDecline(e)) {
          op.notice('已取消：未接受该主机的 SSH 指纹');
        } else {
          op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
        }
      }
    case 'stash':
      op.phase('输入说明…');
      final msg = await textDialog(context, 'Stash 说明（可空）', hint: 'WIP …');
      if (msg == null) return; // 用户取消
      if (!context.mounted) return;
      try {
        op.phase('保存工作区…');
        await engine.stashPush(
          path: repoPath,
          message: msg.isEmpty ? null : msg,
        );
        op.succeed('已 stash');
        onChanged();
      } catch (e) {
        op.fail(friendlyError(e), rawError: '$e', onRetry: retry);
      }
  }
}

/// 当前分支名（快照引擎）；空仓库 / 分离 HEAD 返回空串或 '(detached)'。
/// 用系统浏览器打开外链（走 App 已有的 gitdeck/sys 通道，无新依赖）。
Future<void> _openExternalUrl(String url) async {
  const ch = MethodChannel('gitdeck/sys');
  try {
    await ch.invokeMethod('openUrl', {'url': url});
  } catch (_) {}
}

/// 列出这次推送会触及的 `.github/workflows/` 文件（空 = 不涉及或判不出来）。
///
/// 先与远端对应分支做一次真实 diff（最准）；远端还没有这个分支时（空远端 /
/// 首次推送），「要推的就是全部历史」，于是退化为「HEAD 工作区里是否存在这些
/// 文件」。两步都失败就返回空 —— 预检宁可漏报，不假报警。
Future<List<String>> pushedFilesTouchWorkflow({
  required String repoPath,
  required String remoteName,
  required String branch,
}) async {
  const prefix = '.github/workflows/';
  bool hit(String p) => p.replaceAll('\\', '/').startsWith(prefix);
  try {
    final entries = await engine.diffRevs(
      path: repoPath,
      from: '$remoteName/$branch',
      to: 'HEAD',
    );
    return [
      for (final e in entries)
        if (hit(e.path)) e.path,
    ];
  } catch (_) {
    // 远端没有该分支（或 diff 不可用）→ 走下面的工作区兜底。
  }
  try {
    final root = Directory('$repoPath/.github/workflows');
    if (!root.existsSync()) return const [];
    final out = <String>[];
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is File) {
        final rel = e.path.replaceAll('\\', '/');
        final i = rel.indexOf(prefix);
        if (i >= 0) out.add(rel.substring(i));
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 推送前预检：这次推送会不会被 GitHub 因为「令牌缺 workflow 权限」拒绝。
///
/// 判定刻意保守 —— 只有**确定性证据**齐全才拦人：
/// 1. 远端是 github.com；
/// 2. 凭据是 HTTP 令牌（SSH 不走 scope 体系，直接放行）；
/// 3. GitHub 明确回显的 scope 里**没有** `workflow`；
/// 4. 待推送的提交里**确实**动了 `.github/workflows/`。
///
/// 任何一步拿不到确定答案（问不到 scope、diff 失败、网络抖动）一律**放行**：
/// 预检是提示，不是门禁；权威判定在 Rust 侧的服务端核对（1.5.23 起）。
///
/// 返回 true = 继续推送；false = 用户选择先补权限。
Future<bool> preflightWorkflowPush(
  BuildContext context, {
  required String repoPath,
  required String remoteName,
  required String remoteUrl,
  required String branch,
}) async {
  try {
    if ((hostFromUrl(remoteUrl) ?? '').toLowerCase() != 'github.com') return true;
    final cred = await Prefs.instance.credentialsForUrl(remoteUrl);
    final keyPath = cred?['keyPath'] as String?;
    if (keyPath != null && keyPath.isNotEmpty) return true; // SSH
    final token = cred?['pass'] as String?;
    if (token == null || token.isEmpty) return true;

    if ((await ghTokenInfo(token)).canPushWorkflow != false) return true;

    final touched = await pushedFilesTouchWorkflow(
      repoPath: repoPath,
      remoteName: remoteName,
      branch: branch,
    );
    if (touched.isEmpty) return true;
    if (!context.mounted) return true;

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这次推送会被拒绝', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '待推提交动了 ${touched.length} 个 workflow 文件：',
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              for (final p in touched.take(5))
                Text(
                  '· $p',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                  ),
                ),
              if (touched.length > 5)
                Text(
                  '…另有 ${touched.length - 5} 个',
                  style: const TextStyle(fontSize: 11.5),
                ),
              const SizedBox(height: 10),
              const Text(
                '当前令牌没有 workflow 权限。GitHub 的硬规矩：令牌缺 workflow '
                'scope 时，workflow 文件的创建/更新会被服务端拒绝，'
                '而且拒绝的是整条引用更新。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              const Text(
                '（旧版本会把这个拒绝显示成「推送成功」——远端其实一个字节都没收到。）',
                style: TextStyle(fontSize: 11.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('先补权限'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx, false);
              _openExternalUrl(ghNewTokenUri().toString());
            },
            child: const Text('预勾选令牌页'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('仍然尝试'),
          ),
        ],
      ),
    );
    return go ?? false;
  } catch (_) {
    return true; // 预检自身出错绝不阻断推送
  }
}

Future<String> currentBranch(String repoPath) async {
  try {
    final snap = await engine.getSnapshot(path: repoPath, commitLimit: 1);
    return snap.branch;
  } catch (_) {
    return '';
  }
}