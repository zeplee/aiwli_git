import 'package:flutter/material.dart';

import '../core/sys_access.dart';
import '../core/prefs.dart';
import '../engine/ffi.dart' as engine;
import '../widgets/dialogs.dart';
import '../mcp/server.dart';
import '../pages/settings_page.dart';
import '../pages/workbench_host.dart';

/// App shell v1.4.4：仓库主页页（ReposPage）已删除，工作台即唯一主页。
///
/// - 冷启动：恢复了上次仓库则直入其工作台；没有仓库则落在工作台空态，
///   空态自带「扫描本地 / 添加远程」动线（不再需要独立仓库页）；
/// - 仓库切换：工作台侧边栏仓库目录（长按可拖动排序），左缘 120dp 内
///   左滑即拉出（宽屏常驻侧栏）；
/// - Stash / 远程设置：满高底部弹层；「管理分支…」：直接切到分支 tab；
/// - 设置：侧栏底部 / 工作台「更多」菜单。
class AppShell extends StatefulWidget {
  final String? initialRepo; // restored + validated by AiwlApp
  final ValueChanged<String> onThemeChanged; // 'system' | 'dark' | 'light'
  const AppShell({super.key, this.initialRepo, required this.onThemeChanged});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String? _repo; // 当前仓库（null = 未打开过，显示工作台空态）

  @override
  void initState() {
    super.initState();
    // Engine is fully attached here — safe point to auto-start the MCP server
    // (prefs now point at the stable files dir, set in AiwlApp._boot).
    McpServer.instance.startIfEnabled();
    _repo = widget.initialRepo;
    _checkStorageAccess();
  }

  /// 更新安装后 MANAGE_EXTERNAL_STORAGE（所有文件访问）常被系统重置，
  /// 此时读 /storage/emulated/0 下的仓库会全部 EACCES。启动即自检，
  /// 缺权限就引导去系统设置，避免用户只看到一串 git 底层报错。
  Future<void> _checkStorageAccess() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final state = await SysAccess.state();
    if (!mounted || state != 'denied') return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要存储访问权限', style: TextStyle(fontSize: 16)),
        content: const Text(
          '本应用要读写 /storage/emulated/0 下的仓库，需要「所有文件访问」权限。'
          '应用更新后这个权限有时会被系统重置。\n\n'
          '请在接下来的系统页面里打开本应用的开关，然后返回应用即可。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去开启'),
          ),
        ],
      ),
    );
    if (go == true) await SysAccess.openSettings();
  }

  Future<void> _openRepo(String path) async {
    if (path.trim().isEmpty || path == _repo) return;
    try {
      // 先验证，再切换并持久化，避免侧栏留下已失效路径或冷启动恢复失败。
      await engine.openRepo(path: path);
      await Prefs.instance.setLastRepo(path);
      if (!mounted) return;
      setState(() => _repo = path);
    } catch (e) {
      if (mounted) showSnack(context, friendlyError(e), error: true);
    }
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(onThemeChanged: widget.onThemeChanged),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WorkbenchHost(
      key: const ValueKey('host'),
      repoPath: _repo,
      onOpenRepo: _openRepo,
      onOpenSettings: _openSettings,
    );
  }
}
