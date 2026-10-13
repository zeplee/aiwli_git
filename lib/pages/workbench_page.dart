import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/operation.dart';
import '../core/sys_access.dart';
import '../engine/ffi.dart' as engine;
import '../widgets/diff_view.dart';
import '../widgets/dialogs.dart';
import 'sync_flow.dart';

/// Workbench: changes (staged/unstaged/untracked) + inline diff with hunk
/// actions + commit bar. Merge/conflict state banners.
/// 嵌套在 WorkbenchHost 的子页里：无 AppBar（同步菜单由宿主提供）。
class WorkbenchPage extends StatefulWidget {
  final String repoPath;

  /// Bumped by WorkbenchHost on external changes → reload.
  final int tick;

  /// Published after every snapshot reload (host forwards for the ↑n badge).
  final ValueChanged<engine.RepoSnapshot>? onSnapshot;

  const WorkbenchPage({
    super.key,
    required this.repoPath,
    this.tick = 0,
    this.onSnapshot,
  });
  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  engine.RepoSnapshot? _snap;
  String? _error;
  bool _storageDenied = false;
  bool _busy = false;
  final _msgCtrl = TextEditingController();
  bool _amend = false;
  // multi-select state（长按文件进入选择模式；键=「S/W:路径」，同一路径
  // 可能同时出现在已暂存与未暂存两个分区，故把分区编码进键里）
  bool _selectMode = false;
  final Set<String> _selected = {};
  // diff pane state
  String? _diffFile;
  bool _diffStaged = false;
  String _diffText = '';
  int _reloadSerial = 0;
  int _diffSerial = 0;
  // 同步操作（推进/拉取/获取…）的状态源，见 core/operation.dart。
  // 它和本页的 _busy 是两套：_busy 管本页的读/写（reload、暂存、提交），
  // 操作条管 runSync 的网络操作。
  final _op = OperationController.instance;

  /// 任何操作进行中都要锁按钮。以前 `runSync` 不碰 `_busy`，所以推送期间
  /// 按钮**仍然可点**——实测连点两次会真发出两次 push，第二次的链路抖动
  /// 还会把失败原因掩盖成别的问题。
  bool get _locked => _busy || _op.isRunning;

