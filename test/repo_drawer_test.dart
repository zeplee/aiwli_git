import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aiwli_git/pages/repo_drawer.dart';

/// v1.4.4 侧栏目录化契约（10-01 定稿 + 10-02 追加）：
/// 「左侧只负责选仓库」；追加结论——
/// ① 不做「最近使用」分组（目录应稳定，不该自己变）；
/// ② 不做「仓库主页」入口（该页已整体删除）；
/// ③ 仓库列表支持长按拖动手动排序（repoOrder 持久化）；
/// ④ 头部只留应用名+计数（10-03：radar 直扫按钮移除，扫描收进添加弹层）；
/// ⑤ 仓库专属操作（分支/标签/Stash/远程/快捷同步）不得回流侧栏。
void main() {
  const repos = [
    '/data/projects/gd',
    '/data/projects/ai',
    '/data/projects/gs',
    '/data/projects/x1',
    '/data/projects/x2',
    '/data/projects/x3',
  ];

  /// 打开抽屉后再断言——Scaffold.drawer 懒构建，不开抽屉子树不实例化。
  Future<void> openSidebar(
    WidgetTester tester, {
    required ValueChanged<String> onOpenRepo,
    VoidCallback? onOpenSettings,
    List<String> reposOverride = repos,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        drawer: Drawer(
          child: RepoSidebar(
            repoPath: '/data/projects/gd',
            reposOverride: reposOverride,
            onOpenRepo: onOpenRepo,
            onOpenSettings: onOpenSettings,
          ),
        ),
        body: const SizedBox.shrink(),
      ),
    ));
    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
  }

  testWidgets('平铺目录：全部仓库一列，无分组标题、无仓库主页', (tester) async {
    await openSidebar(tester, onOpenRepo: (_) {});

    expect(find.text('AiwliGit'), findsOneWidget);
    // 10-02 追加：目录化后不再有分组与主页入口
    expect(find.text('最近使用'), findsNothing);
    expect(find.text('全部仓库'), findsNothing);
    expect(find.text('仓库主页'), findsNothing);
    // 底部固定入口：添加 + 设置（均固定可见，无需滚动）
    expect(find.text('＋ 添加仓库'), findsOneWidget);
    expect(find.text('应用设置'), findsOneWidget);
    // 当前仓库高亮
    expect(find.byIcon(Icons.folder_special), findsOneWidget);
    // 6 个仓库全部渲染（含最后一行，平铺无折叠区）
    for (final name in ['gd', 'ai', 'gs', 'x3']) {
      expect(find.text(name), findsOneWidget);
    }
  });

  testWidgets('头部：仓库计数；radar 直扫按钮已移除（收进添加弹层）', (tester) async {
    await openSidebar(tester, onOpenRepo: (_) {});

    expect(find.text('仓库目录 · 6'), findsOneWidget);
    expect(find.byIcon(Icons.radar_outlined), findsNothing);
  });

  testWidgets('交互：点非当前仓库切换；点应用设置回调', (tester) async {
    String? opened;
    var wentSettings = false;
    await openSidebar(
      tester,
      onOpenRepo: (p) => opened = p,
      onOpenSettings: () => wentSettings = true,
    );

    await tester.tap(find.text('gs'));
    expect(opened, '/data/projects/gs');
    await tester.tap(find.text('应用设置'));
    expect(wentSettings, isTrue);
  });

  testWidgets('定稿红线：仓库专属内容与已删入口不得回流侧栏', (tester) async {
    await openSidebar(tester, onOpenRepo: (_) {});

    // 仓库专属操作（应只在主工作区）
    expect(find.text('临时保存'), findsNothing);
    expect(find.text('临时保存（无）'), findsNothing);
    expect(find.text('管理分支…'), findsNothing);
    expect(find.text('远程分支'), findsNothing);
    expect(find.text('拉取'), findsNothing);
    expect(find.text('推送'), findsNothing);
    expect(find.text('获取'), findsNothing);
    expect(find.byIcon(Icons.merge_type), findsNothing);
    // 10-02 已删：仓库主页 / 最近使用
    expect(find.text('仓库主页'), findsNothing);
    expect(find.text('最近使用'), findsNothing);
  });

  testWidgets('空目录：提示 + 仍可添加', (tester) async {
    await openSidebar(tester, onOpenRepo: (_) {}, reposOverride: const []);

    expect(find.textContaining('还没有仓库'), findsOneWidget);
    expect(find.text('＋ 添加仓库'), findsOneWidget);
  });

  testWidgets('添加仓库弹层：扫描 / 选择本地 / 添加远程 三入口', (tester) async {
    await openSidebar(tester, onOpenRepo: (_) {});

    await tester.tap(find.text('＋ 添加仓库'));
    await tester.pumpAndSettle();
    expect(find.text('扫描本地所有仓库'), findsOneWidget);
    expect(find.text('选择本地仓库'), findsOneWidget);
    expect(find.text('添加远程'), findsOneWidget);
  });

  // ---- orderedRepos 纯函数（拖动排序的排序规则）----

  test('orderedRepos：手排顺序优先，stale 条目丢弃，新仓库按发现顺序接尾', () {
    final out = orderedRepos(
      ['/a/gs', '/a/gd', '/a/new1', '/a/ai', '/a/new2'],
      ['/a/gd', '/a/gone', '/a/ai'], // gone 已不存在 → 丢弃
    );
    expect(out, ['/a/gd', '/a/ai', '/a/gs', '/a/new1', '/a/new2']);
  });

  test('orderedRepos：无手排记录时保持候选（发现）顺序', () {
    final out = orderedRepos(['/a/b', '/a/a'], []);
    expect(out, ['/a/b', '/a/a']);
  });

  test('orderedRepos：去重且忽略空白条目', () {
    final out = orderedRepos(['/a/x', ' /a/x ', '', '/a/y'], ['/a/x']);
    expect(out, ['/a/x', '/a/y']);
  });

  test('候选集稳定:打开未手排仓库不再把它顶到最前(scanCache 发现顺序优先)', () {
    // 模拟 _reload 的候选构造:[...scanned, ...recents, ?last, 当前仓库]。
    const scanned = ['/p/aaa', '/p/bbb'];
    final order = <String>[];
    // 打开 ccc 之前(recents 里 ccc 已出现过一次):
    final before = orderedRepos([
      ...scanned,
      '/p/ccc',
    ], order);
    // 打开 ccc 之后(当前仓库 + lastRepo + recents 全指向 ccc):
    final after = orderedRepos([
      ...scanned,
      '/p/ccc',
      '/p/ccc', // last
      '/p/ccc', // 当前仓库
    ], order);
    expect(after, before);
    expect(after.first, '/p/aaa'); // 顺序不被打开动作改变
  });
}
