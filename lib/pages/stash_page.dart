import 'package:flutter/material.dart';

import '../engine/ffi.dart' as engine;
import '../widgets/dialogs.dart';

/// Stash management: list, pop, apply, drop, new stash.
/// 满高底部弹层（v1.4.2 起不再是推入的二级页），下拉即可关闭。
class StashSheet extends StatefulWidget {
  final String repoPath;
  final int tick; // kept for interface parity; stash is opened fresh each time
  final VoidCallback onMutated;
  const StashSheet({
    super.key,
    required this.repoPath,
    this.tick = 0,
    required this.onMutated,
  });
  @override
  State<StashSheet> createState() => _StashPageState();
}

class _StashPageState extends State<StashSheet> {
  List<engine.StashEntry>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    try {
      final l = await engine.stashList(path: widget.repoPath);
      if (!mounted) return;
      setState(() {
        _list = l;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    }
  }

  void _act(Future<void> Function() f, String ok) async {
    try {
      await f();
      if (mounted) showSnack(context, ok);
      widget.onMutated();
    } catch (e) {
      if (mounted) {
        showSnack(context, friendlyError(e), error: true);
      }
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    final cs = Theme.of(context).colorScheme;
    Future<void> stashNow() async {
      final msg = await textDialog(context, 'Stash 说明（可空）', hint: 'WIP …');
      if (msg == null) return;
      _act(
        () => engine.stashPush(
          path: widget.repoPath,
          message: msg.isEmpty ? null : msg,
        ),
        '已 stash',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ---- 头部：标题 + 新建 stash ----
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
          child: Row(
            children: [
              Icon(Icons.inventory_2_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Stash 临时保存',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: stashNow,
                icon: const Icon(Icons.inventory, size: 16),
                label: const Text('Stash 现在', style: TextStyle(fontSize: 12.5)),
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
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: _reload,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : l == null
              ? const Center(child: CircularProgressIndicator())
              : l.isEmpty
              ? const Center(
                  child: Text('没有 stash', style: TextStyle(color: Colors.grey)),
                )
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      for (final e in l)
                        ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.inventory_2,
                            size: 18,
                            color: Colors.deepPurple,
                          ),
                          title: Text(
                            e.message.isEmpty
                                ? 'WIP on ${e.id.substring(0, 7)}'
                                : e.message,
                            style: const TextStyle(fontSize: 12.5),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            'stash@{${e.index}} · ${e.id.substring(0, 7)} · ${DateTime.fromMillisecondsSinceEpoch(e.timeUnix * 1000).toString().substring(5, 16)}',
                            style: const TextStyle(fontSize: 10.5),
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) async {
                              switch (v) {
                                case 'pop':
                                  _act(
                                    () => engine.stashPop(
                                      path: widget.repoPath,
                                      index: e.index,
                                    ),
                                    '已恢复并删除 stash',
                                  );
                                case 'apply':
                                  _act(
                                    () => engine.stashApply(
                                      path: widget.repoPath,
                                      index: e.index,
                                    ),
                                    '已恢复 stash',
                                  );
                                case 'drop':
                                  if (await confirmDialog(
                                    context,
                                    '删除暂存现场？',
                                    '删除后无法从 AiwliGit 恢复这份暂存内容。',
                                    action: '删除',
                                    danger: true,
                                  )) {
                                    _act(
                                      () => engine.stashDrop(
                                        path: widget.repoPath,
                                        index: e.index,
                                      ),
                                      '已删除暂存现场',
                                    );
                                  }
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'pop',
                                child: Text(
                                  '恢复并删除（Pop）',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'apply',
                                child: Text(
                                  '仅恢复（Apply）',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                              PopupMenuItem(
                                value: 'drop',
                                child: Text(
                                  '删除（Drop）',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