  void _onOpChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _op.removeListener(_onOpChanged);
    _msgCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _op.addListener(_onOpChanged);
    _reload();
  }

  /// 回到前台时静默刷新：仓库可能被外部工具（电脑 / 容器 / 其他 App）改过，
  /// 界面若继续展示旧快照，用户基于它做暂存/丢弃会作用在真实的新状态上。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!_busy) _reload(silent: true);
    if (_diffFile != null) _openDiff(_diffFile!, _diffStaged);
  }

  @override
  void didUpdateWidget(covariant WorkbenchPage old) {
    super.didUpdateWidget(old);
    if (widget.tick != old.tick) _reload();
  }

  Future<void> _reload({bool silent = false}) async {
    if (!mounted) return;
    final serial = ++_reloadSerial;
    if (!silent) {
      setState(() {
        _busy = true;
        _error = null;
      });
    }
    try {
      final snap = await engine.getSnapshot(
        path: widget.repoPath,
        commitLimit: 30,
      );
      if (!mounted || serial != _reloadSerial) return;
      setState(() {
        _snap = snap;
        if (!silent) _busy = false; // 静默刷新不碰操作状态，避免误解锁
        _error = null;
      });
      widget.onSnapshot?.call(snap);
    } catch (e) {
      if (!mounted || serial != _reloadSerial) return;
      if (silent && _snap != null) return; // 静默刷新失败：保留旧快照不打扰
      setState(() {
        _error = friendlyError(e);
        _storageDenied = isStorageDeniedError(e);
        _busy = false;
      });
    }
  }

  /// 执行一个写操作并刷新快照；返回是否成功（失败已 toast）。
  Future<bool> _act(Future<void> Function() f, {String okMsg = ''}) async {
    if (!mounted || _busy) return false;
    setState(() {
      _busy = true;
    });
    var ok = true;
    try {
      await f();
      if (okMsg.isNotEmpty && mounted) {
        HapticFeedback.selectionClick();
        showSnack(context, okMsg);
      }
    } catch (e) {
      ok = false;
      if (mounted) {
        showSnack(context, friendlyError(e), error: true);
      }
    }
    if (mounted) await _reload();
    return ok;
  }

  Future<void> _commit() async {
    final msg = _msgCtrl.text.trim();
    if (msg.isEmpty && !_amend) {
      showSnack(context, '提交信息不能为空', error: true);
      return;
    }
    if (_amend) {
      final ok = await confirmDialog(
        context,
        '修改上一提交？',
        '这会重写当前分支最近一次提交。已推送到远程的提交可能因此产生冲突。',
        action: '修改上一提交',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    await _act(() async {
      await engine.commitStaged(
        path: widget.repoPath,
        message: msg,
        amend: _amend,
      );
      _msgCtrl.clear();
      _amend = false;
    }, okMsg: _amend ? '已 amend' : '已提交');
  }

  Future<void> _openDiff(String file, bool staged) async {
    if (!mounted) return;
    final serial = ++_diffSerial;
    setState(() {
      _diffFile = file;
      _diffStaged = staged;
      _diffText = '';
    });
    try {
      final text = await engine.getWorkdirDiff(
        path: widget.repoPath,
        file: file,
        staged: staged,
      );
      if (mounted &&
          serial == _diffSerial &&
          _diffFile == file &&
          _diffStaged == staged) {
        setState(() => _diffText = text);
      }
    } catch (e) {
      if (mounted && serial == _diffSerial) {
        setState(() => _diffText = '生成 diff 失败: $e');
      }
    }
  }

  Future<void> _hunkAction(int index, String op) async {
    final file = _diffFile;
    if (file == null) return;
    if (op == 'discard') {
      final ok = await confirmDialog(
        context,
        '丢弃此块？',
        '将永久丢弃「$file」的这一段未暂存修改，无法从 AiwliGit 恢复。',
        action: '丢弃此块',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    await _act(
      () => engine.hunkOp(
        path: widget.repoPath,
        file: file,
        indexes: [index],
        op: op,
      ),
    );
    if (!mounted) return;
    await _openDiff(file, op == 'stage' ? true : _diffStaged);
  }

  Color _codeColor(String code) => switch (code) {
    'A' => Colors.green,
    'D' => Colors.red,
    'R' => Colors.purple,
    'T' => Colors.orange,
    _ => Colors.blue,
  };

  String _selKey(String path, bool staged) => '${staged ? 'S' : 'W'}:$path';

  void _enterSelectMode([String? key]) {
    HapticFeedback.selectionClick();
    setState(() {
      _selectMode = true;
      if (key != null) _selected.add(key);
      _diffFile = null; // 手机上让变更列表回到眼前
    });
  }

  void _exitSelectMode() {
    if (!_selectMode && _selected.isEmpty) return;
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  void _toggleSelected(String key) {
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  Widget _fileTile(
    engine.FileStatus f, {
    required bool staged,
    bool untracked = false,
  }) {
    final key = _selKey(f.path, staged);
    final isSelected = _selected.contains(key);
    return ListTile(
      dense: true,
      selected: !_selectMode && _diffFile == f.path && _diffStaged == staged,
      leading: CircleAvatar(
        radius: 9,
        backgroundColor: untracked ? Colors.grey : _codeColor(f.code),
        child: Text(
          untracked ? '?' : f.code,
          style: const TextStyle(
            fontSize: 10,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(
        f.path,
        style: const TextStyle(fontSize: 12.5),
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () {
        if (_selectMode) {
          _toggleSelected(key);
          return;
        }
        _openDiff(f.path, staged);
      },
      onLongPress: () =>
          _selectMode ? _toggleSelected(key) : _enterSelectMode(key),
      trailing: _selectMode
          ? Checkbox(
              value: isSelected,
              onChanged: (_) => _toggleSelected(key),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: staged ? '取消暂存' : '暂存',
                  iconSize: 20,
                  icon: Icon(
                    staged ? Icons.indeterminate_check_box : Icons.add_box,
                  ),
                  onPressed: () => _act(
                    () => staged
                        ? engine.unstagePaths(
                            path: widget.repoPath,
                            files: [f.path],
                          )
                        : engine.stagePaths(
                            path: widget.repoPath,
                            files: [f.path],
                          ),
                  ),
                ),
                if (!staged && !untracked)
                  IconButton(
                    tooltip: '丢弃变更',
                    iconSize: 18,
                    icon: const Icon(Icons.restore),
                    onPressed: () async {
                      if (await confirmDialog(
                        context,
                        '丢弃变更',
                        '永久丢弃 ${f.path} 的未暂存修改？',
                        action: '丢弃',
                        danger: true,
                      )) {
                        _act(
                          () => engine.discardPaths(
                            path: widget.repoPath,
                            files: [f.path],
                          ),
                        );
                      }
                    },
                  ),
              ],
            ),
    );
  }

  /// 按钮内的小计数徽标（↑待推送 / ↓待拉取）。
  Widget _countBadge(int n) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      constraints: const BoxConstraints(minWidth: 18),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '$n',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.bold,
          color: cs.onPrimaryContainer,
        ),
      ),
    );
  }

  Widget _statusCard(engine.RepoSnapshot s) {
    final status = s.ahead > 0 && s.behind > 0
        ? '本地领先 ${s.ahead} 个提交，远程领先 ${s.behind} 个提交；先拉取再推送'
        : s.behind > 0
        ? '远程有 ${s.behind} 个新提交，建议先拉取'
        : s.ahead > 0
        ? '本地有 ${s.ahead} 个提交待推送'
        : '与已配置的上游提交一致（仅依据上次获取的远程信息）';
    final paths = <String>{...s.unstaged.map((f) => f.path), ...s.untracked};
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_tree_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '当前分支：${s.branch}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('同步状态：$status', style: const TextStyle(fontSize: 12)),
            if (s.ahead == 0 && s.behind == 0)
              const Text(
                '远程状态可能已变化，点击「拉取更新」可重新检查',
                style: TextStyle(fontSize: 10.5),
              ),
            const SizedBox(height: 6),
            Text(
              '已暂存 ${s.staged.length} 个 · 待暂存 ${paths.length} 个',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _locked
                        ? null
                        : () => runSync(
                            context,
                            repoPath: widget.repoPath,
                            what: 'pull',
                            onChanged: _reload,
                          ),
                    icon: const Icon(Icons.download, size: 18),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('拉取更新'),
                        if (s.behind > 0) ...[
                          const SizedBox(width: 6),
                          _countBadge(s.behind),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _locked
                        ? null
                        : () => runSync(
                            context,
                            repoPath: widget.repoPath,
                            what: 'push',
                            onChanged: _reload,
                          ),
                    icon: const Icon(Icons.upload, size: 18),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('推送提交'),
                        if (s.ahead > 0) ...[
                          const SizedBox(width: 6),
                          _countBadge(s.ahead),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: _locked || paths.isEmpty || s.conflicted.isNotEmpty
                      ? null
                      : () => _act(
                          () => engine.stagePaths(
                            path: widget.repoPath,
                            files: paths.toList(),
                          ),
                          okMsg: '已暂存 ${paths.length} 个文件',
                        ),
                  icon: const Icon(Icons.add_task, size: 17),
                  label: const Text('全部暂存'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      _locked || s.staged.isEmpty || s.conflicted.isNotEmpty
                      ? null
                      : () => _act(
                          () => engine.unstagePaths(
                            path: widget.repoPath,
                            files: s.staged.map((f) => f.path).toSet().toList(),
                          ),
                          okMsg: '已取消全部暂存',
                        ),
                  icon: const Icon(Icons.undo, size: 17),
                  label: const Text('全部取消暂存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _changesPane() {
    final s = _snap;
    if (s == null) return const Center(child: CircularProgressIndicator());
    final total = s.staged.length + s.unstaged.length + s.untracked.length;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          _statusCard(s),
          if (s.conflicted.isNotEmpty) ...[
            ListTile(
              dense: true,
              leading: Icon(Icons.warning_amber, color: Colors.orange.shade700),
              title: Text(
                '冲突 (${s.conflicted.length}) — 需要解决',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: Colors.orange,
                ),
              ),
            ),
            for (final p in s.conflicted)
              ListTile(
                dense: true,
                leading: const Icon(
                  Icons.error_outline,
                  size: 18,
                  color: Colors.orange,
                ),
                title: Text(p, style: const TextStyle(fontSize: 12.5)),
                onTap: () => _resolveConflict(p),
              ),
          ],
          if (s.staged.isNotEmpty) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.inventory_2, size: 18),
              title: Text(
                '已暂存 (${s.staged.length})',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '多选',
                    iconSize: 20,
                    icon: const Icon(Icons.checklist),
                    onPressed: () => _enterSelectMode(),
                  ),
                  TextButton(
                    onPressed: () => _act(
                      () => engine.unstagePaths(
                        path: widget.repoPath,
                        files: s.staged.map((e) => e.path).toList(),
                      ),
                    ),
                    child: const Text('全部取消暂存', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            ...s.staged.map((f) => _fileTile(f, staged: true)),
          ],
          if (s.unstaged.isNotEmpty) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.edit_note, size: 18),
              title: Text(
                '未暂存 (${s.unstaged.length})',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '多选',
                    iconSize: 20,
                    icon: const Icon(Icons.checklist),
                    onPressed: () => _enterSelectMode(),
                  ),
                  TextButton(
                    onPressed: () => _act(
                      () => engine.stagePaths(
                        path: widget.repoPath,
                        files: s.unstaged.map((e) => e.path).toList(),
                      ),
                    ),
                    child: const Text('全部暂存', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            ...s.unstaged.map((f) => _fileTile(f, staged: false)),
          ],
          if (s.untracked.isNotEmpty) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.help_outline, size: 18),
              title: Text(
                '未跟踪 (${s.untracked.length})',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '多选',
                    iconSize: 20,
                    icon: const Icon(Icons.checklist),
                    onPressed: () => _enterSelectMode(),
                  ),
                  TextButton(
                    onPressed: () => _act(
                      () => engine.stagePaths(
                        path: widget.repoPath,
                        files: s.untracked,
                      ),
                    ),
                    child: const Text('全部暂存', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            ...s.untracked.map(
              (p) => _fileTile(
                engine.FileStatus(path: p, code: '?'),
                staged: false,
                untracked: true,
              ),
            ),
          ],
          if (total == 0 && s.conflicted.isEmpty)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 38,
                      color: Colors.green,
                    ),
                    SizedBox(height: 8),
                    Text(
                      '工作区很干净',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '没有需要提交的变更',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _resolveConflict(String path) async {
    final cs = await engine.conflicts(path: widget.repoPath);
    final f = cs.where((c) => c.path == path).firstOrNull;
    if (!mounted) return;
    final side = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          path,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
        ),
        children: [
          if (f?.hasOurs ?? true)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'ours'),
              child: const ListTile(
                dense: true,
                leading: Icon(Icons.home, size: 18),
                title: Text(
                  '采用我方 (ours / 当前分支)',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
          if (f?.hasTheirs ?? true)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'theirs'),
              child: const ListTile(
                dense: true,
                leading: Icon(Icons.merge, size: 18),
                title: Text(
                  '采用对方 (theirs / 合入方)',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'edit'),
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.edit, size: 18),
              title: Text('手工编辑文件后自行 stage', style: TextStyle(fontSize: 13)),
            ),
          ),
        ],
      ),
    );
    if (side == null || side == 'edit') {
      if (side == 'edit' && mounted) showSnack(context, '编辑后请手动暂存该文件，再点"完成合并"');
      return;
    }
    await _act(
      () =>
          engine.resolveConflict(path: widget.repoPath, file: path, side: side),
      okMsg: '已采用${side == 'ours' ? '我方' : '对方'}',
    );
  }

  Widget _diffPane() {
    if (_diffFile == null) {
      return Center(
        child: Text(
          '点击文件查看差异',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.5),
            fontSize: 12.5,
          ),
        ),
      );
    }
    return Column(
      children: [
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: CircleAvatar(
            radius: 9,
            backgroundColor: _diffStaged ? Colors.green : Colors.blue,
            child: Text(
              _diffStaged ? 'S' : 'W',
              style: const TextStyle(fontSize: 10, color: Colors.white),
            ),
          ),
          title: Text(
            _diffFile!,
            style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _diffStaged ? '已暂存的差异（HEAD → index）' : '未暂存的差异（index → 工作树）',
            style: const TextStyle(fontSize: 10.5),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _diffFile = null),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: DiffView(
              patchText: _diffText,
              hunkActions: _diffStaged
                  ? (ctx, i, h) => _hunkRow(ctx, i, h, {'unstage': '取消暂存此块'})
                  : (ctx, i, h) => _hunkRow(ctx, i, h, {
                      'stage': '暂存此块',
                      'discard': '丢弃此块',
                    }),
            ),
          ),
        ),
      ],
    );
  }

  Widget _hunkRow(
    BuildContext ctx,
    int index,
    String header,
    Map<String, String> actions,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Wrap(
        spacing: 6,
        children: [
          for (final e in actions.entries)
            ActionChip(
              visualDensity: VisualDensity.compact,
              label: Text(e.value, style: const TextStyle(fontSize: 10.5)),
              avatar: Icon(
                e.key == 'discard' ? Icons.delete_outline : Icons.check,
                size: 13,
              ),
              onPressed: () => _hunkAction(index, e.key),
            ),
        ],
      ),
    );
  }

  Widget _mergeBar(engine.RepoSnapshot s) {
    if (!s.hasMergeHead) return const SizedBox.shrink();
    return Container(
      color: Colors.orange.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.merge, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '合并进行中 — 解决冲突并提交',
              style: TextStyle(fontSize: 11.5, color: Colors.orange.shade900),
            ),
          ),
          TextButton(
            onPressed: () => _act(
              () => engine.mergeCommit(path: widget.repoPath, message: null),
              okMsg: '合并已提交',
            ),
            child: const Text('完成合并', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () async {
              if (await confirmDialog(
                context,
                '中止合并',
                '放弃本次合并，恢复合并前状态？',
                action: '中止',
                danger: true,
              )) {
                _act(() => engine.mergeAbort(path: widget.repoPath));
              }
            },
            child: const Text('中止', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ---- 多选批量操作（只提交部分文件的标准路径：勾选 → 暂存所选 → 提交）----

  List<String> get _selectedStaged => [
    for (final k in _selected)
      if (k.startsWith('S:')) k.substring(2),
  ];

  /// 未暂存 + 未跟踪 的所选文件（都能被 stage 接受）。
  List<String> get _selectedWork => [
    for (final k in _selected)
      if (k.startsWith('W:')) k.substring(2),
  ];

  Future<void> _stageSelected() async {
    final files = _selectedWork;
    if (files.isEmpty) return;
    final ok = await _act(
      () => engine.stagePaths(path: widget.repoPath, files: files),
      okMsg: '已暂存 ${files.length} 个文件',
    );
    if (ok && mounted) _exitSelectMode();
  }

  Future<void> _unstageSelected() async {
    final files = _selectedStaged;
    if (files.isEmpty) return;
    final ok = await _act(
      () => engine.unstagePaths(path: widget.repoPath, files: files),
      okMsg: '已取消暂存 ${files.length} 个文件',
    );
    if (ok && mounted) _exitSelectMode();
  }

  Future<void> _discardSelected() async {
    final files = _selectedWork;
    if (files.isEmpty) return;
    final ok = await confirmDialog(
      context,
      '丢弃所选变更',
      '永久丢弃所选 ${files.length} 个文件的未暂存修改？无法从 AiwliGit 恢复。',
      action: '丢弃',
      danger: true,
    );
    if (!ok || !mounted) return;
    final done = await _act(
      () => engine.discardPaths(path: widget.repoPath, files: files),
      okMsg: '已丢弃 ${files.length} 个文件',
    );
    if (done && mounted) _exitSelectMode();
  }

  /// 只提交所选：把「所选已暂存 + 所选未暂存」打包成一个提交，
  /// 其余已暂存文件保持暂存状态（提交后原样恢复）。
  /// 实现等价于 git commit --only：暂存所选 → 取消暂存其余 → 提交 → 恢复。
  Future<void> _commitSelected() async {
    final work = _selectedWork;
    final stagedSel = _selectedStaged;
    final total = work.length + stagedSel.length;
    if (total == 0) return;
    var msg = _msgCtrl.text.trim();
    if (msg.isEmpty) {
      final entered = await textDialog(
        context,
        '提交所选 $total 个文件',
        hint: '提交信息…',
        maxLines: 3,
        confirmLabel: '提交',
      );
      if (entered == null || !mounted) return;
      msg = entered.trim();
      if (msg.isEmpty) {
        showSnack(context, '提交信息不能为空', error: true);
        return;
      }
    }
    // 提交后需要恢复暂存状态的文件：当前已暂存 − 所选（若该文件在暂存后
    // 又有新改动，恢复时会以工作区最新内容进入暂存区，原暂存拆分不再保留）
    final snap = _snap;
    final restore = <String>[
      if (snap != null)
        for (final f in snap.staged)
          if (!stagedSel.contains(f.path) && !work.contains(f.path)) f.path,
    ];
    final ok = await _act(() async {
      if (work.isNotEmpty) {
        await engine.stagePaths(path: widget.repoPath, files: work);
      }
      if (restore.isNotEmpty) {
        await engine.unstagePaths(path: widget.repoPath, files: restore);
      }
      try {
        await engine.commitStaged(
          path: widget.repoPath,
          message: msg,
          amend: false,
        );
      } catch (_) {
        // 提交失败：退回本次为凑提交而暂存的文件，尽量还原现场
        if (work.isNotEmpty) {
          try {
            await engine.unstagePaths(path: widget.repoPath, files: work);
          } catch (_) {}
        }
        rethrow;
      }
      // 成功：把「未提交但原本已暂存」的文件恢复暂存（尽力而为）
      if (restore.isNotEmpty) {
        try {
          await engine.stagePaths(path: widget.repoPath, files: restore);
        } catch (_) {}
      }
    }, okMsg: '已提交所选 $total 个文件');
    if (ok && mounted) {
      _msgCtrl.clear();
      _exitSelectMode();
    }
  }

  /// 选择模式下的底部工具栏，替代提交栏。
  Widget _selectionBar(engine.RepoSnapshot s) {
    final cs = Theme.of(context).colorScheme;
    final allKeys = <String>{
      for (final f in s.staged) _selKey(f.path, true),
      for (final f in s.unstaged) _selKey(f.path, false),
      for (final p in s.untracked) _selKey(p, false),
    };
    final allSelected = allKeys.isNotEmpty && _selected.containsAll(allKeys);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      color: cs.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              IconButton(
                tooltip: '退出选择',
                icon: const Icon(Icons.close, size: 20),
                onPressed: _exitSelectMode,
              ),
              Text(
                '已选 ${_selected.length}',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => setState(() {
                  if (allSelected) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(allKeys);
                  }
                }),
                child: Text(
                  allSelected ? '全不选' : '全选',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              FilledButton.icon(
                onPressed:
                    _locked || (_selectedWork.isEmpty && _selectedStaged.isEmpty)
                    ? null
                    : () => _commitSelected(),
                icon: const Icon(Icons.commit, size: 16),
                label: Text(
                  '提交所选 ${_selectedWork.length + _selectedStaged.length}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: _locked || _selectedWork.isEmpty
                    ? null
                    : () => _stageSelected(),
                icon: const Icon(Icons.add_task, size: 16),
                label: Text(
                  '暂存 ${_selectedWork.length}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: _locked || _selectedStaged.isEmpty
                    ? null
                    : () => _unstageSelected(),
                icon: const Icon(Icons.undo, size: 16),
                label: Text(
                  '取消暂存 ${_selectedStaged.length}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: _locked || _selectedWork.isEmpty
                    ? null
                    : () => _discardSelected(),
                icon: Icon(
                  Icons.delete_outline,
                  size: 16,
                  color: cs.error,
                ),
                label: Text(
                  '丢弃 ${_selectedWork.length}',
                  style: TextStyle(fontSize: 12, color: cs.error),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _commitBar() {
    final canCommit = _snap?.staged.isNotEmpty == true || _amend;
    if (!canCommit && _msgCtrl.text.trim().isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                '先暂存文件，再填写提交信息',
                style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 4,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _msgCtrl,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '提交信息…',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  suffix: GestureDetector(
                    onTap: () => setState(() => _amend = !_amend),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _amend
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 16,
                        ),
                        const Text('修改上一提交', style: TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _locked || !canCommit ? null : _commit,
              icon: const Icon(Icons.commit, size: 18),
              label: const Text('提交', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final s = _snap;
    final bodyContent = _error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                  if (_storageDenied) ...[
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        await SysAccess.openSettings();
                        if (mounted) _reload();
                      },
                      icon: const Icon(Icons.folder_off_outlined, size: 17),
                      label: const Text('去开启存储权限'),
                    ),
                  ],
                ],
              ),
            ),
          )
        : Column(
            children: [
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (s != null) _mergeBar(s),
              Expanded(
                child: wide
                    ? Row(
                        children: [
                          Expanded(flex: 4, child: _changesPane()),
                          const VerticalDivider(width: 1),
                          Expanded(flex: 6, child: _diffPane()),
                        ],
                      )
                    : _diffFile != null
                    ? Column(
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () => setState(() => _diffFile = null),
                              icon: const Icon(Icons.arrow_back, size: 18),
                              label: const Text('返回变更列表'),
                            ),
                          ),
                          Expanded(child: _diffPane()),
                        ],
                      )
                    : _changesPane(),
              ),
              _selectMode && s != null ? _selectionBar(s) : _commitBar(),
            ],
          );

    // 手机上使用单一变更流：点击文件后直接进入差异详情页，
    // 不再把“差异”伪装成第二个 Tab；宽屏仍保留左右分栏。
    return bodyContent;
  }
}
