import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aiwli_git/widgets/dialogs.dart';

/// v1.4.2 扁平化导航：Stash / 远程设置等改为 showFullSheet 满高底部弹层，
/// 不再推入二级页。此测试锁定 helper 的行为契约（满高 + 内容可见 + 下拉可关）。
void main() {
  testWidgets('showFullSheet opens a tall bottom sheet and drags to close', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => showFullSheet(
                  ctx,
                  const Scaffold(body: Center(child: Text('弹层内容'))),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 内容可见
    expect(find.text('弹层内容'), findsOneWidget);
    // 满高契约：sheet 高度接近屏高（isScrollControlled + 0.93）
    final media = tester.element(find.text('弹层内容'));
    final sheetBox = media.findAncestorRenderObjectOfType<RenderBox>()!;
    expect(sheetBox.size.height, greaterThan(2400 * 0.85));
    expect(sheetBox.size.height, lessThan(2400 * 0.99));

    // 下拉关闭（内容是 Center，直接拖 sheet 即可；满高 sheet 需拖过半屏）
    await tester.drag(find.text('弹层内容'), const Offset(0, 1400));
    await tester.pumpAndSettle();
    expect(find.text('弹层内容'), findsNothing);
  });
}
