import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/hosting_api.dart';
import '../core/prefs.dart';
import '../engine/ffi.dart' as engine;
import '../widgets/dialogs.dart';

/// GitHub 平台面板(满高弹层):远端仓库概览 / 文件树 / Issues / PRs /
/// Releases —— 只做平台侧功能,不做文件同步(文件操作仍在 git 工作台)。
///
/// 账号复用既有账号体系(Prefs.accounts 中 provider=github 的账号);
/// API 复用 hosting_api 的纯函数构造器 + ghRequest,与 MCP 工具共享同一层。
/// 测试注入点:[initialRepo](跳过远程推断)、[accountOverride](跳过账号
/// 存储)、[httpClient](注入 IO client)。
class GithubSheet extends StatefulWidget {
  final String repoPath;
  final String? initialRepo;
  final Map<String, Object?>? accountOverride;
  final http.Client? httpClient;

  const GithubSheet({
    super.key,
    required this.repoPath,
    this.initialRepo,
    this.accountOverride,
    this.httpClient,
  });

  @override
  State<GithubSheet> createState() => _GithubSheetState();
}

typedef _GhJsonFn = Future<dynamic> Function(
  String method,
  Uri uri, {
  String? body,
  Map<String, String>? headers,
});
typedef _GhTextFn = Future<String> Function(
  Uri uri, {
  Map<String, String>? headers,
});

