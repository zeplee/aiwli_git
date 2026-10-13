import 'package:flutter/material.dart';

import '../widgets/dialogs.dart';
import '../widgets/op_bar.dart';
import 'branches_page.dart';
import 'dir_picker.dart';
import 'github_panel.dart';
import 'history_page.dart';
import 'remotes_page.dart';
import 'repo_drawer.dart';
import 'stash_page.dart';
import 'sync_flow.dart';
import 'publish_remote.dart';
import 'workbench_page.dart';

/// 当前仓库页的宿主。
///
/// 布局（v1.4.3 侧边栏模型；v1.4.4 目录化 + 删除仓库主页页）：
/// - 宽屏（≥900dp）：左侧**常驻仓库侧边栏**（纯仓库目录：全部仓库
///   长按拖动排序 + ＋添加仓库 + 底部应用设置）+ 右侧工作区双栏；
/// - 手机：同一份侧边栏收进抽屉，AppBar 汉堡按钮打开，左缘 120dp 内左滑
///   也能拉出；内容包 SafeArea，不再与系统状态栏重叠。
///
/// 侧边栏只负责选仓库（点任意仓库直接切换到它的工作台）；当前仓库的
/// 分支/标签/Stash/远程/同步操作全部在主工作区（Tab + 「更多」菜单 +
/// 满高弹层）完成，头部不再显示仓库信息。
/// v1.4.4：仓库主页页（ReposPage）已删除——无仓库时由 _empty 空态
/// 直接提供「扫描本地 / 添加远程」两条动线。
class WorkbenchHost extends StatefulWidget {
  final String? repoPath;

  /// 从侧边栏仓库列表打开指定仓库（AppShell 切仓库并跳到工作台）；
  /// 空态页扫描/导入完成后也经此打开首个仓库。
  final ValueChanged<String>? onOpenRepo;

  /// 同步信息回调（备用：侧栏分支行与仓库卡片均已自带 ↑n↓n）。
  final void Function(String path, int ahead, int behind)? onSync;

  /// 打开设置页（AppShell 提供，保证主题回调一致）。
  final VoidCallback? onOpenSettings;

  const WorkbenchHost({
    super.key,
    required this.repoPath,
    this.onOpenRepo,
    this.onSync,
    this.onOpenSettings,
  });
  @override
  State<WorkbenchHost> createState() => _WorkbenchHostState();
}

