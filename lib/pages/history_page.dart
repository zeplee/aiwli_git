import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/ffi.dart' as engine;
import '../widgets/dialogs.dart';
import 'commit_detail.dart';

/// History: commit graph lanes + search (debounced auto-query) + load-more.
/// Tap → commit detail.
class HistoryPage extends StatefulWidget {
  final String repoPath;
  final int tick; // bumped by WorkbenchHost on external changes → reload
  const HistoryPage({super.key, required this.repoPath, this.tick = 0});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _GraphNode {
  final engine.LogEntry e;
  final int lane;
  _GraphNode(this.e, this.lane);
}

class _HistoryPageState extends State<HistoryPage> {
  List<engine.LogEntry> _commits = [];
  String? _error;
  bool _busy = false;
  bool _noMore = false;
  String _query = '';
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  int _laneCount = 1;
  int _requestSerial = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadMore(reset: true);
  }

  @override
  void didUpdateWidget(covariant HistoryPage old) {
    super.didUpdateWidget(old);
    if (widget.tick != old.tick) {
      _query = _searchCtrl.text.trim();
      _loadMore(reset: true);
    }
  }

  Future<void> _loadMore({bool reset = false}) async {
    if (_busy || !mounted) return;
    final serial = ++_requestSerial;
    setState(() {
      _busy = true;
      if (reset) _noMore = false;
      if (reset) _error = null;
    });
    try {
      final batch = await engine.log(
        path: widget.repoPath,
        skip: reset ? 0 : _commits.length,
        limit: 80,
        query: _query.isEmpty ? null : _query,
      );
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        if (reset) {
          _commits = batch;
        } else {
          _commits.addAll(batch);
        }
        if (batch.length < 80) _noMore = true;
        _busy = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _error = friendlyError(e);
        _busy = false;
      });
    }
  }

  /// Lane layout: reuse parent lane when possible, else first free lane.
  List<_GraphNode> _layout() {
    final active = <String?>[];
    final out = <_GraphNode>[];
    for (final c in _commits) {
      int lane = active.indexOf(c.info.id);
      if (lane < 0) {
        lane = active.indexOf(null);
        if (lane < 0) {
          active.add(null);
          lane = active.length - 1;
        }
      }
      active[lane] = c.parents.isNotEmpty ? c.parents.first : null;
      for (var i = 1; i < c.parents.length; i++) {
        if (!active.contains(c.parents[i])) {
          int f = active.indexOf(null);
          if (f < 0) {
            active.add(null);
            f = active.length - 1;
          }
          active[f] = c.parents[i];
        }
      }
      out.add(_GraphNode(c, lane));
    }
    return out;
  }

  static const _laneColors = [
    Color(0xFF2196F3),
    Color(0xFF9C27B0),
    Color(0xFF4CAF50),
    Color(0xFFFF9800),
    Color(0xFF00BCD4),
    Color(0xFFE91E63),
    Color(0xFF8BC34A),
  ];

  Widget _refChip(String r, ColorScheme cs) {
    final isTag = r.startsWith('tag:');
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
      decoration: BoxDecoration(
        color: isTag
            ? Colors.deepOrange.shade100
            : cs.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isTag ? r.substring(4) : r,
        style: TextStyle(
          fontSize: 9,
          color: isTag ? Colors.deepOrange.shade900 : cs.primary,
        ),
      ),
    );
  }

  Widget _commitRow(BuildContext context, _GraphNode n, ColorScheme cs) {
    final c = n.e.info;
    final t = DateTime.fromMillisecondsSinceEpoch(c.timeUnix * 1000);
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                CommitDetailPage(repoPath: widget.repoPath, commitId: c.id),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 24.0 * _laneCount,
              height: 42,
              child: CustomPaint(
                painter: _LanePainter(
                  lane: n.lane,
                  lanes: _laneCount,
                  color: _laneColors[n.lane % _laneColors.length],
                  isMerge: n.e.parents.length > 1,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          c.summary,
                          style: const TextStyle(fontSize: 12.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (final r in n.e.refs.take(2)) _refChip(r, cs),
                    ],
                  ),
                  Text(
                    '${c.shortId} · ${c.author} · ${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontSize: 10,
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nodes = _layout();
    _laneCount = nodes
        .fold(1, (m, n) => n.lane + 1 > m ? n.lane + 1 : m)
        .clamp(1, 6);
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
          child: TextField(
            controller: _searchCtrl,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: '搜索 信息 / 作者 / hash',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
            onChanged: (v) {
              // debounced auto-search while typing
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 500), () {
                if (!mounted) return;
                setState(() => _query = v.trim());
                _loadMore(reset: true);
              });
            },
            onSubmitted: (v) {
              _debounce?.cancel();
              setState(() => _query = v.trim());
              _loadMore(reset: true);
            },
          ),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.pixels > n.metrics.maxScrollExtent - 400 &&
                  !_busy &&
                  !_noMore) {
                _loadMore();
              }
              return false;
            },
            child: RefreshIndicator(
              onRefresh: () => _loadMore(reset: true),
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
                            onPressed: () => _loadMore(reset: true),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 30),
                      itemCount: nodes.length + 2,
                      itemBuilder: (context, i) {
                        if (i >= nodes.length) {
                          return Padding(
                            padding: const EdgeInsets.all(14),
                            child: Center(
                              child: _busy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : _noMore && _commits.isNotEmpty
                                  ? Text(
                                      '— 到底了（${_commits.length} 个提交）—',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: cs.onSurface.withValues(
                                          alpha: 0.4,
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          );
                        }
                        return _commitRow(context, nodes[i], cs);
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LanePainter extends CustomPainter {
  final int lane, lanes;
  final Color color;
  final bool isMerge;
  _LanePainter({
    required this.lane,
    required this.lanes,
    required this.color,
    required this.isMerge,
  });
  @override
  void paint(Canvas canvas, Size size) {
    final x = (lane + 0.5) * size.width / lanes;
    final p = Paint()
      ..strokeWidth = 1.5
      ..color = color.withValues(alpha: 0.55);
    if (isMerge) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height * 0.5), p);
      if (lane > 0) {
        canvas.drawLine(
          Offset(x - size.width * 0.16, size.height),
          Offset(x, size.height * 0.5),
          p,
        );
      }
    } else {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    canvas.drawCircle(
      Offset(x, size.height / 2),
      isMerge ? 5 : 4,
      Paint()..color = color,
    );
    canvas.drawCircle(
      Offset(x, size.height / 2),
      2,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _LanePainter old) =>
      old.lane != lane || old.color != color || old.isMerge != isMerge;
}