class _GithubSheetState extends State<GithubSheet>
    with TickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);
  final _repoCtrl = TextEditingController();
  final _refCtrl = TextEditingController(text: 'HEAD');

  String? _slug;
  String? _slugError;
  List<Map<String, Object?>>? _accounts;
  Map<String, Object?>? _account;

  String _issueState = 'open';
  String _prState = 'open';

  Future<dynamic>? _overviewF;
  Future<dynamic>? _treeF;
  Future<dynamic>? _issuesF;
  Future<dynamic>? _prsF;
  Future<dynamic>? _relF;
  int _activeTab = 0;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_tabChanged);
    _init();
  }

  void _tabChanged() {
    if (_tabs.indexIsChanging) return;
    _ensureTab(_tabs.index);
  }

  @override
  void dispose() {
    _tabs.removeListener(_tabChanged);

    _tabs.dispose();
    _repoCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    // 账号两条路径都要:测试注入(accountOverride)或 Prefs(真实使用)。
    await _loadAccounts();
    final seed = widget.initialRepo;
    if (seed != null && seed.isNotEmpty) {
      _repoCtrl.text = seed;
      if (!mounted) return;
      setState(() => _slug = seed);
      _reload();
      return;
    }
    await _inferSlug();
  }

  Future<void> _loadAccounts() async {
    if (widget.accountOverride != null) {
      if (!mounted) return;
      setState(() => _account = widget.accountOverride);
      return;
    }
    final all = await Prefs.instance.accounts();
    if (!mounted) return;
    final gh = [
      for (final a in all)
        if (accountProvider(a) == 'github') a,
    ];
    setState(() {
      _accounts = gh;
      _account = gh.isNotEmpty ? gh.first : null;
    });
  }

  Future<void> _inferSlug() async {
    try {
      final rs = await engine.remotes(path: widget.repoPath);
      final slug = ghSlugPick(_repoCtrl.text, [
        for (final r in rs) (name: r.name, url: r.url),
      ]);
      if (!mounted) return;
      setState(() {
        _repoCtrl.text = slug;
        _slug = slug;
        _slugError = null;
      });
      _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _slugError = friendlyError(e));
    }
  }

  void _applyRepoText() {
    final t = _repoCtrl.text.trim();
    if (t.isEmpty || t == _slug) return;
    try {
      setState(() {
        _slug = checkGhSlug(t);
        _slugError = null;
      });
    } catch (e) {
      setState(() => _slugError = friendlyError(e));
      return;
    }
    _reload();
  }

  // ---------------- API access (shared by tabs & detail sheets) ----------------

  Future<Map<String, Object?>> _resolveAccount() async {
    final acc = _account;
    if (acc == null) {
      throw HostingException('没有 GitHub 账号：请到「设置 → 代码托管账号」绑定并授权 GitHub');
    }
    if (accountToken(acc) == null) {
      throw HostingException('账号「${accountLabel(acc)}」还没有访问令牌，请先在账号管理里完成授权');
    }
    return acc;
  }

  Future<dynamic> _ghJson(
    String method,
    Uri uri, {
    String? body,
    Map<String, String>? headers,
  }) async {
    final acc = await _resolveAccount();
    final out = await ghRequest(
      method,
      uri,
      token: accountToken(acc)!,
      body: body,
      extraHeaders: headers,
      client: widget.httpClient,
    );
    return out.isEmpty ? null : jsonDecode(out);
  }

  Future<String> _ghText(Uri uri, {Map<String, String>? headers}) async {
    final acc = await _resolveAccount();
    return ghRequest(
      'GET',
      uri,
      token: accountToken(acc)!,
      extraHeaders: headers,
      client: widget.httpClient,
    );
  }

  Future<dynamic> _ghOverview() async => parseGhRepoDetail(
    Map<String, dynamic>.from(await _ghJson('GET', ghRepoUri(_slug!)) as Map),
  );

  Future<dynamic> _ghTree() async {
    final ref = _refCtrl.text.trim().isEmpty ? 'HEAD' : _refCtrl.text.trim();
    return parseGhTree(await _ghText(ghTreeUri(_slug!, ref)), maxEntries: 300);
  }

  Future<dynamic> _ghIssues() async => parseGhIssues(
    await _ghText(ghIssuesUri(_slug!, state: _issueState, perPage: 100)),
  );

  Future<dynamic> _ghPrs() async => parseGhPrs(
    await _ghText(ghPullsUri(_slug!, state: _prState, perPage: 100)),
  );

  Future<dynamic> _ghReleases() async =>
      parseGhReleases(await _ghText(ghReleasesUri(_slug!)));

  /// TabBarView 懒加载:未激活分区的 FutureBuilder 不存在,其 future 的
  /// error 会成为 unhandled async error 直接炸掉测试/全局。ignore() 注册
  /// 一个空监听消费 error(Future 可多订阅,不影响 FutureBuilder 再拿)。
  Future<T> _safe<T>(Future<T> f) {
    f.ignore();
    return f;
  }

  void _reload() {
    final s = _slug;
    if (s == null || !mounted) return;
    setState(() {
      _overviewF = null;
      _treeF = null;
      _issuesF = null;
      _prsF = null;
      _relF = null;
    });
    _ensureTab(_activeTab, force: true);
  }

  void _selectTab(int index) {
    _activeTab = index;
    _ensureTab(index);
  }

  void _ensureTab(int index, {bool force = false}) {
    if (!mounted || _slug == null) return;
    final current = switch (index) {
      0 => _overviewF,
      1 => _treeF,
      2 => _issuesF,
      3 => _prsF,
      _ => _relF,
    };
    if (current != null && !force) return;
    final next = switch (index) {
      0 => _safe(_ghOverview()),
      1 => _safe(_ghTree()),
      2 => _safe(_ghIssues()),
      3 => _safe(_ghPrs()),
      _ => _safe(_ghReleases()),
    };
    setState(() {
      switch (index) {
        case 0:
          _overviewF = next;
        case 1:
          _treeF = next;
        case 2:
          _issuesF = next;
        case 3:
          _prsF = next;
        default:
          _relF = next;
      }
    });
  }

  void _pickAccount(Map<String, Object?> a) {
    if (identical(a, _account)) return;
    setState(() => _account = a);
    _reload();
  }

  void _setIssueState(String v) {
    if (v == _issueState || _slug == null) return;
    _activeTab = 2;
    setState(() {
      _issueState = v;
      _issuesF = _safe(_ghIssues());
    });
  }

  void _setPrState(String v) {
    if (v == _prState || _slug == null) return;
    _activeTab = 3;
    setState(() {
      _prState = v;
      _prsF = _safe(_ghPrs());
    });
  }

  void _applyRef() {
    if (_slug == null) return;
    _activeTab = 1;
    setState(() => _treeF = _safe(_ghTree()));
  }

  // ---------------- write operations ----------------

  Future<void> _newIssue() async {
    final slug = _slug;
    if (slug == null) return;
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建 Issue', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '标题',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: bodyCtrl,
              style: const TextStyle(fontSize: 13),
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '正文（Markdown，可留空）',
                border: OutlineInputBorder(),
              ),
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
              if (titleCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final resp = await _ghJson(
        'POST',
        ghIssuesUri(slug),
        body: ghIssueCreateBody(
          titleCtrl.text.trim(),
          body: bodyCtrl.text.trim(),
        ),
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      final n = resp is Map ? resp['number'] : null;
      showSnack(context, '已创建 Issue${n == null ? '' : ' #$n'}');
      _reload();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  // ---------------- build ----------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.92,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.code, size: 20, color: cs.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'GitHub 仓库',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: _slug == null ? null : _reload,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _repoCtrl,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'owner/name（如 alice/demo）',
                        prefixIcon: const Icon(Icons.folder_outlined, size: 18),
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        errorText: _slugError,
                      ),
                      onSubmitted: (_) => _applyRepoText(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    tooltip: '加载该仓库',
                    icon: const Icon(Icons.search, size: 18),
                    onPressed: _applyRepoText,
                  ),
                ],
              ),
            ),
            if (_accounts != null && _accounts!.isNotEmpty)
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final a in _accounts!)
                      Padding(
                        padding: const EdgeInsets.only(right: 8, top: 6),
                        child: ChoiceChip(
                          label: Text(
                            accountLabel(a),
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: _account == a,
                          onSelected: (_) => _pickAccount(a),
                        ),
                      ),
                  ],
                ),
              )
            else if (_accounts != null && _accounts!.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 14,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '没有 GitHub 账号：请先到「设置 → 代码托管账号」绑定并授权。'
                        '绑定后返回此面板即可浏览 Issue / PR / 发布。',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(height: 1),
            if (_slug == null)
              Expanded(
                child: Center(
                  child: Text(
                    _slugError ?? '正在识别当前仓库的 GitHub 远程…',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else ...[
              TabBar(
                controller: _tabs,
                onTap: _selectTab,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: const [
                  Tab(text: '概览'),
                  Tab(text: '文件'),
                  Tab(text: 'Issues'),
                  Tab(text: 'PR'),
                  Tab(text: '发布'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _Section(
                      future: _overviewF,
                      onRetry: _reload,
                      onDone: _overview,
                    ),
                    _treeSection(),
                    _issuesSection(),
                    _prsSection(),
                    _Section(
                      future: _relF,
                      onRetry: _reload,
                      onDone: _releases,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------- 概览 ----------------

  Widget _overview(BuildContext context, dynamic d) {
    if (d is! Map<String, Object?>) return _hint('仓库响应无法解析');
    final cs = Theme.of(context).colorScheme;
    final desc = (d['description'] as String?) ?? '';
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        (d['fullName'] as String?) ?? '',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _badge(
                      d['private'] == true ? '私有' : '公开',
                      d['private'] == true,
                    ),
                  ],
                ),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    _stat(Icons.star_border, '⭐ ${d['stars'] ?? '-'}'),
                    const SizedBox(width: 16),
                    _stat(Icons.call_split, '⑂ ${d['forks'] ?? '-'}'),
                    const SizedBox(width: 16),
                    _stat(
                      Icons.bug_report_outlined,
                      '◎ ${d['openIssues'] ?? '-'}',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _infoRow(Icons.account_tree_outlined, '默认分支', d['defaultBranch']),
        _infoRow(
          Icons.cloud_upload_outlined,
          '最近推送落地',
          (d['pushedAt'] as String?)?.split('T').first,
        ),
        _infoRow(
          Icons.update,
          '最近更新',
          (d['updatedAt'] as String?)?.split('T').first,
        ),
        _infoRow(
          Icons.merge_type_outlined,
          'Fork',
          d['fork'] == true ? '是' : '否',
        ),
        _copyRow(Icons.link, 'HTTPS 克隆地址', (d['httpsUrl'] as String?) ?? ''),
        _copyRow(
          Icons.alternate_email,
          'SSH 地址',
          (d['sshUrl'] as String?) ?? '',
        ),
      ],
    );
  }

  Widget _badge(String text, bool strong) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: (strong ? Colors.orange : Colors.green).withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        color: strong ? Colors.orange : Colors.green,
      ),
    ),
  );

  Widget _stat(IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );

  Widget _infoRow(IconData icon, String label, Object? value) => ListTile(
    dense: true,
    leading: Icon(icon, size: 18),
    title: Text(label, style: const TextStyle(fontSize: 12.5)),
    trailing: Text(
      '${value ?? '-'}',
      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
    ),
  );

  Widget _copyRow(IconData icon, String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 18),
      title: Text(label, style: const TextStyle(fontSize: 12.5)),
      subtitle: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: const Icon(Icons.copy_outlined, size: 16),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (!mounted) return;
        HapticFeedback.selectionClick();
        showSnack(context, '已复制：$value');
      },
    );
  }

  // ---------------- 文件树 ----------------

  Widget _treeSection() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _refCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '分支 / 标签 / commit',
                    prefixIcon: Icon(Icons.account_tree_outlined, size: 18),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: (_) => _applyRef(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: '查看该引用',
                icon: const Icon(Icons.visibility_outlined, size: 18),
                onPressed: _applyRef,
              ),
            ],
          ),
        ),
        Expanded(
          child: _Section(
            future: _treeF,
            onRetry: _reload,
            onDone: (context, data) {
              final t = data as Map<String, Object?>?;
              if (t == null) return _hint('树响应无法解析');
              final entries = t['entries'] as List;
              if (entries.isEmpty) return _hint('该引用下没有条目');
              final note = t['serverTruncated'] == true
                  ? '树过大，GitHub 端已截断，结果不完整'
                  : ((t['clientOverflow'] as int? ?? 0) > 0
                        ? '超出显示上限，还有 ${t['clientOverflow']} 条未展示'
                        : '');
              return ListView(
                children: [
                  if (note.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: Text(
                        note,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final e in entries)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        e['type'] == 'tree'
                            ? Icons.folder_outlined
                            : Icons.description_outlined,
                        size: 18,
                        color: e['type'] == 'tree'
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(
                        '${e['path']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      trailing: e['size'] == null
                          ? null
                          : Text(
                              '${e['size']} B',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                            ),
                      onTap: e['type'] == 'blob' && _slug != null
                          ? () => _openFile('${e['path']}')
                          : null,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openFile(String path) async {
    final slug = _slug;
    if (slug == null) return;
    await showFullSheet(
      context,
      _FileSheet(
        slug: slug,
        ref: _refCtrl.text.trim().isEmpty ? 'HEAD' : _refCtrl.text.trim(),
        path: path,
        ghText: _ghText,
      ),
    );
  }

  // ---------------- Issues ----------------

  Widget _issuesSection() {
    return _ListSection(
      future: _issuesF,
      current: _issueState,
      onPick: _setIssueState,
      states: const ['open', 'closed', 'all'],
      actionLabel: '新建 Issue',
      onAction: _newIssue,
      onRetry: _reload,
      emptyHint: '该状态下没有 Issue',
      itemCount: (data) => (data as List).length,
      tile: (context, item, onTap) =>
          _issueTile(item as Map<String, Object?>, onTap),
      onTapItem: (item) => _openIssue(item as Map<String, Object?>),
    );
  }

  Widget _issueTile(Map<String, Object?> i, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    final labels = (i['labels'] as List?)?.cast() ?? const [];
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: Text(
        '#${i['number']}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: cs.primary,
        ),
      ),
      title: Text(
        '${i['title']}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          '${i['author'] ?? '匿名'}',
          if (labels.isNotEmpty) labels.join(','),
          (i['updatedAt'] as String?)?.split('T').first ?? '',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10.5),
      ),
      trailing: i['state'] == 'closed'
          ? Icon(Icons.check_circle_outline, size: 16, color: cs.outline)
          : null,
    );
  }

  Future<void> _openIssue(Map<String, Object?> i) async {
    final slug = _slug;
    if (slug == null) return;
    await showFullSheet(
      context,
      _IssueDetailSheet(
        slug: slug,
        number: i['number'] as int,
        gh: _ghJson,
        onMutated: _reload,
      ),
    );
  }

  // ---------------- PRs ----------------

  Widget _prsSection() {
    return _ListSection(
      future: _prsF,
      current: _prState,
      onPick: _setPrState,
      states: const ['open', 'closed', 'all'],
      onRetry: _reload,
      emptyHint: '该状态下没有 PR',
      itemCount: (data) => (data as List).length,
      tile: (context, item, onTap) =>
          _prTile(item as Map<String, Object?>, onTap),
      onTapItem: (item) => _openPr(item as Map<String, Object?>),
    );
  }

  Widget _prTile(Map<String, Object?> p, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: Text(
        '#${p['number']}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: cs.primary,
        ),
      ),
      title: Text(
        '${p['title']}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          '${p['headRef'] ?? '?'}→${p['baseRef'] ?? '?'}',
          '${p['author'] ?? '匿名'}',
          if (p['changedFiles'] != null) '${p['changedFiles']} 文件',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10.5),
      ),
      trailing: p['draft'] == true
          ? Icon(Icons.edit_note, size: 16, color: cs.outline)
          : p['merged'] == true
          ? Icon(Icons.merge, size: 16, color: cs.primary)
          : null,
    );
  }

  Future<void> _openPr(Map<String, Object?> p) async {
    final slug = _slug;
    if (slug == null) return;
    await showFullSheet(
      context,
      _PrDetailSheet(
        slug: slug,
        number: p['number'] as int,
        gh: _ghJson,
        ghText: _ghText,
        onMutated: _reload,
      ),
    );
  }

  // ---------------- 发布 ----------------

  Widget _releases(BuildContext context, dynamic data) {
    final rel = data as List? ?? const [];
    if (rel.isEmpty) return _hint('还没有发布(Release)');
    return ListView(
      children: [
        for (final r in rel) _releaseTile(context, r as Map<String, Object?>),
      ],
    );
  }

  Widget _releaseTile(BuildContext context, Map<String, Object?> r) {
    final assets = r['assets'] as List? ?? const [];
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      title: Text(
        '${r['tagName']}${r['name'] == null || r['name'] == r['tagName'] ? '' : ' · ${r['name']}'}',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          (r['publishedAt'] as String?)?.split('T').first ?? '',
          if (r['prerelease'] == true) '预发布',
          '附件 ${assets.length}',
        ].join(' · '),
        style: const TextStyle(fontSize: 10.5),
      ),
      children: [
        if ((r['body'] as String?)?.isNotEmpty == true)
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              r['body'] as String,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        for (final a in assets)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_outlined, size: 16),
            title: Text(
              '${(a as Map)['name']}',
              style: const TextStyle(fontSize: 12),
            ),
            subtitle: Text(
              '${a['size']} B',
              style: const TextStyle(fontSize: 10.5),
            ),
            onTap: () async {
              final url = '${a['downloadUrl']}';
              await Clipboard.setData(ClipboardData(text: url));
              if (!context.mounted) return;
              HapticFeedback.selectionClick();
              showSnack(context, '已复制下载链接：\n$url');
            },
          ),
      ],
    );
  }
}

