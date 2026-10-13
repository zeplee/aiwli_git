import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/ffi.dart' as engine;
import '../widgets/diff_view.dart';
import '../widgets/dialogs.dart';

/// One commit: metadata + changed files + diff. Source of truth for the
/// history tap-through and the "commit context" actions.
class CommitDetailPage extends StatefulWidget {
  final String repoPath;
  final String commitId;
  const CommitDetailPage({
    super.key,
    required this.repoPath,
    required this.commitId,
  });
  @override
  State<CommitDetailPage> createState() => _CommitDetailPageState();
}

class _CommitDetailPageState extends State<CommitDetailPage>
    with SingleTickerProviderStateMixin {
  engine.CommitDetail? _detail;
  String? _error;
  late TabController _tabs;
  String? _openFile;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final d = await engine.commitDetail(
        path: widget.repoPath,
        commitId: widget.commitId,
      );
      if (!mounted) return;
      setState(() {
        _detail = d;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  Color _codeColor(String code) => switch (code) {
    'A' => Colors.green,
    'D' => Colors.red,
    'R' => Colors.purple,
    'T' => Colors.orange,
    _ => Colors.blue,
  };

  Future<void> _act(Future<void> Function() f) async {
    try {
      await f();
      if (mounted) showSnack(context, '完成');
      // Repo state changed (revert / reset / cherry-pick) — refresh the detail.
      await _load();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  Future<void> _menu() async {
    final d = _detail;
    if (d == null) return;
    final isHead =
        d.info.id ==
        (await engine.getSnapshot(
          path: widget.repoPath,
          commitLimit: 1,
        )).headId;
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          d.info.shortId,
          style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
        ),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'copy'),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.copy, size: 18),
              title: Text('复制完整 hash', style: TextStyle(fontSize: 13)),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'tag'),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.new_label, size: 18),
              title: Text('在此提交上打标签', style: TextStyle(fontSize: 13)),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'branch'),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.account_tree, size: 18),
              title: Text('在此提交上建分支', style: TextStyle(fontSize: 13)),
            ),
          ),
          if (!isHead)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'checkout'),
              child: const ListTile(
                dense: true,
                leading: Icon(Icons.login, size: 18),
                title: Text('检出此提交（分离 HEAD）', style: TextStyle(fontSize: 13)),
              ),
            ),
          if (!isHead)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'cherry'),
              child: const ListTile(
                dense: true,
                leading: Icon(Icons.content_copy_outlined, size: 18),
                title: Text(
                  'Cherry-pick 到当前分支',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'revert'),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.undo, size: 18),
              title: Text('Revert 此提交（生成反向提交）', style: TextStyle(fontSize: 13)),
            ),
          ),
          if (!isHead)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'reset'),
              child: const ListTile(
                dense: true,
                leading: Icon(Icons.restart_alt, size: 18),
                title: Text('重置当前分支到此提交…', style: TextStyle(fontSize: 13)),
              ),
            ),
        ],
      ),
    );
    if (choice == null) return;
    if (!mounted) return;
    switch (choice) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: d.info.id));
        if (mounted) showSnack(context, '已复制 ${d.info.id}');
      case 'tag':
        final name = await textDialog(context, '标签名', hint: 'v1.0.0');
        if (name != null && name.isNotEmpty) {
          _act(
            () => engine.tagCreate(
              path: widget.repoPath,
              name: name,
              commitId: d.info.id,
            ),
          );
        }
      case 'branch':
        final name = await textDialog(context, '分支名', hint: 'feature/x');
        if (name != null && name.isNotEmpty) {
          _act(
            () => engine.branchCreate(
              path: widget.repoPath,
              name: name,
              fromCommit: d.info.id,
            ),
          );
        }
      case 'checkout':
        if (!await confirmDialog(
          context,
          '检出提交',
          '进入分离 HEAD 状态（${d.info.shortId}）？只移动 HEAD，不动分支指针。',
          action: '检出',
        )) {
          return;
        }
        await _act(
          () =>
              engine.checkoutCommit(path: widget.repoPath, commitId: d.info.id),
        );
        if (!mounted) return;
        // HEAD moved away from the branch — leave the detail page.
        Navigator.pop(context);
      case 'cherry':
        _act(
          () => engine.cherryPick(path: widget.repoPath, commitId: d.info.id),
        );
      case 'revert':
        if (!await confirmDialog(
          context,
          'Revert 提交',
          '为 ${d.info.shortId} 生成反向提交？',
          action: '回退',
        )) {
          return;
        }
        _act(() => engine.revert(path: widget.repoPath, commitId: d.info.id));
      case 'reset':
        final mode = await resetModeDialog(context, d.info.shortId);
        if (mode == null) return;
        if (!mounted) return;
        if (mode == 'hard' &&
            !await confirmDialog(
              context,
              'Hard 重置',
              '将永久丢弃 ${d.info.shortId} 之后的所有变更，确认？',
              action: '丢弃',
              danger: true,
            )) {
          return;
        }
        _act(
          () => engine.reset(
            path: widget.repoPath,
            commitId: d.info.id,
            mode: mode,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          d?.info.shortId ?? widget.commitId.substring(0, 7),
          style: const TextStyle(fontSize: 15, fontFamily: 'monospace'),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.more_vert), onPressed: _menu),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '文件'),
            Tab(text: '信息'),
          ],
        ),
      ),
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                  OutlinedButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : d == null
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                // files + inline diff
                _openFile == null
                    ? ListView(
                        padding: const EdgeInsets.only(bottom: 20),
                        children: [
                          for (final f in d.files)
                            ListTile(
                              dense: true,
                              leading: CircleAvatar(
                                radius: 9,
                                backgroundColor: _codeColor(f.code),
                                child: Text(
                                  f.code,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              title: Text(
                                f.path,
                                style: const TextStyle(fontSize: 12.5),
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '+${f.additions} −${f.deletions}',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: Colors.green.shade700,
                                ),
                              ),
                              trailing: const Icon(
                                Icons.chevron_right,
                                size: 18,
                              ),
                              onTap: () => setState(() => _openFile = f.path),
                            ),
                          if (d.files.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(40),
                              child: Center(
                                child: Text(
                                  '无文件变更',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ),
                            ),
                        ],
                      )
                    : Column(
                        children: [
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.arrow_back, size: 18),
                            title: Text(
                              _openFile!,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontFamily: 'monospace',
                              ),
                            ),
                            onTap: () => setState(() => _openFile = null),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: DiffView(
                                patchText: d.files
                                    .firstWhere((f) => f.path == _openFile!)
                                    .patchText,
                              ),
                            ),
                          ),
                        ],
                      ),
                // info
                ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    SelectableText(
                      d.info.summary,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (d.info.message.trim().contains('\n'))
                      SelectableText(
                        d.info.message.trim(),
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                    const Divider(height: 24),
                    _kv('作者', '${d.info.author} <${d.info.email}>'),
                    _kv(
                      '时间',
                      DateTime.fromMillisecondsSinceEpoch(
                        d.info.timeUnix * 1000,
                      ).toString().substring(0, 19),
                    ),
                    _kv('hash', d.info.id),
                    if (d.parents.isNotEmpty)
                      _kv(
                        '父提交',
                        d.parents.map((p) => p.substring(0, 7)).join(', '),
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            k,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            v,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
      ],
    ),
  );
}
