
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aiwli_git/ui/app_shell.dart';

/// v1.4.4 导航模型：仓库主页页（ReposPage）已删除，工作台即唯一主页；
/// 无仓库时落在工作台空态（自带扫描/添加远程），无底部 tab / rail。
/// 10-03：空态同样挂仓库侧栏（宽屏常驻 / 手机抽屉+汉堡）——侧栏全局
/// 常驻，「应用设置」任何状态下都可达。
/// 仅渲染断言：AppShell.initState 会起 MCP server、空态扫描走真实
/// Prefs 文件 IO，fake-async 区不可点击触发。
void main() {
  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AppShell(onThemeChanged: (_) {})),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('AppShell empty (phone): drawer keeps settings reachable', (
    tester,
  ) async {
    await pump(tester, const Size(600, 900));

    // 空态欢迎页（无仓库恢复时的起点）
    expect(find.text('还没有打开的仓库'), findsOneWidget);
    expect(find.text('扫描本地仓库'), findsOneWidget);
    expect(find.text('添加远程'), findsOneWidget);
    // 侧栏全局常驻：窄屏收进抽屉，AppBar 汉堡可开。DrawerController 懒构建：
    // 抽屉关闭时 Drawer 子树根本不在树里（实测探针），必须先拉开再断言。
    // 用定长 pump 而非 pumpAndSettle：侧栏加载态的 CircularProgressIndicator
    // 在 fake-async 下永转（Prefs 真实 IO 不返回），settle 永不收敛。
    expect(find.byIcon(Icons.menu), findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(Drawer), findsOneWidget);
    expect(find.text('应用设置'), findsOneWidget);
    // 品牌名 = AppBar 标题 + 侧栏头部各一次
    expect(find.text('AiwliGit'), findsNWidgets(2));
    // 旧导航模型不再存在
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRail), findsNothing);
    // 旧仓库主页页与其品牌大标题不再存在
    expect(find.byIcon(Icons.folder_special_outlined), findsNothing);
  });

  testWidgets('AppShell empty (wide): permanent sidebar, no drawer', (
    tester,
  ) async {
    await pump(tester, const Size(900, 700));

    expect(find.byType(Drawer), findsNothing);
    expect(find.byIcon(Icons.menu), findsNothing);
    expect(find.text('应用设置'), findsOneWidget);
    expect(find.text('AiwliGit'), findsNWidgets(2));
    expect(find.text('还没有打开的仓库'), findsOneWidget);
  });
}
