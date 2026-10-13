import 'dart:isolate';

import 'package:flutter/material.dart';

import '../core/prefs.dart';
import '../core/platform_paths.dart';
import '../core/scan.dart';
import 'cloud_import.dart';
import 'dir_picker.dart';
import '../widgets/dialogs.dart';

/// 扫描本地标准目录（Projects / Documents / Download）并写入扫描缓存。
/// 返回发现的仓库列表；提示与后续动作由调用方决定（侧栏 / 空态页共用）。
Future<List<String>> scanLocalRepos() async {
  // roots 必须在主 isolate 解析（path_provider 平台通道限制），再传入。
  final roots = await PlatformPaths.scanRoots();
  final found = await Isolate.run(() => RepoScanner.scanAll(roots));
  await Prefs.instance.setScanCache(found);
  return found;
}

/// 满屏底部弹层：云端导入（GitHub / GitLab / Codeup），返回新仓库路径。
Future<String?> showCloudImport(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const CloudImportSheet(),
    );

/// 目录排序（纯函数，便于测试）：repoOrder 中仍存在的排前面（按用户
/// 手排顺序），其余（新扫描到 / 添加远程 / 最近打开）按发现顺序接尾。
/// stale 的排序条目（仓库已删）自然丢弃。
List<String> orderedRepos(Iterable<String> candidates, List<String> order) {
  final all = <String>[];
  for (final p in candidates) {
    final t = p.trim();
    if (t.isNotEmpty && !all.contains(t)) all.add(t);
  }
  final head = <String>[];
  for (final p in order) {
    if (all.remove(p)) head.add(p); // remove 返回是否存在于候选集
  }
  return [...head, ...all];
}

/// 仓库侧边栏（v1.4.4 目录化终稿；10-03 修订）。
///
/// 定稿结论（10-01 对话原文 + 10-02 追加）：
/// 「左侧栏最适合放仓库目录」「左侧只负责选仓库」；
/// 10-02 追加：去掉「最近使用」（目录应稳定，不该自己变）、去掉
/// 「仓库主页」入口（仓库主页页已整体删除，其信息工作台都有）、
/// 仓库列表支持长按拖动手动排序（持久化 repoOrder）。
/// 10-03 修订：头部 radar 直扫按钮移除（头部只留应用名+计数），
/// 扫描收进「＋ 添加仓库」弹层（扫描 / 选择本地 / 添加远程 三入口）。
///
/// 因此侧栏只做三件事：
/// 1. 仓库目录：平铺全部仓库，长按拖动排序，当前仓库高亮；
/// 2. ＋ 添加仓库：扫描本地所有仓库 / 选择本地仓库（目录浏览器） / 添加远程；
/// 3. 底部固定：应用设置。
///
/// 当前仓库的一切操作（分支、标签、Stash、远程、拉推同步）都在主工作区
/// 完成：工作台 Tab + 「更多」菜单 + 满高弹层。头部不再显示仓库信息。
class RepoSidebar extends StatefulWidget {
  final String repoPath;
  final int tick; // bumped by host on switch → refresh list
  final ValueChanged<String> onOpenRepo;
  final VoidCallback? onOpenSettings;

  /// 测试/预览注入：非 null 时跳过 Prefs 读取，直接渲染该列表。
  final List<String>? reposOverride;

  const RepoSidebar({
    super.key,
    required this.repoPath,
    this.tick = 0,
    required this.onOpenRepo,
    this.onOpenSettings,
    this.reposOverride,
  });

  @override
  State<RepoSidebar> createState() => _RepoSidebarState();
}

