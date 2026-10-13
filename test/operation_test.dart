import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aiwli_git/core/operation.dart';
import 'package:aiwli_git/widgets/dialogs.dart';
import 'package:aiwli_git/widgets/op_bar.dart';

/// v1.5.20 操作反馈回归测试。
///
/// 背景：`runSync` 原先从「点击」到 `showSnack` 之间**没有任何状态变更**
/// （引擎是一次性请求/响应：`Isolate.run` + 单个 JSON 返回值），所以用户看到的
/// 「点了没反应」是设计上的必然，不是漏加转圈。这里锁住四件事：
///
///  1. 状态机语义——阶段只在进行中生效、终态不被后续打点“复活”、dismiss 幂等；
///  2. 失败**常驻**——错误不能像原先那样 4 秒就消失（v1.5.18 实测：读屏都来不及）；
///  3. 原始错误不被折叠态吞掉：「详情」里是**未截断**、可选中复制的完整串
///     （`friendlyError` 只保留 240 字），这是把真因原样发出来的唯一通道；
///  4. 同值 phase 不触发通知——否则每秒重画会连带重建整个工作台。
void main() {
  final op = OperationController.instance;

  setUp(op.reset);
  tearDown(op.reset);

  group('OperationController 状态机', () {
    test('begin → 进行中，带标题与起始时刻', () {
      op.begin('推送提交');
      expect(op.isRunning, isTrue);
      expect(op.value.title, '推送提交');
      expect(op.value.phase, '准备中…');
      expect(op.value.startedAt, isNotNull);
      expect(op.value.finishedAt, isNull);
    });

    test('phase 只在进行中生效，不复活终态', () {
      op.begin('推送提交');
      op.phase('连接远程并上传…');
      expect(op.value.phase, '连接远程并上传…');

      op.succeed('已推送 main → origin');
      op.phase('不该出现');
      expect(op.value.status, OpStatus.success);
      expect(op.value.phase, isNot('不该出现'));
    });

    test('同值 phase 不发通知（避免无意义重建）', () {
      op.begin('拉取更新');
      var hits = 0;
      void count() => hits++;
      op.addListener(count);
      op.phase('准备中…'); // 与当前相同
      expect(hits, 0);
      op.phase('连接远程并合并…');
      expect(hits, 1);
      op.removeListener(count);
    });

    test('retitle 只在进行中生效', () {
      op.begin('推送提交');
      op.retitle('推送 main → origin');
      expect(op.value.title, '推送 main → origin');
      op.succeed('已推送 main → origin');
      op.retitle('不该生效');
      expect(op.value.title, '推送 main → origin');
    });

    test('fail 记录原始错误与重试入口；终态 elapsed 不再增长', () {
      op.begin('推送提交');
      op.fail(
        '网络连接失败',
        rawError: 'push 失败: SSL error: syscall failure: Connection reset by peer',
        onRetry: () {},
      );
      expect(op.value.status, OpStatus.failed);
      expect(op.value.rawError, contains('Connection reset by peer'));
      expect(op.value.onRetry, isNotNull);
      expect(op.value.finishedAt, isNotNull);

      final atFinish = op.value.elapsed();
      final muchLater = op.value.elapsed(
        DateTime.now().add(const Duration(hours: 1)),
      );
      expect(muchLater, atFinish); // 终态只看 finishedAt
    });

    test('succeed 不带重试入口（成功没什么可重试的）', () {
      op.begin('拉取更新');
      op.succeed('已经是最新');
      expect(op.value.status, OpStatus.success);
      expect(op.value.onRetry, isNull);
      expect(op.value.rawError, isNull);
    });

    test('dismiss 幂等且回到 idle', () {
      op.dismiss();
      expect(op.value.status, OpStatus.idle);
      op.begin('推送提交');
      op.dismiss();
      expect(op.value.status, OpStatus.idle);
      op.dismiss();
      expect(op.value.status, OpStatus.idle);
    });
  });

  group('formatElapsed', () {
    test('秒 / 分钟格式化', () {
      expect(formatElapsed(Duration.zero), '0s');
      expect(formatElapsed(const Duration(seconds: 42)), '42s');
      expect(formatElapsed(const Duration(seconds: 60)), '1m');
      expect(formatElapsed(const Duration(seconds: 65)), '1m 05s');
      expect(formatElapsed(const Duration(minutes: 12, seconds: 3)), '12m 03s');
    });
  });

  group('shortReason：折叠态只留人话', () {
    test('剥掉 friendlyError 追加的（原始：…）尾巴', () {
      const friendly =
          '网络连接失败：请检查网络后重试。（原始：push 失败: SSL error: '
          'syscall failure: Connection reset by peer; class=Os (2)）';
      final short = shortReason(friendly);
      expect(short, '网络连接失败：请检查网络后重试。');
      expect(short.contains('原始'), isFalse);
    });

    test('没有尾巴时原样返回', () {
      expect(shortReason('分离 HEAD，无法推送。'), '分离 HEAD，无法推送。');
    });

    test('只有尾巴时退回原文，避免折叠态变空白', () {
      const only = '（原始：push 失败）';
      expect(shortReason(only), only);
    });
  });

  group('OperationBar', () {
    Future<void> mount(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: OperationBar())),
      );
    }

    testWidgets('idle 时完全不占位', (tester) async {
      await mount(tester);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byType(SelectableText), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('进行中显示标题 + 阶段 + 已用时间；阶段变化即时反映', (tester) async {
      await mount(tester);
      op.begin('推送提交');
      await tester.pump();

      expect(find.text('推送提交'), findsOneWidget);
      expect(find.textContaining('准备中…'), findsOneWidget);
      expect(find.textContaining('已用'), findsOneWidget);
      // 进行中不给关闭按钮：让用户不能把「正在发生什么」关掉
      expect(find.byTooltip('关闭'), findsNothing);
      // 细进度条是「有事在跑」的既有视觉约定
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      op.phase('连接远程并上传…');
      await tester.pump();
      expect(find.textContaining('连接远程并上传…'), findsOneWidget);

      await tester.pumpWidget(const SizedBox()); // 释放秒表
    });

    testWidgets('失败常驻、可重试、原始错误未截断且可展开复制', (tester) async {
      await mount(tester);
      final longRaw = 'push 失败: ${'x' * 300}';
      var retried = 0;

      op.begin('推送提交');
      await tester.pump();
      op.fail(
        '网络连接失败：请检查网络后重试。（原始：${longRaw.substring(0, 240)}…）',
        rawError: longRaw,
        onRetry: () => retried++,
      );
      await tester.pump();

      expect(find.textContaining('网络连接失败'), findsOneWidget);
      // 折叠态不能把「（原始：…）」也糊上去——人话与证据分开
      expect(find.textContaining('原始：'), findsNothing);
      expect(find.text('重试'), findsOneWidget);

      // 失败不自动消失：等 10 秒仍在（原先 snackbar 4 秒就没了）
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('重试'), findsOneWidget);

      // 展开：未截断的完整原始串，且可选中（便于原样发出去）
      await tester.tap(find.byTooltip('查看原始错误'));
      await tester.pump();
      final st = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(st.data, longRaw);
      expect(st.data!.length, greaterThan(240));

      await tester.tap(find.text('重试'));
      expect(retried, 1);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('成功自动淡出（4 秒）', (tester) async {
      await mount(tester);
      op.begin('拉取更新');
      await tester.pump();
      op.succeed('已经是最新');
      await tester.pump();
      expect(find.text('已经是最新'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.text('已经是最新'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('切到终态后收起上一次展开的详情', (tester) async {
      await mount(tester);
      op.begin('推送提交');
      await tester.pump();
      op.fail('失败了', rawError: 'raw-a');
      await tester.pump();
      await tester.tap(find.byTooltip('查看原始错误'));
      await tester.pump();
      expect(find.byType(SelectableText), findsOneWidget);

      // 新的一次操作进来 → 旧的详情必须收起，否则会张冠李戴
      op.begin('拉取更新');
      await tester.pump();
      op.fail('又失败了', rawError: 'raw-b');
      await tester.pump();
      expect(find.byType(SelectableText), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });
}