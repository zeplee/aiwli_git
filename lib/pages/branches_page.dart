import 'package:flutter/material.dart';

import '../engine/ffi.dart' as engine;
import '../widgets/dialogs.dart';
import '../widgets/remote_dialogs.dart';
import 'sync_flow.dart';

/// Branches / tags management + merge & checkout actions + upstream config.
class BranchesPage extends StatefulWidget {
  final String repoPath;
  final int tick; // bumped by WorkbenchHost on external changes → reload
  final VoidCallback onMutated;
  const BranchesPage({
    super.key,
    required this.repoPath,
    this.tick = 0,
    required this.onMutated,
  });
  @override
  State<BranchesPage> createState() => _BranchesPageState();
}

class _BranchesPageState extends State<BranchesPage> {
  engine.BranchesResult? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant BranchesPage old) {
    super.didUpdateWidget(old);
    if (widget.tick != old.tick) _reload();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    try {
      final d = await engine.branches(path: widget.repoPath);
      if (!mounted) return;
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  void _act(Future<void> Function() f, {String ok = ''}) async {
    if (!mounted) return;
    try {
      await f();
      if (ok.isNotEmpty && mounted) showSnack(context, ok);
      widget.onMutated();
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
    if (mounted) await _reload();
  }

  Future<void> _create() async {
    final name = await textDialog(context, '新建分支', hint: 'feature/xxx');
    if (name == null || name.isEmpty) return;
    _act(
      () => engine.branchCreate(path: widget.repoPath, name: name),
      ok: '已创建 $name（未切换）',
    );
  }

  Future<void> _branchMenu(engine.BranchInfo b) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          b.name,
          style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
        ),
        children: [
          if (!b.isCurrent)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'checkout'),
              child: const ListTile(
                dense: true,
                leading: Icon(Icons.login, size: 18),
                title: Text('切换到此分支', style: TextStyle(fontSize: 13)),
              ),
            ),
          if (!b.isCurrent)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'merge'),
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.merge, size: 18),
                title: Text('合并到当前分支', style: TextStyle(fontSize: 13)),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'rename'),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.drive_file_rename_outline, size: 18),
              title: Text('重命名', style: TextStyle(fontSize: 13)),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'upstream'),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.link, size: 18),
              title: Text('设置上游跟踪', style: TextStyle(fontSize: 13)),
            ),
          ),
          if (!b.isCurrent)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              child: ListTile(
                dense: true,
                leading: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: Colors.red,
                ),
                title: Text(
                  '删除分支',
                  style: TextStyle(fontSize: 13, color: Colors.red),
                ),
              ),
            ),
        ],
      ),
    );
    if (choice == null) return;
    if (!mounted) return;
    switch (choice) {
      case 'checkout':
        _act(
          () => engine.checkout(path: widget.repoPath, branch: b.name),
          ok: '已切换到 ${b.name}',
        );
      case 'merge':
        _act(() async {
          final r = await engine.merge(path: widget.repoPath, branch: b.name);
          if (!mounted) return;
          if (r.upToDate) {
            showSnack(context, '当前分支已包含该分支');
          } else if (r.conflicts.isNotEmpty) {
            showSnack(
              context,
              '合并产生冲突（${r.conflicts.length} 个文件），去工作台解决',
              error: true,
            );
          }
        }, ok: '合并完成');
      case 'rename':
        final name = await textDialog(context, '重命名分支', initial: b.name);
        if (name != null && name.isNotEmpty && name != b.name) {
          _act(
            () => engine.branchRename(
              path: widget.repoPath,
              oldName: b.name,
              newName: name,
            ),
            ok: '已重命名',
          );
        }
      case 'upstream':
        final rs = await engine.remotes(path: widget.repoPath);
        if (!mounted) return;
        if (rs.isEmpty) {
          showSnack(context, '先在「远程与仓库设置」里添加远程', error: true);
          return;
        }
        final remote = rs.length == 1
            ? rs.first.name
            : await pickRemoteDialog(context, rs);
        if (remote == null || !mounted) return;
        _act(
          () => engine.branchSetUpstream(
            path: widget.repoPath,
            branch: b.name,
            upstream: '$remote/${b.name}',
          ),
          ok: '已设置跟踪 ${b.name} → $remote/${b.name}',
        );
      case 'delete':
        if (await confirmDialog(
          context,
          '删除分支',
          '删除 ${b.name}？其提交仍保留在历史中（若已合并）。',
          action: '删除',
          danger: true,
        )) {
          _act(
            () => engine.branchDelete(path: widget.repoPath, name: b.name),
            ok: '已删除',
          );
        }
    }
  }

  Future<void> _tagMenu(engine.TagInfo t) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.name, style: const TextStyle(fontSize: 14)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'push'),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.upload_outlined, size: 18),
              title: Text('推送到远程', style: TextStyle(fontSize: 13)),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'del'),
            child: ListTile(
              dense: true,
              leading: Icon(Icons.delete_outline, size: 18, color: Colors.red),
              title: Text(
                '删除标签',
                style: TextStyle(fontSize: 13, color: Colors.red),
              ),
            ),
          ),
        ],
      ),
    );
    if (choice == 'push') {
      if (!mounted) return;
      // 走 sync_flow 的推送标签工作流（远程选择 + 凭据 + SSH 守卫 + 操作条）。
      await runSync(
        context,
        repoPath: widget.repoPath,
        what: 'pushTag',
        tag: t.name,
        onChanged: widget.onMutated,
      );
      if (mounted) await _reload();
      return;
    }
    if (choice == 'del') {
      if (!mounted) return;
      if (await confirmDialog(
        context,
        '删除标签',
        '删除 ${t.name}？',
        action: '删除',
        danger: true,
      )) {
        _act(
          () => engine.tagDelete(path: widget.repoPath, name: t.name),
          ok: '已删除标签',
        );
      }
    }
  }

  Future<void> _remoteBranchAction(String r) async {
    final rr = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(r, style: const TextStyle(fontSize: 14)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'checkout'),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.login, size: 18),
              title: Text('检出为本地分支', style: TextStyle(fontSize: 13)),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'merge'),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.merge, size: 18),
              title: Text('合并到当前分支', style: TextStyle(fontSize: 13)),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (rr == 'checkout') {
      await engine.checkout(path: widget.repoPath, branch: r);
      if (!mounted) return;
      showSnack(context, '已检出');
    }
    if (rr == 'merge') {
      final result = await engine.merge(path: widget.repoPath, branch: r);
      if (!mounted) return;
      if (result.upToDate) {
        showSnack(context, '当前分支已包含该远程分支');
      } else if (result.conflicts.isNotEmpty) {
        showSnack(
          context,
          '合并产生冲突（${result.conflicts.length} 个文件），去改动页解决',
          error: true,
        );
      } else {
        showSnack(context, result.fastForward ? '已快进合并' : '合并完成');
      }
    }
    if (mounted) widget.onMutated();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final cs = Theme.of(context).colorScheme;
    return _error != null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.error),
                ),
                const SizedBox(height: 10),
                OutlinedButton(onPressed: _reload, child: const Text('重试')),
              ],
            ),
          )
        : d == null
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.account_tree, size: 18),
                  title: Text(
                    '本地 (${d.local.length})',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: '新建分支',
                    onPressed: _create,
                  ),
                ),
                for (final b in d.local)
                  ListTile(
                    dense: true,
                    selected: b.isCurrent,
                    leading: Icon(
                      b.isCurrent ? Icons.check_circle : Icons.circle_outlined,
                      size: 18,
                      color: b.isCurrent
                          ? Colors.green
                          : cs.onSurface.withValues(alpha: 0.35),
                    ),
                    title: Text(
                      b.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                    ),
                    subtitle: b.upstream != null
                        ? Text(
                            '${b.upstream} ↑${b.ahead} ↓${b.behind}',
                            style: const TextStyle(fontSize: 10.5),
                          )
                        : null,
                    trailing: Text(
                      b.targetShort,
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        color: cs.onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                    onTap: () => b.isCurrent ? null : _branchMenu(b),
                    onLongPress: () => _branchMenu(b),
                  ),
                if (d.remote.isNotEmpty) ...[
                  const Divider(height: 16),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.cloud_outlined, size: 18),
                    title: Text(
                      '远程 (${d.remote.length})',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  for (final r in d.remote)
                    ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.call_split,
                        size: 16,
                        color: Colors.grey,
                      ),
                      title: Text(
                        r,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      onTap: () => _act(() => _remoteBranchAction(r)),
                    ),
                ],
                if (d.tags.isNotEmpty) ...[
                  const Divider(height: 16),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.label_outline, size: 18),
                    title: Text(
                      '标签 (${d.tags.length})',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  for (final t in d.tags.take(60))
                    ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.label,
                        size: 15,
                        color: Colors.deepOrange,
                      ),
                      title: Text(
                        t.name,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                      trailing: Text(
                        t.targetShort,
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: 'monospace',
                          color: cs.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                      onLongPress: () => _tagMenu(t),
                    ),
                ],
              ],
            ),
          );
  }
}
