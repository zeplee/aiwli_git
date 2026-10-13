import 'package:flutter/foundation.dart';

/// Git 写操作的生命周期（v1.5.20）。
///
/// 为什么需要它：`runSync` 以前从「点击」到 `showSnack` 之间**没有任何状态
/// 变更**——引擎是一次性请求/响应（`Isolate.run` + 单个 JSON 返回值），
/// 所以「点了没反应」不是漏加了转圈，而是**设计上不存在可显示的中间事实**。
/// 这里把「点击 → 结果」显式建模，让 UI 有东西可显示：
///
///     idle → running(阶段) → success | failed | notice → idle
///
/// - [OpStatus.running]：常驻操作条，带**阶段文字**与**已用时间**。已用时间
///   是「没卡死」的唯一证明——没有它，用户无法区分「慢」和「死了」；本次
///   排障时我盯着 `gitdeck_error.log` 猜了三分钟，就是在人工做这件事。
/// - [OpStatus.success]：自动淡出——低信息量且可自证（远程跟踪引用已随之更新）。
/// - [OpStatus.failed]：**常驻**，直到用户处理或重试。错误不该 4 秒就消失
///   （v1.5.18 实测：徽标 4 秒后消失，读屏都来不及）。
/// - [OpStatus.notice]：中性提示——操作没执行，但不是错误（如用户未接受
///   SSH 主机指纹）。
///
/// **阶段粒度是诚实的**：`engine.push` 是一次阻塞调用，我们只能在**自己
/// 调用的步骤边界**上打点，「连接 / 认证 / 上传」的细分要等 Rust 侧
/// `transfer_progress` / `sideband_progress` 回调（见 docs/16 的 P2）。
/// 这里不假装知道引擎内部在做什么。
enum OpStatus { idle, running, success, failed, notice }

/// 时长格式化：「12s」/「1m 05s」，用于操作条的「已用 N」。
String formatElapsed(Duration d) {
  final total = d.inSeconds;
  if (total < 60) return '${total}s';
  final m = total ~/ 60;
  final s = total % 60;
  return s == 0 ? '${m}m' : '${m}m ${s.toString().padLeft(2, '0')}s';
}

@immutable
class OperationState {
  const OperationState({
    required this.status,
    this.title = '',
    this.phase = '',
    this.message,
    this.rawError,
    this.startedAt,
    this.finishedAt,
    this.onRetry,
  });

  final OpStatus status;

  /// 操作标题，如「推送 main → origin」。
  final String title;

  /// 进行中的阶段文字，如「连接远程并上传…」。
  final String phase;

  /// 终态展示文案（失败时即人话原因）。
  final String? message;

  /// 失败时的**未截断**原始错误，供「详情」展开并长按复制。
  /// `friendlyError` 已把原始串截到 240 字附在人话后面，这里保留完整串
  /// 且单独可选中，是为了让用户能把真因原样发出去——本次排障正需要它。
  final String? rawError;

  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// 失败终态的重试入口；为空则不显示「重试」。
  final VoidCallback? onRetry;

  static const OperationState idle = OperationState(status: OpStatus.idle);

  bool get isRunning => status == OpStatus.running;

  /// 已用时长：进行中按 `now` 算，终态按结束时刻算。
  Duration elapsed([DateTime? now]) {
    final s = startedAt;
    if (s == null) return Duration.zero;
    final d = (finishedAt ?? now ?? DateTime.now()).difference(s);
    return d.isNegative ? Duration.zero : d;
  }
}

/// 全局唯一的操作状态源。操作条与按钮锁都只读它。
class OperationController extends ValueNotifier<OperationState> {
  OperationController._() : super(OperationState.idle);

  static final OperationController instance = OperationController._();

  bool get isRunning => value.isRunning;

  void begin(String title) {
    value = OperationState(
      status: OpStatus.running,
      title: title,
      phase: '准备中…',
      startedAt: DateTime.now(),
    );
  }

  /// 解析出具体目标后细化标题（如「推送提交」→「推送 main → origin」）。
  void retitle(String title) {
    if (!value.isRunning) return;
    value = OperationState(
      status: OpStatus.running,
      title: title,
      phase: value.phase,
      startedAt: value.startedAt,
    );
  }

  /// 推进阶段。非进行中时忽略——避免终态被后续打点"复活"。
  void phase(String phase) {
    if (!value.isRunning || value.phase == phase) return;
    value = OperationState(
      status: OpStatus.running,
      title: value.title,
      phase: phase,
      startedAt: value.startedAt,
    );
  }

  void succeed(String message) {
    value = OperationState(
      status: OpStatus.success,
      title: value.title,
      message: message,
      startedAt: value.startedAt,
      finishedAt: DateTime.now(),
    );
  }

  void fail(String message, {String? rawError, VoidCallback? onRetry}) {
    value = OperationState(
      status: OpStatus.failed,
      title: value.title,
      message: message,
      rawError: rawError,
      startedAt: value.startedAt,
      finishedAt: DateTime.now(),
      onRetry: onRetry,
    );
  }

  void notice(String message) {
    value = OperationState(
      status: OpStatus.notice,
      title: value.title,
      message: message,
      startedAt: value.startedAt,
      finishedAt: DateTime.now(),
    );
  }

  void dismiss() {
    if (value.status == OpStatus.idle) return;
    value = OperationState.idle;
  }

  @visibleForTesting
  void reset() => value = OperationState.idle;
}