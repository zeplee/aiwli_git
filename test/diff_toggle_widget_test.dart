import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aiwli_git/widgets/diff_view.dart';

void main() {
  const patch =
      'diff --git a/f b/f\n--- a/f\n+++ b/f\n'
      '@@ -1,1 +1,1 @@\n-old line\n+new line\n';

  testWidgets('DiffView shows layout toggle on wide screens and switches', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DiffView(patchText: patch)),
      ),
    );
    // 统一视图默认渲染 + toggle 可见
    expect(find.text('左右对照'), findsOneWidget);
    expect(find.text('-old line'), findsOneWidget);
    // 切到左右对照
    await tester.tap(find.text('左右对照'));
    await tester.pumpAndSettle();
    expect(find.text('统一视图'), findsOneWidget);
    // 分栏后 old / new 各占一列
    expect(find.text('-old line'), findsOneWidget);
    expect(find.text('+new line'), findsOneWidget);
  });

  testWidgets('DiffView hides toggle on very narrow screens', (tester) async {
    tester.view.physicalSize = const Size(340, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DiffView(patchText: patch)),
      ),
    );
    expect(find.text('左右对照'), findsNothing);
  });
}
