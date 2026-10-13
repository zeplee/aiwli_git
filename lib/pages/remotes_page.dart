import 'package:flutter/material.dart';

import '../core/prefs.dart';
import '../core/ssh_hosts.dart';
import '../engine/ffi.dart' as engine;
import '../widgets/dialogs.dart';

/// Remotes + credentials + repo identity (user.name/email) + .gitignore.
/// 满高底部弹层（v1.4.2 起不再是推入的二级页），下拉即可关闭。
class RemotesSheet extends StatefulWidget {
  final String repoPath;
  final int tick; // kept for interface parity; opened fresh each time
  final VoidCallback onMutated;
  const RemotesSheet({
    super.key,
    required this.repoPath,
    this.tick = 0,
    required this.onMutated,
  });
  @override
  State<RemotesSheet> createState() => _RemotesPageState();
}

class _RemotesPageState extends State<RemotesSheet> {
  List<engine.RemoteInfo>? _remotes;
  engine.ConfigInfo? _cfg;
  Map<String, Object?>? _cred;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    try {
      final r = await engine.remotes(path: widget.repoPath);
      final c = await engine.configGet(path: widget.repoPath);
      final cred = r.isEmpty
          ? await Prefs.instance.credentials()
          : await Prefs.instance.credentialsForUrl(r.first.url);
      if (!mounted) return;
      setState(() {
        _remotes = r;
        _cfg = c;
        _cred = cred;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  void _act(Future<void> Function() f, {String ok = ''}) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await f();
      if (ok.isNotEmpty && mounted) showSnack(context, ok);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _reload();
  }

  Future<void> _addRemote() async {
    final name = await textDialog(
      context,
      '远程名称',
      initial: 'origin',
      hint: 'origin / upstream',
    );
    if (!mounted) return;
    if (name == null || name.trim().isEmpty) return;
    final url = await textDialog(
      context,
      '远程 URL',
      hint: 'https://github.com/user/repo.git 或 git@github.com:user/repo.git',
    );
    if (!mounted) return;
    if (url == null || url.trim().isEmpty) return;
    _act(
      () => engine.remoteAdd(
        path: widget.repoPath,
        name: name.trim(),
        url: url.trim(),
      ),
      ok: '已添加远程 ${name.trim()}',
    );
  }

  Future<void> _editRemote(engine.RemoteInfo r) async {
    final url = await textDialog(context, '修改 ${r.name} 的 URL', initial: r.url);
    if (!mounted) return;
    if (url == null || url.trim().isEmpty || url.trim() == r.url) return;
    _act(
      () => engine.remoteSetUrl(
        path: widget.repoPath,
        name: r.name,
        url: url.trim(),
      ),
      ok: '已更新 ${r.name}',
    );
  }

  Future<void> _deleteRemote(engine.RemoteInfo r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除远程？', style: TextStyle(fontSize: 16)),
        content: Text(
          '将移除远程 ${r.name} 及其跟踪配置（本地提交不受影响）',
          style: const TextStyle(fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      _act(
        () => engine.remoteDelete(path: widget.repoPath, name: r.name),
        ok: '已删除 ${r.name}',
      );
    }
  }

  Future<void> _editCred() async {
    final user = await textDialog(
      context,
      '用户名',
      initial: (_cred?['user'] as String?) ?? '',
      hint: 'git / 用户名',
    );
    if (!mounted) return;
    if (user == null) return;
    final pass = await textDialog(
      context,
      '令牌 / 密码（HTTPS）\nSSH 私钥路径也可以填这里下方',
      initial: (_cred?['pass'] as String?) ?? '',
      hint: 'ghp_xxx（加密后仅存本机）',
    );
    if (!mounted) return;
    if (pass == null) return;
    final key = await textDialog(
      context,
      'SSH 私钥路径（可选）',
      initial: (_cred?['keyPath'] as String?) ?? '',
      hint: '/sdcard/keys/id_ed25519',
    );
    if (!mounted) return;
    if (key == null) return;
    final passphrase = await textDialog(
      context,
      '私钥口令（可选）',
      initial: (_cred?['passphrase'] as String?) ?? '',
    );
    if (!mounted) return;
    if (passphrase == null) return;
    await Prefs.instance.setCredentials({
      if (user.isNotEmpty) 'user': user,
      if (pass.isNotEmpty) 'pass': pass,
      if (key.isNotEmpty) 'keyPath': key,
      if (passphrase.isNotEmpty) 'passphrase': passphrase,
    });
    final c = await Prefs.instance.credentials();
    setState(() => _cred = c);
    if (mounted) showSnack(context, '凭据已加密保存到本机');
  }

  Future<void> _editIdentity() async {
    final name = await textDialog(
      context,
      'user.name',
      initial: _cfg?.userName ?? '',
    );
    if (!mounted) return;
    if (name == null) return;
    final email = await textDialog(
      context,
      'user.email',
      initial: _cfg?.userEmail ?? '',
    );
    if (!mounted) return;
    if (email == null) return;
    _act(
      () => engine.configSet(
        path: widget.repoPath,
        userName: name,
        userEmail: email,
      ),
      ok: '已保存',
    );
  }

  Future<void> _editGitignore() async {
    final cur = await engine.ignoreGet(path: widget.repoPath);
    if (!mounted) return;
    final next = await textDialog(
      context,
      '编辑 .gitignore',
      initial: cur,
      maxLines: 8,
    );
    if (!mounted) return;
    if (next == null) return;
    _act(
      () => engine.ignoreSet(path: widget.repoPath, content: next),
      ok: '已保存 .gitignore',
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ---- 头部：标题 ----
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
          child: Row(
            children: [
              Icon(Icons.cloud_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '远程与仓库设置',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_error!, textAlign: TextAlign.center),
                      ),
                      OutlinedButton(
                        onPressed: _reload,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _busy
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    // remotes
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '远程仓库',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: cs.primary,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '添加远程',
                          icon: const Icon(Icons.add, size: 20),
                          onPressed: _busy ? null : _addRemote,
                        ),
                      ],
                    ),
                    ...(_remotes ?? []).map(
                      (r) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.cloud, size: 18),
                        title: Text(
                          r.name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          r.url,
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        onLongPress: _busy ? null : () => _editRemote(r),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Fetch',
                              icon: const Icon(Icons.cloud_download, size: 20),
                              onPressed: () => _act(() async {
                                final kh = await knownHostsPath();
                                if (!context.mounted) return;
                                await runSshGuarded<String>(
                                  context,
                                  (a) async => engine.fetch(
                                    path: widget.repoPath,
                                    remote: r.name,
                                    cred: await Prefs.instance
                                        .credentialsForUrl(r.url),
                                    knownHostsPath: kh,
                                    acceptUnknownHost: a,
                                  ),
                                );
                              }, ok: '已获取 ${r.name}'),
                            ),
                            IconButton(
                              tooltip: '编辑 URL',
                              icon: const Icon(Icons.edit, size: 18),
                              onPressed: _busy ? null : () => _editRemote(r),
                            ),
                            IconButton(
                              tooltip: '删除远程',
                              icon: Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: cs.error,
                              ),
                              onPressed: _busy ? null : () => _deleteRemote(r),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if ((_remotes ?? []).isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          '（无远程）',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ),
                    const Divider(height: 20),
                    // compatibility fallback credentials; normal account mapping lives in App Settings
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.key, size: 20),
                      title: const Text(
                        '兼容同步凭据',
                        style: TextStyle(fontSize: 13.5),
                      ),
                      subtitle: Text(
                        _cred == null
                            ? '未配置；优先使用「应用设置 → 代码托管账号」'
                            : '仅在没有匹配托管账号时作为后备（${_cred!.keys.join(", ")})',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_cred != null)
                            TextButton(
                              onPressed: () async {
                                final ok = await confirmDialog(
                                  context,
                                  '清除凭据',
                                  '删除本机保存的凭据？已配置的远程不受影响。',
                                  action: '清除',
                                  danger: true,
                                );
                                if (ok) {
                                  _act(() async {
                                    await Prefs.instance.setCredentials(null);
                                  }, ok: '已清除凭据');
                                }
                              },
                              child: const Text(
                                '清除',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.red,
                                ),
                              ),
                            ),
                          TextButton(
                            onPressed: _editCred,
                            child: const Text(
                              '编辑',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 20),
                    // identity
                    Text(
                      '仓库身份（提交作者）',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: cs.primary,
                      ),
                    ),
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person, size: 20),
                      title: Text(
                        '${_cfg?.userName.isNotEmpty == true ? _cfg!.userName : "（未设置）"}  <${_cfg?.userEmail ?? ""}>',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      trailing: TextButton(
                        onPressed: _editIdentity,
                        child: const Text('编辑', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const Divider(height: 20),
                    // gitignore
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.block, size: 20),
                      title: const Text(
                        '.gitignore',
                        style: TextStyle(fontSize: 13.5),
                      ),
                      trailing: TextButton(
                        onPressed: _editGitignore,
                        child: const Text('编辑', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                    const Divider(height: 20),
                    Text(
                      '仓库路径',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: cs.primary,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: SelectableText(
                        widget.repoPath,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