class _RepoSidebarState extends State<RepoSidebar> {
  List<String>? _repos;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant RepoSidebar old) {
    super.didUpdateWidget(old);
    if (old.tick != widget.tick || old.repoPath != widget.repoPath) _reload();
  }

  /// 候选集 = 扫描缓存 + 最近打开 + lastRepo + 当前仓库，去重后按用户
  /// 手排顺序（repoOrder）排列。
  /// 顺序权重只给扫描缓存（发现顺序）——目录必须稳定，不因打开仓库而
  /// 重排（10-02 设计结论「不该自己变」；实测反馈：未手排的仓库一打开
  /// 就被顶到列表最前，跳动感很强）。recents / last / 当前仓库只贡献
  /// 成员资格，不在 scanCache 中的排到新条目区尾部；想提前就长按拖动
  /// （拖动会持久化 repoOrder）。
  Future<void> _reload() async {
    final injected = widget.reposOverride;
    if (injected != null) {
      if (!mounted) return;
      setState(() => _repos = injected);
      return;
    }
    final last = await Prefs.instance.lastRepo();
    final recents = await Prefs.instance.recents();
    final scanned = await Prefs.instance.scanCache();
    final order = await Prefs.instance.repoOrder();
    final hidden = await Prefs.instance.hiddenRepos();
    final candidates = <String>[
      ...scanned,
      ...recents,
      ?last,
      if (widget.repoPath.isNotEmpty) widget.repoPath,
    ];
    if (!mounted) return;
    final visible = candidates.where(
      (p) => p == widget.repoPath || !hidden.contains(p),
    );
    setState(() => _repos = orderedRepos(visible, order));
  }

  /// 长按拖动结束：立即更新本地顺序并持久化（注入路径不写盘）。
  /// onReorderItem 的 newIndex 已由框架做过移位校正，直接插入即可。
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    final list = [...?_repos];
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex < 0 || newIndex > list.length) return;
    final p = list.removeAt(oldIndex);
    list.insert(newIndex, p);
    setState(() => _repos = list);
    if (widget.reposOverride != null) return;
    try {
      await Prefs.instance.setRepoOrder(list);
    } catch (e) {
      if (mounted) {
        showSnack(context, '仓库顺序保存失败：${friendlyError(e)}', error: true);
      }
    }
  }

  /// ＋ 添加仓库弹层（10-03 三入口）：扫描本地所有仓库 / 选择本地仓库
  /// （目录浏览器）/ 添加远程（账号导入或任意 URL 克隆）。
  /// 扫描就地执行并刷新列表；后两条导入成功后直接打开新仓库。
  Future<void> _addRepo() async {
    final what = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.radar_outlined),
              title: const Text('扫描本地所有仓库'),
              subtitle: const Text('自动发现 Projects / Documents / Download'),
              onTap: () => Navigator.pop(ctx, 'scan'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('选择本地仓库'),
              subtitle: const Text('浏览存储目录；普通文件夹可一键初始化为仓库'),
              onTap: () => Navigator.pop(ctx, 'browse'),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_sync_outlined),
              title: const Text('添加远程'),
              subtitle: const Text('克隆任意 URL，或从 GitHub / GitLab / Codeup 导入'),
              onTap: () => Navigator.pop(ctx, 'cloud'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || what == null) return;
    if (what == 'scan') {
      if (_scanning) return;
      setState(() => _scanning = true);
      try {
        final found = await scanLocalRepos();
        if (!mounted) return;
        await _reload();
        if (!mounted) return;
        showSnack(context, '扫描完成，发现 ${found.length} 个仓库');
      } catch (e) {
        if (mounted) showSnack(context, friendlyError(e), error: true);
      }
      if (mounted) setState(() => _scanning = false);
      return;
    }
    if (what == 'browse') {
      final path = await showDirPicker(context);
      if (path != null && path.isNotEmpty) widget.onOpenRepo(path);
      return;
    }
    final path = await showCloudImport(context);
    if (path != null && path.isNotEmpty) widget.onOpenRepo(path);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final repos = _repos;
    final count = repos?.length ?? 0;
    return SafeArea(
      // v1.4.4：抽屉内容包 SafeArea，修复顶部与系统状态栏重叠
      //（Drawer 自身不处理 insets）；底部同时避让手势条。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- 头部：应用名 + 仓库数（10-03：radar 直扫按钮移除，扫描收进
          // ＋添加仓库弹层；扫描进度走下方细进度条）----
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              children: [
                const SizedBox(width: 8),
                Icon(Icons.account_tree_outlined, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                const Text(
                  'AiwliGit',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Flexible(
                  // 10-03：包 Flexible+ellipsis——改名后头部变宽，窄容器
                  // （测试 / 小抽屉）会溢出 10px，此为硬化。
                  child: Text(
                    repos == null ? '仓库目录' : '仓库目录 · $count',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_scanning) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _listBody(repos)),
          // ---- 底部固定：全局入口（不属于任何仓库）----
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: Icon(Icons.add_link, size: 19, color: cs.primary),
            title: const Text(
              '＋ 添加仓库',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              '扫描 / 浏览本地，或添加远程仓库',
              style: TextStyle(fontSize: 9.5),
            ),
            onTap: _addRepo,
          ),
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: const Icon(Icons.settings_outlined, size: 18),
            title: const Text('应用设置', style: TextStyle(fontSize: 12.5)),
            onTap: widget.onOpenSettings,
          ),
        ],
      ),
    );
  }

  Widget _listBody(List<String>? repos) {
    if (repos == null) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (repos.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: Center(
          child: Text(
            '（还没有仓库，点下方「＋ 添加仓库」）',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: Colors.grey),
          ),
        ),
      );
    }
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: repos.length,
      onReorderItem: _onReorder,
      itemBuilder: (context, i) =>
          _repoTile(repos[i], index: i, key: ValueKey(repos[i])),
    );
  }

  Widget _repoTile(String path, {required int index, required Key key}) {
    final current = path == widget.repoPath;
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      key: key,
      dense: true,
      selected: current,
      leading: Icon(
        current ? Icons.folder_special : Icons.folder_outlined,
        size: 19,
        color: current ? cs.primary : null,
      ),
      title: Text(
        path.split('/').last,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: current ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 9.5, color: cs.onSurfaceVariant),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (current) Icon(Icons.check_circle, size: 16, color: cs.primary),
          PopupMenuButton<String>(
            tooltip: '仓库列表操作',
            padding: EdgeInsets.zero,
            iconSize: 18,
            onSelected: (value) async {
              if (value != 'hide' || path == widget.repoPath) return;
              final ok = await confirmDialog(
                context,
                '从列表移除？',
                '只会从 AiwliGit 列表隐藏「${path.split('/').last}」，不会删除磁盘文件。',
                action: '移除',
                danger: true,
              );
              if (!ok || !mounted) return;
              try {
                await Prefs.instance.hideRepo(path);
                await _reload();
              } catch (e) {
                if (mounted) showSnack(context, friendlyError(e), error: true);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'hide',
                enabled: path != widget.repoPath,
                child: const Text('从列表移除（不删文件）'),
              ),
            ],
          ),
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Icon(Icons.drag_handle, size: 18),
            ),
          ),
        ],
      ),
      // 当前仓库也允许点击：手机抽屉需要借此正常收起，宽屏则保持幂等。
      onTap: () => widget.onOpenRepo(path),
    );
  }
}
