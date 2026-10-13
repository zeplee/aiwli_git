import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/hosting_api.dart';
import '../core/prefs.dart';
import '../core/ssh_hosts.dart';
import '../engine/ffi.dart' as engine;
import '../widgets/dialogs.dart';

/// 远程仓库名合法字符：字母数字点下划线连字符
/// （GitHub / GitLab / Codeup 的通用安全子集，避免特殊字符注入路径）。
bool validRepoName(String name) {
  if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) return false;
  return name != '.' && name != '..'; // 防路径穿越点段
}

/// 把本地仓库发布为远程新仓库：选账号 → 同名检查 → 远程建仓 → 设 origin →
/// 推送当前分支。远程已存在同名仓库时询问是否直接推送到现有仓库。
Future<void> showPublishSheet(BuildContext context, String repoPath) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PublishSheet(repoPath: repoPath),
  );
}

class _PublishSheet extends StatefulWidget {
  final String repoPath;
  const _PublishSheet({required this.repoPath});

  @override
  State<_PublishSheet> createState() => _PublishSheetState();
}

class _PublishSheetState extends State<_PublishSheet> {
  late final TextEditingController _nameCtrl = TextEditingController(
    text: widget.repoPath.split('/').last,
  );
  bool _private = true;
  bool _busy = false;
  List<Map<String, Object?>> _accounts = [];
  Map<String, Object?>? _picked;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final list = await Prefs.instance.accounts();
    if (!mounted) return;
    setState(() {
      _accounts = list;
      _picked = list.isNotEmpty ? list.first : null;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  String get _provider => accountProvider(_picked ?? const {});

  Future<void> _publish() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || !validRepoName(name)) {
      showSnack(context, '仓库名只能用字母、数字、点、下划线、连字符', error: true);
      return;
    }
    final account = _picked;
    if (account == null) {
      showSnack(context, '请先绑定云端账号（添加仓库 → 添加远程）', error: true);
      return;
    }
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 0) 本地得有提交可推
      final br = await engine.branches(path: widget.repoPath);
      if (br.local.isEmpty) {
        setState(() => _busy = false);
        if (mounted) {
          showSnack(context, '该仓库还没有任何提交，先提交一次再发布', error: true);
        }
        return;
      }
      final branch = br.current;

      // 1) 同名检查：远程已有同名仓库 → 询问是否直接推送
      String url;
      CloudRepo? existing;
      try {
        final repos = await listCloudRepos(account);
        existing = repos
            .where(
              (r) => r.name == name || r.fullName.split('/').last == name,
            )
            .cast<CloudRepo?>()
            .firstOrNull;
      } catch (_) {
        // 检查失败不阻塞：创建接口的 422 会兜底报“已存在”
      }
      if (!mounted) return;
      if (existing != null && existing.httpsUrl.isNotEmpty) {
        final ok = await confirmDialog(
          context,
          '远程已有同名仓库',
          '${_providerLabel()} 上已存在 ${existing.fullName}，将不新建，'
          '直接把当前分支推送到该仓库。',
          action: '推送到现有仓库',
        );
        if (!ok) {
          setState(() => _busy = false);
          return;
        }
        url = existing.httpsUrl;
      } else {
        // 2) 远程建仓
        final created = await createCloudRepo(
          account,
          name,
          isPrivate: _private,
        );
        url = created.httpsUrl;
        if (url.isEmpty) throw HostingException('创建成功但未返回仓库地址');
      }

      // 3) 设 origin（已有则改地址）
      final remotes = await engine.remotes(path: widget.repoPath);
      if (remotes.any((r) => r.name == 'origin')) {
        await engine.remoteSetUrl(
          path: widget.repoPath,
          name: 'origin',
          url: url,
        );
      } else {
        await engine.remoteAdd(
          path: widget.repoPath,
          name: 'origin',
          url: url,
        );
      }

      // 4) 推送当前分支并设上游
      final cred = await Prefs.instance.credentialsForUrl(url);
      final kh = await knownHostsPath();
      await engine.push(
        path: widget.repoPath,
        remote: 'origin',
        branch: branch,
        setUpstream: true,
        cred: cred,
        knownHostsPath: kh,
        acceptUnknownHost: false,
      );

      if (!mounted) return;
      setState(() => _busy = false);
      navigator.pop();
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(
        SnackBar(content: Text('已发布 $branch → $url（地址已复制）')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, friendlyError(e), error: true);
    }
  }

  String _providerLabel() {
    switch (_provider) {
      case 'github':
        return 'GitHub';
      case 'codeup':
        return '云效';
      default:
        return 'GitLab';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 14,
          bottom: 14 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_upload_outlined, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                const Text(
                  '发布到云端',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  widget.repoPath.split('/').last,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameCtrl,
              enabled: !_busy,
              onChanged: (_) => setState(() {}), // 让底部提示实时跟随名称
              decoration: const InputDecoration(
                labelText: '远程仓库名',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 13.5),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Text('可见性：', style: TextStyle(fontSize: 12.5)),
                ChoiceChip(
                  label: const Text('私有', style: TextStyle(fontSize: 12)),
                  selected: _private,
                  onSelected: _busy ? null : (_) => setState(() => _private = true),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('公开', style: TextStyle(fontSize: 12)),
                  selected: !_private,
                  onSelected: _busy ? null : (_) => setState(() => _private = false),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '账号（将在该账号下建仓库）',
              style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            if (_accounts.isEmpty)
              Text(
                '还没有绑定云端账号：添加仓库 → 添加远程 里绑定 GitHub / GitLab / 云效后再来发布。',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              )
            else
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final a in _accounts)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            '${accountProvider(a) == 'github' ? 'GitHub' : accountProvider(a) == 'codeup' ? '云效' : 'GitLab'}'
                            ' · ${accountLabel(a)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: _picked == a,
                          onSelected: _busy
                              ? null
                              : (_) => setState(() => _picked = a),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Text(
              '将创建${_private ? '私有' : '公开'}仓库「${_nameCtrl.text.trim()}」'
              '并推送当前分支；远程已有同名仓库时会先询问。',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _publish,
                icon: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.rocket_launch_outlined, size: 17),
                label: Text(
                  _busy ? '正在创建并推送…' : '创建并推送',
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