// ============================ 通用分区与列表 ============================

/// FutureBuilder 四态封装:loading / error(可重试) / empty / data。
class _Section extends StatelessWidget {
  final Future<dynamic>? future;
  final Widget Function(BuildContext context, dynamic data) onDone;
  final VoidCallback? onRetry;
  const _Section({required this.future, required this.onDone, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<dynamic>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _errorView(context, '${snap.error}', onRetry: onRetry);
        }
        return onDone(context, snap.data);
      },
    );
  }
}

/// 列表分区:状态筛选 chips + 可选动作按钮 + FutureBuilder 列表。
/// 刷新走 [onRetry](面板级重载);onPick(current) 同值会被幂等跳过,
/// 不能用于刷新。
class _ListSection extends StatelessWidget {
  final Future<dynamic>? future;
  final String current;
  final ValueChanged<String> onPick;
  final List<String> states;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onRetry;
  final int Function(dynamic data) itemCount;
  final Widget Function(BuildContext context, dynamic item, VoidCallback onTap)
  tile;
  final ValueChanged<dynamic> onTapItem;
  final String emptyHint;

  const _ListSection({
    required this.future,
    required this.current,
    required this.onPick,
    required this.states,
    required this.itemCount,
    required this.tile,
    required this.onTapItem,
    this.actionLabel,
    this.onAction,
    this.onRetry,
    this.emptyHint = '这里还没有内容',
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final s in states)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            s == 'open'
                                ? '打开'
                                : s == 'closed'
                                ? '已关闭'
                                : '全部',
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: current == s,
                          onSelected: (_) => onPick(s),
                        ),
                      ),
                  ],
                ),
              ),
              if (actionLabel != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: onAction,
                    icon: const Icon(Icons.add, size: 16),
                    label: Text(
                      actionLabel!,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _Section(
            future: future,
            onRetry: onRetry,
            onDone: (context, data) {
              final n = itemCount(data);
              if (n == 0) return _hint(emptyHint);
              return RefreshIndicator(
                onRefresh: () async => onRetry?.call(),
                child: ListView.builder(
                  itemCount: n,
                  itemBuilder: (context, i) {
                    final item = (data as List)[i];
                    return tile(context, item, () => onTapItem(item));
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

Widget _hint(String text) => Center(
  child: Padding(
    padding: const EdgeInsets.all(20),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 12.5, color: Colors.grey, height: 1.5),
    ),
  ),
);

Widget _errorView(BuildContext context, String msg, {VoidCallback? onRetry}) =>
    Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            msg,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.error,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          if (onRetry != null)
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );

// ============================ 文件查看 ============================

class _FileSheet extends StatefulWidget {
  final String slug;
  final String ref;
  final String path;
  final _GhTextFn ghText;

  const _FileSheet({
    required this.slug,
    required this.ref,
    required this.path,
    required this.ghText,
  });

  @override
  State<_FileSheet> createState() => _FileSheetState();
}

class _FileSheetState extends State<_FileSheet> {
  late final Future<Map<String, Object?>> _f = _load();

  Future<Map<String, Object?>> _load() async {
    final body = await widget.ghText(
      ghContentUri(widget.slug, widget.path, ref: widget.ref),
    );
    return parseGhFileContent(body) ?? (throw HostingException('文件响应无法解析'));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.description_outlined, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
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
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<Map<String, Object?>>(
                future: _f,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return _errorView(context, '${snap.error}');
                  }
                  final f = snap.data!;
                  if (f['tooLargeForInline'] == true) {
                    return _hint(
                      '文件超过 1MB，GitHub 不内联返回内容。\n请克隆后在工作台查看。'
                      '${f['htmlUrl'] ?? ''}',
                    );
                  }
                  if (f['binary'] == true) {
                    return _hint('二进制文件(${f['size']} 字节)，不在对话中展示。');
                  }
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        '${f['text']}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.45,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================ Issue 详情 ============================

class _IssueDetailSheet extends StatefulWidget {
  final String slug;
  final int number;
  final _GhJsonFn gh;
  final VoidCallback onMutated;

  const _IssueDetailSheet({
    required this.slug,
    required this.number,
    required this.gh,
    required this.onMutated,
  });

  @override
  State<_IssueDetailSheet> createState() => _IssueDetailSheetState();
}

class _IssueDetailSheetState extends State<_IssueDetailSheet> {
  Future<List<dynamic>>? _f;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    if (!mounted) return;
    setState(() {
      _f = Future.wait<dynamic>([
        widget.gh('GET', ghIssueUri(widget.slug, widget.number)),
        widget.gh(
          'GET',
          ghIssueCommentsUri(widget.slug, widget.number, perPage: 100),
        ),
      ]);
    });
  }

  Future<void> _comment() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加评论', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            hintText: '评论内容(Markdown)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (ctrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.gh(
        'POST',
        ghIssueCommentsUri(widget.slug, widget.number),
        body: ghCommentBody(ctrl.text.trim()),
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      showSnack(context, '已添加评论');
      widget.onMutated();
      _load();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _setIssueState(String state) async {
    final verb = state == 'closed' ? '关闭' : '重新打开';
    final ok = await confirmDialog(
      context,
      '$verb Issue #${widget.number}',
      '仅在 GitHub 平台生效，不影响本地仓库。',
      action: verb,
    );
    if (!ok || !mounted) return;
    try {
      await widget.gh(
        'PATCH',
        ghIssueUri(widget.slug, widget.number),
        body: ghIssuePatchBody(state: state),
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      showSnack(context, '已$verb #${widget.number}');
      widget.onMutated();
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.88,
        child: FutureBuilder<List<dynamic>>(
          future: _f,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _errorView(context, '${snap.error}', onRetry: _load);
            }
            final issue = parseGhIssue(
              Map<String, dynamic>.from(snap.data![0] as Map),
              includePullRequests: true,
            );
            final comments = [
              for (final c in (snap.data![1] as List? ?? []))
                if (c is Map) parseGhComment(Map<String, dynamic>.from(c)),
            ].whereType<Map<String, Object?>>().toList();
            if (issue == null) return _hint('Issue 响应无法解析');
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                  child: Row(
                    children: [
                      Text(
                        '#${issue['number']}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${issue['title']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      _stateBadge('${issue['state']}'),
                      const SizedBox(width: 8),
                      Text(
                        '${issue['author'] ?? '匿名'} · ${(issue['updatedAt'] as String?)?.split('T').first ?? ''}',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 16),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      if ((issue['body'] as String?)?.isNotEmpty == true)
                        SelectableText(
                          issue['body'] as String,
                          style: const TextStyle(fontSize: 12.5, height: 1.55),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        '评论 ${comments.length}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      for (final c in comments)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${c['author'] ?? '匿名'} · ${(c['createdAt'] as String?)?.split('T').first ?? ''}',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 2),
                              SelectableText(
                                '${c['body']}',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (comments.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            '还没有评论',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: _comment,
                          icon: const Icon(Icons.comment_outlined, size: 16),
                          label: const Text('评论'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => _setIssueState(
                            issue['state'] == 'closed' ? 'open' : 'closed',
                          ),
                          child: Text(
                            issue['state'] == 'closed' ? '重新打开' : '关闭',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

Widget _stateBadge(String state) {
  final (label, color) = switch (state) {
    'open' => ('打开', Colors.green),
    'merged' => ('已合并', Colors.deepPurple),
    _ => ('已关闭', const Color(0xFF8B5CF6)),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(label, style: TextStyle(fontSize: 10.5, color: color)),
  );
}

// ============================ PR 详情 ============================

class _PrDetailSheet extends StatefulWidget {
  final String slug;
  final int number;
  final _GhJsonFn gh;
  final _GhTextFn ghText;
  final VoidCallback onMutated;

  const _PrDetailSheet({
    required this.slug,
    required this.number,
    required this.gh,
    required this.ghText,
    required this.onMutated,
  });

  @override
  State<_PrDetailSheet> createState() => _PrDetailSheetState();
}

class _PrDetailSheetState extends State<_PrDetailSheet> {
  Future<dynamic>? _f;
  Future<String>? _diffF;
  Future<dynamic>? _commentsF;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    if (!mounted) return;
    setState(() {
      _f = widget.gh('GET', ghPullUri(widget.slug, widget.number));
      _diffF = widget.ghText(
        ghPullUri(widget.slug, widget.number),
        headers: {'Accept': 'application/vnd.github.diff'},
      );
      final comments = widget.gh(
        'GET',
        ghIssueCommentsUri(widget.slug, widget.number, perPage: 100),
      );
      // PR comment APIs are optional on some GitHub-compatible servers. Keep
      // the detail page usable when that endpoint is unavailable and still
      // let FutureBuilder expose the error if the request is supported.
      comments.ignore();
      _commentsF = comments;
    });
  }

  Future<void> _comment() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加评论', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            hintText: '评论内容(Markdown)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (ctrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.gh(
        'POST',
        ghIssueCommentsUri(widget.slug, widget.number),
        body: ghCommentBody(ctrl.text.trim()),
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      showSnack(context, '已添加评论');
      widget.onMutated();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _setPrState(String state) async {
    final verb = state == 'closed' ? '关闭' : '重新打开';
    final ok = await confirmDialog(
      context,
      '$verb PR #${widget.number}',
      '仅在 GitHub 平台生效，不影响本地仓库。',
      action: verb,
    );
    if (!ok || !mounted) return;
    try {
      await widget.gh(
        'PATCH',
        ghPullUri(widget.slug, widget.number),
        body: ghPrPatchBody(state: state),
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      showSnack(context, '已$verb PR #${widget.number}');
      widget.onMutated();
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _merge(Map<String, Object?> pr) async {
    var method = 'merge';
    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(
            '合并 PR #${widget.number}',
            style: const TextStyle(fontSize: 16),
          ),
          content: RadioGroup<String>(
            groupValue: method,
            onChanged: (v) => setD(() => method = v ?? 'merge'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (m, label) in const [
                  ('merge', '合并提交(保留分支历史)'),
                  ('squash', '压缩为一个提交'),
                  ('rebase', '变基合并'),
                ])
                  RadioListTile<String>(
                    dense: true,
                    value: m,
                    title: Text(label, style: const TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, method),
              child: const Text('下一步'),
            ),
          ],
        ),
      ),
    );
    if (pick == null || !mounted) return;
    final ok = await confirmDialog(
      context,
      '确认合并 PR #${widget.number}',
      '以 $pick 方式合并到 ${pr['baseRef'] ?? '目标分支'}。',
      action: '合并',
    );
    if (!ok || !mounted) return;
    try {
      final resp = await widget.gh(
        'PUT',
        ghPullMergeUri(widget.slug, widget.number),
        body: ghPrMergeBody(method: pick),
      );
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      final merged = resp is Map && resp['merged'] == true;
      showSnack(context, merged ? '已合并 PR #${widget.number}' : '合并结果未知');
      widget.onMutated();
      if (merged) Navigator.pop(context);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.92,
        child: FutureBuilder<dynamic>(
          future: _f,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _errorView(context, '${snap.error}', onRetry: _load);
            }
            final pr = snap.data is Map
                ? parseGhPr(Map<String, dynamic>.from(snap.data as Map))
                : null;
            if (pr == null) return _hint('PR 响应无法解析');
            final mergeable =
                pr['merged'] != true &&
                pr['state'] == 'open' &&
                pr['draft'] != true &&
                pr['mergeable'] != false;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                  child: Row(
                    children: [
                      Text(
                        '#${pr['number']}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${pr['title']}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      if (pr['merged'] == true)
                        _stateBadge('merged')
                      else
                        _stateBadge('${pr['state']}'),
                      if (pr['draft'] == true) ...[
                        const SizedBox(width: 6),
                        Text(
                          '草稿',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${pr['headRef'] ?? '?'} → ${pr['baseRef'] ?? '?'} · '
                          '${pr['author'] ?? '匿名'} · '
                          '+${pr['additions'] ?? '?'}/-${pr['deletions'] ?? '?'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if ((pr['body'] as String?)?.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        pr['body'] as String,
                        style: const TextStyle(fontSize: 12.5, height: 1.5),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '变更 diff(${pr['changedFiles'] ?? '?'} 个文件)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<String>(
                    future: _diffF,
                    builder: (context, dsnap) {
                      if (dsnap.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (dsnap.hasError) {
                        return _errorView(
                          context,
                          '${dsnap.error}',
                          onRetry: () => setState(() {
                            _diffF = widget.ghText(
                              ghPullUri(widget.slug, widget.number),
                              headers: {
                                'Accept': 'application/vnd.github.diff',
                              },
                            );
                          }),
                        );
                      }
                      return SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(
                            dsnap.data ?? '',
                            style: const TextStyle(
                              fontSize: 10.5,
                              height: 1.4,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                FutureBuilder<dynamic>(
                  future: _commentsF,
                  builder: (context, csnap) {
                    if (csnap.connectionState != ConnectionState.done ||
                        csnap.hasError) {
                      return const SizedBox.shrink();
                    }
                    final comments = [
                      for (final c in (csnap.data as List? ?? []))
                        if (c is Map)
                          parseGhComment(Map<String, dynamic>.from(c)),
                    ].whereType<Map<String, Object?>>().toList();
                    if (comments.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '评论 ${comments.length} · 可在评论按钮中添加新评论',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: _comment,
                          icon: const Icon(Icons.comment_outlined, size: 16),
                          label: const Text('评论'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: mergeable
                              ? () => _setPrState('closed')
                              : null,
                          child: const Text(
                            '关闭',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 4),
                        FilledButton.icon(
                          onPressed: mergeable ? () => _merge(pr) : null,
                          icon: const Icon(Icons.merge, size: 16),
                          label: const Text(
                            '合并',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
