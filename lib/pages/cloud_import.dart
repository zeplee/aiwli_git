import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/hosting_api.dart';
import '../core/prefs.dart';
import '../core/platform_paths.dart';
import '../core/ssh_hosts.dart';
import '../engine/ffi.dart' as engine;
import '../widgets/dialogs.dart';

/// 添加远程（原「云端导入」）：顶部地址栏可克隆任意 Git URL（公开仓库
/// 免凭据，SSH 走守卫）；下方 GitHub / GitLab / 云效 Codeup 绑定账号 →
/// 仓库列表 → 一键克隆。
/// 入口：侧栏「＋ 添加仓库 → 添加远程」与空态页「添加远程」。
class CloudImportSheet extends StatefulWidget {
  const CloudImportSheet({super.key});
  @override
  State<CloudImportSheet> createState() => _CloudImportSheetState();
}

class _CloudImportSheetState extends State<CloudImportSheet> {
  List<Map<String, Object?>>? _accounts;
  Map<String, Object?>? _picked;
  Future<List<CloudRepo>>? _reposFuture;
  final _urlCtrl = TextEditingController();
  bool _cloning = false;
  bool _creating = false;
  String _kind = 'all'; // all | starred | forked

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final all = await Prefs.instance.accounts();
    final usable = [
      for (final a in all)
        if (supportsCloudImport(a)) a,
    ];
    if (!mounted) return;
    setState(() {
      _accounts = usable;
      if (usable.isNotEmpty) {
        _picked = usable.first;
        _reposFuture = _fetch(usable.first);
      }
    });
  }

  /// 按当前类别拉取：starred 走平台星标端点；forked 用仓库自带 fork 标记
  /// 客户端过滤（GitHub `fork` / GitLab `forked_from_project`）。
  Future<List<CloudRepo>> _fetch(Map<String, Object?> account) async {
    if (_kind == 'starred') {
      return listCloudRepos(account, starred: true);
    }
    final repos = await listCloudRepos(account);
    return _kind == 'forked' ? repos.where((r) => r.isFork).toList() : repos;
  }

  void _pick(Map<String, Object?> a) {
    setState(() {
      _picked = a;
      _reposFuture = _fetch(a);
    });
  }

  void _pickKind(String k) {
    if (_kind == k || _picked == null) return;
    setState(() {
      _kind = k;
      _reposFuture = _fetch(_picked!);
    });
  }

  /// 克隆公共动线：确认 → 同域凭据 → SSH 守卫 → 克隆 → 记 lastRepo →
  /// pop(目录路径) 交回调用方直接打开。note 展示在确认框里。
  Future<void> _doClone(String url, String name, String note) async {
    final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final base = await PlatformPaths.projectsDir();
    if (!mounted) return;
    final dir = await textDialog(
      context,
      '克隆到哪个目录？',
      initial: p.join(base, safeName),
      hint: p.join(base, safeName),
      confirmLabel: '下一步',
    );
    if (dir == null || dir.trim().isEmpty || !mounted) return;
    final target = p.normalize(dir.trim());
    if (target.isEmpty ||
        target == '/' ||
        target == '.' ||
        p.equals(target, base)) {
      showSnack(context, '请选择具体的仓库目录', error: true);
      return;
    }
    final ok = await confirmDialog(
      context,
      '确认克隆 $name',
      '目标目录：\n$target\n\n$note',
      action: '克隆',
    );
    if (!ok || !mounted) return;
    final cred = await Prefs.instance.credentialsForUrl(url);
    if (!mounted) return;
    setState(() => _cloning = true);
    try {
      final kh = await knownHostsPath();
      if (!mounted) return;
      // 云端克隆走 HTTPS（凭据已匹配）；SSH 地址交给 SSH 守卫流程。
      await runSshGuarded<String>(
        context,
        (accept) => engine.cloneRepo(
          url: url,
          path: target,
          cred: cred,
          knownHostsPath: kh,
          acceptUnknownHost: accept,
        ),
      );
      await Prefs.instance.setLastRepo(target);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      showSnack(context, '克隆完成：$target');
      Navigator.pop(context, target);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
    if (mounted) setState(() => _cloning = false);
  }

  Future<void> _clone(CloudRepo r) async {
    final url = r.httpsUrl.isNotEmpty ? r.httpsUrl : r.sshUrl ?? '';
    if (url.isEmpty) {
      showSnack(context, '该仓库没有可用的克隆地址', error: true);
      return;
    }
    await _doClone(
      url,
      r.name,
      r.httpsUrl.startsWith('https') ? '使用 HTTPS 地址 + 已保存凭据' : '使用 $url',
    );
  }

  /// 复制仓库地址（HTTPS 优先，无则 SSH）：snack 直接展示完整地址。
  Future<void> _copyRepoUrl(CloudRepo r) async {
    final url = r.httpsUrl.isNotEmpty ? r.httpsUrl : r.sshUrl ?? '';
    if (url.isEmpty) {
      showSnack(context, '该仓库没有可用的地址', error: true);
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    HapticFeedback.selectionClick();
    showSnack(context, '已复制仓库地址：\n$url');
  }

  /// 新建仓库：弹窗填名称 + 可见性 → 调用平台 API 创建 → 成功后展示新
  /// 仓库地址并可一键复制 / 直接克隆，然后刷新列表。
  Future<void> _createRepo() async {
    final account = _picked;
    if (account == null) return;
    final nameCtrl = TextEditingController();
    var isPrivate = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('新建仓库', style: TextStyle(fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '仓库名（如 my-demo）',
                  border: const OutlineInputBorder(),
                  suffixText: accountLabel(account),
                  suffixStyle: TextStyle(
                    fontSize: 11,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('私有仓库', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  isPrivate ? '仅自己可见' : '所有人可见',
                  style: const TextStyle(fontSize: 11),
                ),
                value: isPrivate,
                onChanged: (v) => setD(() => isPrivate = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final n = nameCtrl.text.trim();
                if (n.isEmpty || RegExp(r'\s').hasMatch(n)) return;
                Navigator.pop(ctx, true);
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameCtrl.text.trim();
    setState(() => _creating = true);
    try {
      final repo = await createCloudRepo(account, name, isPrivate: isPrivate);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      // 切回「全部」并刷新，新建的仓库立即可见
      _kind = 'all';
      final f = _fetch(account);
      setState(() => _reposFuture = f);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('创建成功', style: TextStyle(fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                repo.fullName,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(
                repo.httpsUrl,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制地址'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: repo.httpsUrl));
                if (ctx.mounted) {
                  showSnack(ctx, '已复制：${repo.httpsUrl}');
                }
              },
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _clone(repo);
              },
              child: const Text('克隆'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
    if (mounted) setState(() => _creating = false);
  }

  /// 地址栏克隆：从 URL 尾段推导仓库名（去 .git 后缀），目标目录仍固定在
  /// Projects/ 下，与账号导入克隆保持一致。
  Future<void> _cloneFromUrlField() async {
    var url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    var name = url.split('/').last;
    if (name.endsWith('.git')) name = name.substring(0, name.length - 4);
    if (name.isEmpty || name == '.' || name == '..') {
      showSnack(context, '无法从该地址识别仓库名', error: true);
      return;
    }
    final kind = url.startsWith('http')
        ? 'HTTPS（公开仓库免凭据，私有需同域已保存凭据）'
        : 'SSH（走 SSH 守卫确认主机）';
    await _doClone(url, name, '地址：$url\n$kind');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.cloud_download_outlined,
                    size: 20,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '添加远程仓库',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // ---- 通用克隆：任意 Git URL（10-03）----
            // 公开仓库免凭据；私有仓库用已保存的同域 HTTPS 凭据，
            // SSH 地址走 SSH 守卫（known_hosts 确认）。
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _urlCtrl,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '克隆任意 Git URL（https 或 ssh）',
                        prefixIcon: Icon(Icons.link, size: 18),
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      onSubmitted: (_) => _cloneFromUrlField(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _cloning ? null : _cloneFromUrlField,
                    icon: _cloning
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined, size: 16),
                    label: const Text('克隆'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (_accounts == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              )
            else if (_accounts!.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Text(
                      '没有绑定托管账号也能用上方地址栏克隆公开仓库；'
                      '私有仓库请到「设置 → 代码托管账号」绑定 GitHub、'
                      'GitLab 或云效 Codeup。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, height: 1.6),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.settings_outlined, size: 16),
                      label: const Text('知道了'),
                    ),
                  ],
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Text(
                      '账号仓库',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _creating ? null : _createRepo,
                      icon: _creating
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add, size: 16),
                      label: const Text(
                        '新建仓库',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final a in _accounts!)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            '${accountLabel(a)}（${_providerShort(accountProvider(a))}）',
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: _picked == a,
                          onSelected: (_) => _pick(a),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // ---- 类别筛选：全部 / 星标 / Fork ----
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final (k, label) in const [
                      ('all', '全部'),
                      ('starred', '星标'),
                      ('forked', 'Fork'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            label,
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: _kind == k,
                          onSelected: (_) => _pickKind(k),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _reposFuture == null
                    ? const SizedBox.shrink()
                    : FutureBuilder<List<CloudRepo>>(
                        future: _reposFuture,
                        builder: (context, snap) {
                          if (snap.connectionState != ConnectionState.done) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (snap.hasError) {
                            return Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '${snap.error}',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: cs.error,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  OutlinedButton(
                                    onPressed: () => setState(
                                      () => _reposFuture = _fetch(_picked!),
                                    ),
                                    child: const Text('重试'),
                                  ),
                                ],
                              ),
                            );
                          }
                          final repos = snap.data ?? const <CloudRepo>[];
                          if (repos.isEmpty) {
                            final hint = switch (_kind) {
                              'starred' => '该账号还没有星标仓库',
                              'forked' => '该账号没有 Fork 仓库（你 fork 的会显示在这里）',
                              _ => '该账号名下没有仓库',
                            };
                            return Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    hint,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  OutlinedButton.icon(
                                    onPressed: _creating ? null : _createRepo,
                                    icon: const Icon(Icons.add, size: 16),
                                    label: const Text('新建仓库'),
                                  ),
                                ],
                              ),
                            );
                          }
                          return RefreshIndicator(
                            onRefresh: () async {
                              final f = _fetch(_picked!);
                              setState(() => _reposFuture = f);
                              await f;
                            },
                            child: ListView.builder(
                              itemCount: repos.length,
                              itemBuilder: (context, i) {
                                final r = repos[i];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(
                                    r.isPrivate
                                        ? Icons.lock_outline
                                        : Icons.lock_open_outlined,
                                    size: 18,
                                  ),
                                  title: Text(
                                    r.fullName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    [
                                      if (r.isFork) 'Fork',
                                      if (r.description != null &&
                                          r.description!.isNotEmpty)
                                        r.description!,
                                      if (r.updatedAt != null)
                                        r.updatedAt!.split('T').first,
                                      if (r.defaultBranch != null)
                                        r.defaultBranch!,
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 10.5),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        icon: Icon(
                                          Icons.copy_outlined,
                                          size: 17,
                                          color: cs.onSurfaceVariant,
                                        ),
                                        tooltip: '复制仓库地址',
                                        onPressed: () => _copyRepoUrl(r),
                                      ),
                                      Icon(
                                        Icons.download_outlined,
                                        size: 18,
                                        color: cs.primary,
                                      ),
                                    ],
                                  ),
                                  onLongPress: () => _copyRepoUrl(r),
                                  onTap: () => _clone(r),
                                );
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _providerShort(String p) => switch (p) {
    'github' => 'GitHub',
    'gitlab' => 'GitLab',
    'codeup' => 'Codeup',
    _ => 'Git',
  };
}