class _WorkbenchHostState extends State<WorkbenchHost>
    with SingleTickerProviderStateMixin {
  TabController? _tabs;
  int _tick = 0; // bumped by children / actions → children reload themselves

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void didUpdateWidget(covariant WorkbenchHost old) {
    super.didUpdateWidget(old);
    if (widget.repoPath != old.repoPath) _mutated();
  }

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  void _mutated() {
    if (!mounted) return;
    setState(() => _tick++);
  }

  /// 满高底部弹层（v1.4.2 扁平化：不再推入二级页）；若抽屉开着先关掉。
  void _showSheet(Widget child) {
    // PopupMenu 已经在 onSelected 前自动关闭；这里不能用通用 pop，
    // 否则在根路由上会误退工作台。抽屉场景只由抽屉自己的回调负责关闭。
    showFullSheet(context, child);
  }

  @override
  Widget build(BuildContext context) {
    final repo = widget.repoPath;
    if (repo == null || repo.isEmpty) {
      return _empty(context);
    }
    // Keys stay stable across mutations (no state-teardown storm); children
    // observe `tick` in didUpdateWidget and reload themselves.
    final keySuffix = repo.hashCode.toString();
    final tabBar = TabBar(
      controller: _tabs,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      tabs: const [
        Tab(text: '改动'),
        Tab(text: '历史'),
        Tab(text: '分支'),
      ],
    );
    final tabView = TabBarView(
      controller: _tabs,
      children: [
        WorkbenchPage(
          key: ValueKey('wb$keySuffix'),
          repoPath: repo,
          tick: _tick,
          onSnapshot: (snap) =>
              widget.onSync?.call(repo, snap.ahead, snap.behind),
        ),
        HistoryPage(key: ValueKey('hi$keySuffix'), repoPath: repo, tick: _tick),
        BranchesPage(
          key: ValueKey('br$keySuffix'),
          repoPath: repo,
          tick: _tick,
          onMutated: _mutated,
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        Widget sidebar(
          VoidCallback? openSettings, {
          ValueChanged<String>? onOpenRepo,
        }) {
          return RepoSidebar(
            repoPath: repo,
            tick: _tick,
            onOpenRepo: onOpenRepo ?? (p) => widget.onOpenRepo?.call(p),
            onOpenSettings: openSettings,
          );
        }

        return Scaffold(
          // v1.4.2：加宽左缘手势区（默认仅 20dp 且被 TabBarView 抢手势，
          // 实际滑不出来只能点左上角）——左手拇指自然区 120dp 内左滑即拉出侧栏。
          drawerEdgeDragWidth: wide ? null : 120,
          drawer: wide
              ? null
              : Drawer(
                  width: 330,
                  child: sidebar(
                    () {
                      Navigator.of(context).pop(); // close drawer first
                      widget.onOpenSettings?.call();
                    },
                    onOpenRepo: (p) {
                      // 选完仓库先收起抽屉：否则新仓库在抽屉背后加载，
                      // 用户看着像“点了没反应”。
                      Navigator.of(context).pop();
                      widget.onOpenRepo?.call(p);
                    },
                  ),
                ),
          appBar: AppBar(
            leading: wide
                ? null
                : Builder(
                    builder: (ctx) => IconButton(
                      tooltip: '打开仓库侧栏',
                      icon: const Icon(Icons.menu),
                      onPressed: () => Scaffold.of(ctx).openDrawer(),
                    ),
                  ),
            titleSpacing: 12,
            title: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  repo.split('/').last.isEmpty ? '当前仓库' : repo.split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  repo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz, size: 22),
                tooltip: '更多操作',
                onSelected: (what) {
                  switch (what) {
                    case 'stashManage':
                      _showSheet(
                        StashSheet(
                          key: ValueKey('st$keySuffix'),
                          repoPath: repo,
                          onMutated: _mutated,
                        ),
                      );
                    case 'githubPanel':
                      _showSheet(
                        GithubSheet(
                          key: ValueKey('gh$keySuffix'),
                          repoPath: repo,
                        ),
                      );
                    case 'remoteSettings':
                      _showSheet(
                        RemotesSheet(
                          key: ValueKey('rm$keySuffix'),
                          repoPath: repo,
                          onMutated: _mutated,
                        ),
                      );
                    case 'appSettings':
                      widget.onOpenSettings?.call();
                    case 'publish':
                      showPublishSheet(context, repo);
                    default:
                      runSync(
                        context,
                        repoPath: repo,
                        what: what,
                        onChanged: _mutated,
                      );
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'pull',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.download, size: 18),
                      title: Text('拉取更新', style: TextStyle(fontSize: 13)),
                      subtitle: Text(
                        'Pull · 下载并合并远程提交',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'push',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.upload, size: 18),
                      title: Text('推送提交', style: TextStyle(fontSize: 13)),
                      subtitle: Text(
                        'Push · 上传本地提交到远程',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'fetch',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.cloud_download, size: 18),
                      title: Text('获取远程更新', style: TextStyle(fontSize: 13)),
                      subtitle: Text(
                        'Fetch · 仅下载，不改变当前文件',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'stash',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.inventory, size: 18),
                      title: Text('临时保存修改', style: TextStyle(fontSize: 13)),
                      subtitle: Text(
                        'Stash · 暂时收起未提交修改',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'stashManage',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.inventory_2_outlined, size: 18),
                      title: Text('临时保存管理', style: TextStyle(fontSize: 13)),
                      subtitle: Text(
                        'Stash 管理 · 查看和恢复临时保存',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'githubPanel',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.code, size: 18),
                      title: Text(
                        'GitHub 仓库面板',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        '在线浏览 Issue / PR / 发布(平台侧)',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'publish',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.cloud_upload_outlined, size: 18),
                      title: Text('发布 / 配置远程', style: TextStyle(fontSize: 13)),
                      subtitle: Text(
                        '创建或绑定远程仓库并推送当前分支',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'remoteSettings',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.cloud_outlined, size: 18),
                      title: Text('远程与仓库设置', style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'appSettings',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.settings_outlined, size: 18),
                      title: Text('设置', style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  // 危险操作沉底：强制推送放在菜单最末，用分隔线+红色降低误触。
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'forcePush',
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.warning_amber,
                        size: 18,
                        color: Colors.red,
                      ),
                      title: Text(
                        '强制推送（覆盖远程）',
                        style: TextStyle(fontSize: 13, color: Colors.red),
                      ),
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 22),
                tooltip: '刷新',
                onPressed: _mutated, // children reload on tick
              ),
            ],
            bottom: tabBar,
          ),
          body: Column(
            children: [
              // 操作条常驻在 TabBar 之下、内容之上：切 Tab 也在，所以操作
              // 进行状态与结果不会因为换页（或读屏慢一点）而丢失——原先
              // 一个操作的全部反馈就是 2~4 秒的 snackbar。
              const OperationBar(),
              Expanded(
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Material(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerLowest,
                            child: SizedBox(
                              width: 288,
                              child: sidebar(widget.onOpenSettings),
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: tabView),
                        ],
                      )
                    : tabView,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 空态（无仓库）：v1.4.4 起仓库主页页已删除，这里就是新用户的起点，
  /// 自带「扫描本地 / 添加远程」两条动线；扫描发现仓库则直接打开第一个。
  /// 10-03：空态同样挂仓库侧边栏（宽屏常驻 / 手机抽屉+汉堡）——侧栏必须
  /// 全局常驻，否则无仓库时侧栏底部的「应用设置」永远不可达（实测反馈）。
  bool _emptyScanning = false;

  Future<void> _scanHere() async {
    if (_emptyScanning) return;
    setState(() => _emptyScanning = true);
    try {
      final found = await scanLocalRepos();
      if (!mounted) return;
      if (found.isEmpty) {
        showSnack(context, '未发现 Git 仓库，可试试「添加远程」');
        return;
      }
      widget.onOpenRepo?.call(found.first);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
    if (mounted) setState(() => _emptyScanning = false);
  }

  Future<void> _cloudHere() async {
    final path = await showCloudImport(context);
    if (path != null && path.isNotEmpty) widget.onOpenRepo?.call(path);
  }

  Future<void> _browseHere() async {
    final path = await showDirPicker(context);
    if (path != null && path.isNotEmpty) widget.onOpenRepo?.call(path);
  }

  Widget _empty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 与开仓态同一套侧栏（repoPath 置空 = 无高亮；抽屉里点仓库后整个
    // Scaffold 被替换，抽屉随之消失，无需手动 pop）。
    Widget sidebar(VoidCallback? openSettings) => RepoSidebar(
      repoPath: '',
      onOpenRepo: (p) => widget.onOpenRepo?.call(p),
      onOpenSettings: openSettings,
    );
    Widget welcome(bool drawerHint) => Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_emptyScanning)
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(strokeWidth: 3),
            )
          else
            Icon(
              Icons.build_circle_outlined,
              size: 64,
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
            ),
          const SizedBox(height: 12),
          Text(
            '还没有打开的仓库',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _emptyScanning ? '正在扫描本地仓库…' : '扫描本地、选择文件夹或克隆远程仓库',
            style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _emptyScanning ? null : _scanHere,
                icon: const Icon(Icons.radar_outlined, size: 18),
                label: const Text('扫描本地仓库'),
              ),
              OutlinedButton.icon(
                onPressed: _browseHere,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text('选择本地仓库'),
              ),
              FilledButton.icon(
                onPressed: _cloudHere,
                icon: const Icon(Icons.cloud_sync_outlined, size: 18),
                label: const Text('添加远程'),
              ),
            ],
          ),
          if (drawerHint) ...[
            const SizedBox(height: 18),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.touch_app, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  '点左上角菜单打开仓库侧栏',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        return Scaffold(
          drawerEdgeDragWidth: wide ? null : 120,
          drawer: wide
              ? null
              : Drawer(
                  width: 330,
                  child: sidebar(() {
                    Navigator.of(context).pop(); // close drawer first
                    widget.onOpenSettings?.call();
                  }),
                ),
          appBar: AppBar(
            leading: wide
                ? null
                : Builder(
                    builder: (ctx) => IconButton(
                      tooltip: '打开仓库侧栏',
                      icon: const Icon(Icons.menu),
                      onPressed: () => Scaffold.of(ctx).openDrawer(),
                    ),
                  ),
            title: const Text('AiwliGit'),
          ),
          body: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Material(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerLowest,
                      child: SizedBox(
                        width: 288,
                        child: sidebar(widget.onOpenSettings),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: welcome(false)),
                  ],
                )
              : welcome(true),
        );
      },
    );
  }
}
