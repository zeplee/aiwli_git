import 'dart:async';

import 'package:flutter/material.dart';

import '../core/operation.dart';
import 'dialogs.dart';

/// 常驻操作条：git 写操作的进行状态与终态都显示在这里。
///
/// 挂在 [WorkbenchHost] 的 TabBar 之下、内容之上，所以切 Tab 也在——
/// 以前操作结果只走 2～4 秒的 snackbar，切页或读屏慢一点就永远错过了。
/// v1.5.20 起它是同步操作的**唯一**反馈载体（成功/中性短暂自隐，
/// 失败常驻直到用户处理）。
class OperationBar extends StatefulWidget {
  const OperationBar({super.key});

  @override
  State<OperationBar> createState() => _OperationBarState();
}

class _OperationBarState extends State<OperationBar> {
  final _op = OperationController.instance;
  Timer? _ticker;
  Timer? _autoHide;
  OpStatus _lastStatus = OpStatus.idle;
  DateTime? _lastFinishedAt;
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    _lastStatus = _op.value.status;
    _lastFinishedAt = _op.value.finishedAt;
    _op.addListener(_onChanged);
    _reschedule();
  }

  @override
  void dispose() {
    _op.removeListener(_onChanged);
    _ticker?.cancel();
    _autoHide?.cancel();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final v = _op.value;
    final moved =
        v.status != _lastStatus || v.finishedAt != _lastFinishedAt;
    _lastStatus = v.status;
    _lastFinishedAt = v.finishedAt;
    if (moved) _showRaw = false; // 换了终态就收起上一次的详情
    setState(() {});
    if (moved) _reschedule();
  }

  void _reschedule() {
    _ticker?.cancel();
    _autoHide?.cancel();
    final v = _op.value;
    if (v.isRunning) {
      // 每秒重画一次「已用 Ns」。计时器必须留在这里：控制器的通知只在
      // **阶段变化**时发出，若让控制器每秒通知，工作台整棵树都会跟着重建。
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _op.value.isRunning) setState(() {});
      });
    } else if (v.status == OpStatus.success) {
      _autoHide = Timer(const Duration(seconds: 4), () {
        if (mounted && _op.value.status == OpStatus.success) _op.dismiss();
      });
    } else if (v.status == OpStatus.notice) {
      _autoHide = Timer(const Duration(seconds: 6), () {
        if (mounted && _op.value.status == OpStatus.notice) _op.dismiss();
      });
    }
    // failed 故意不自动消失：错误需要用户读到并处理。
  }

  String _subline(OperationState v) {
    final took = formatElapsed(v.elapsed());
    if (v.isRunning) {
      return v.phase.isEmpty ? '已用 $took' : '${v.phase} · 已用 $took';
    }
    return v.status == OpStatus.failed ? '未完成 · 耗时 $took' : '耗时 $took';
  }

  @override
  Widget build(BuildContext context) {
    final v = _op.value;
    if (v.status == OpStatus.idle) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    final isFail = v.status == OpStatus.failed;
    final isOk = v.status == OpStatus.success;
    final bg = isFail
        ? cs.errorContainer
        : (isOk ? cs.primaryContainer : cs.surfaceContainerHighest);
    final fg = isFail
        ? cs.onErrorContainer
        : (isOk ? cs.onPrimaryContainer : cs.onSurface);
    final muted = fg.withValues(alpha: 0.72);

    final Widget leading;
    if (v.isRunning) {
      leading = SizedBox(
        width: 15,
        height: 15,
        child: CircularProgressIndicator(strokeWidth: 2, color: fg),
      );
    } else if (isFail) {
      leading = Icon(Icons.error_outline, size: 17, color: fg);
    } else if (isOk) {
      leading = Icon(Icons.check_circle_outline, size: 17, color: fg);
    } else {
      leading = Icon(Icons.info_outline, size: 17, color: fg);
    }

    // 折叠态只放人话：friendlyError 会在尾部追加「（原始：…）」且截到 240 字，
    // 那截断的原始串留给「详情」展开（完整、可选中复制）。
    final headline = v.isRunning
        ? v.title
        : shortReason(v.message ?? v.title);

    return Material(
      color: bg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        style: TextStyle(fontSize: 12.5, color: fg, height: 1.3),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subline(v),
                        style: TextStyle(fontSize: 11, color: muted),
                      ),
                    ],
                  ),
                ),
                if (isFail && v.onRetry != null)
                  TextButton(
                    onPressed: v.onRetry,
                    style: TextButton.styleFrom(
                      foregroundColor: fg,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('重试', style: TextStyle(fontSize: 12)),
                  ),
                if (isFail && (v.rawError ?? '').isNotEmpty)
                  IconButton(
                    tooltip: _showRaw ? '收起原始错误' : '查看原始错误',
                    onPressed: () => setState(() => _showRaw = !_showRaw),
                    icon: Icon(
                      _showRaw ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: fg,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                if (!v.isRunning)
                  IconButton(
                    tooltip: '关闭',
                    onPressed: _op.dismiss,
                    icon: Icon(Icons.close, size: 17, color: fg),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          // 复用工作台原有的 2px 细进度条语言（"有事在跑"的既有视觉约定）。
          if (v.isRunning)
            LinearProgressIndicator(
              minHeight: 2,
              color: fg,
              backgroundColor: fg.withValues(alpha: 0.18),
            ),
          if (_showRaw && (v.rawError ?? '').isNotEmpty)
            Container(
              width: double.infinity,
              color: fg.withValues(alpha: 0.06),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: SelectableText(
                v.rawError!,
                style: TextStyle(
                  fontSize: 11,
                  color: fg,
                  height: 1.35,
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
    );
  }
}