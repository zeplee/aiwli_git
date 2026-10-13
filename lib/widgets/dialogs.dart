import 'package:flutter/material.dart';

/// Small reusable dialogs (text input / confirm / choice).

Future<String?> textDialog(
  BuildContext context,
  String title, {
  String initial = '',
  String hint = '',
  int maxLines = 1,
  String confirmLabel = '确定',
  bool obscureText = false,
}) async {
  final ctrl = TextEditingController(text: initial);
  try {
    return await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: obscureText ? 1 : maxLines,
          obscureText: obscureText,
          autocorrect: !obscureText,
          textInputAction: maxLines == 1
              ? TextInputAction.done
              : TextInputAction.newline,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  } finally {
    ctrl.dispose();
  }
}

Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String body, {
  String action = '确定',
  bool danger = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: Text(body, style: const TextStyle(fontSize: 13)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: Colors.red.shade700)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return r == true;
}

/// Reset mode chooser → returns 'soft' | 'mixed' | 'hard' | null.
Future<String?> resetModeDialog(BuildContext context, String commitLabel) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('重置到 $commitLabel', style: const TextStyle(fontSize: 16)),
      children: [
        _tile(ctx, 'soft', 'Soft — 仅移动分支指针，变更保留在暂存区', Icons.playlist_add_check),
        _tile(ctx, 'mixed', 'Mixed — 移动指针，变更保留在工作树（默认）', Icons.folder_open),
        _tile(
          ctx,
          'hard',
          'Hard — 彻底丢弃所有变更（危险）',
          Icons.delete_forever,
          danger: true,
        ),
      ],
    ),
  );
}

Widget _tile(
  BuildContext ctx,
  String value,
  String subtitle,
  IconData icon, {
  bool danger = false,
}) {
  return SimpleDialogOption(
    onPressed: () => Navigator.pop(ctx, value),
    child: ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20, color: danger ? Colors.red : null),
      title: Text(subtitle, style: const TextStyle(fontSize: 12.5)),
    ),
  );
}

/// 是否是「存储权限被系统拒绝」类错误。
///
/// 典型来源：更新安装后 MANAGE_EXTERNAL_STORAGE（所有文件访问）被系统重置，
/// 打开 /storage/emulated/0 下仓库的 .git 时 EACCES，git2 报
/// `Permission denied; class=Os (2); code=Locked (-14)`。
bool isStorageDeniedError(Object e) {
  final low = e.toString().toLowerCase();
  if (!low.contains('permission denied')) return false;
  return low.contains('/storage/') ||
      low.contains('/sdcard') ||
      low.contains('code=locked') ||
      low.contains('.git/');
}

/// 原始错误摘要。分类文案**不能**把真因吞掉 —— 排障时这一句往往就是全部
/// 线索（libgit2 的 `class=…; code=…`、OpenSSL 原因、SocketException 的 errno）。
String rawTail(String raw) {
  final one = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (one.isEmpty) return '';
  final s = one.length <= 240 ? one : '${one.substring(0, 240)}…';
  return '（原始：$s）';
}

/// Maps common engine errors to plain-language guidance with a next step.
/// Raw text is preserved for anything unrecognized.
String friendlyError(Object e) {
  final raw = e.toString().replaceFirst('Exception: ', '');
  // ⚠️ 分类只看**第一行**：引擎会在原始错误后面追加「提示：…」（Rust 侧
  // `transport_hint`），那段文案里含「网络安全」「证书校验失败」等字样 ——
  // 1.5.16 之前正是把整段拿去匹配，才把证书错误判成"网络连接失败"（docs/14）。
  // 用第一行做**结构化隔离**，比"把关键字列全"稳得多：不管提示里写了什么词，
  // 都不会再污染分类。
  final head = raw.split('\n').first;
  final low = head.toLowerCase();
  bool has(List<String> keys) => keys.any(low.contains);
  if (isStorageDeniedError(e)) {
    return '没有存储访问权限：系统设置 → 应用 → 所有文件访问 → 打开本应用的开关，'
        '然后回到这里重试（更新安装后这个权限可能被系统重置）。';
  }
  if (has(['没有设置上游', 'upstream'])) {
    return '这个分支还没有绑定远程分支：直接推送一次（会自动绑定上游），或在「远程与仓库设置」里配置。';
  }
  // 判定顺序（踩过 3 次，见 docs/14 / docs/15）：
  //   ① 先认**传输层特征** —— 因为 libgit2 / OpenSSL 会把"握手中被掐断"也报成
  //      `class=Ssl`，例如真机抓到的
  //        `push 失败: SSL error: unknown error; class=Ssl (16)`
  //        （OpenSSL `SSL_ERROR_SYSCALL` 拿不到 errno → "unknown error"）
  //        `failed to connect to github.com: Software caused connection abort; class=Os (2)`
  //      这些是链路问题，给"导 CA / 关校验"的处置是错的。
  //   ② 剩下的 `class=Ssl` / cert 字样才判证书（见下方网络分支之后）。
  if (has([
    'network',
    'connection',
    'reset by peer',
    'syscall failure',
    'unreachable',
    'timeout',
    // DNS 失败：libgit2 的真实串是 "failed to resolve address for <host>"
    // 且 class=Net(12)。只写 'resolve host' 会漏 —— 回归测试抓到的第三个
    // 漏网（见 docs/15）。这里的 'class=net' 是 libgit2 的硬信号，
    // 比英文子串可靠。
    'resolve address',
    'resolve host',
    'host lookup',
    'name or service not known',
    'class=net',
    // 传输层被掐断的几种真实包装（真机抓到，见 docs/15）：
    'unexpected eof',
    'connection abort',
    'ssl error: unknown error',
  ])) {
    // 「连接被重置」在真机上最常见的原因是链路/代理，而不是目的地不可达：
    // 开着**按应用分流**的 VPN 时，走了隧道的应用会被 RST，而没走隧道的
    // 直连反而是好的（本机实测：同一时刻 NP 直连 git 端点 401，本应用走
    // 隧道 Connection reset）。所以这里要给一条能直接照做的提示。
    final reset = has([
      'reset by peer',
      'syscall failure',
      'connection abort',
      'unexpected eof',
      'ssl error: unknown error',
    ]);
    return '网络连接失败：请检查网络后重试。'
        '${reset ? '「连接被重置」通常是链路或代理问题：若开着 VPN/代理分流，'
            '把本应用移出分流列表（走直连）或换个节点再试。' : ''}'
        '${rawTail(raw)}';
  }
  // ② 传输特征都不匹配，剩下的才是**证书**问题：`class=Ssl (16)` 且带 cert 字样。
  if (has(['class=ssl', 'certificate', '证书'])) {
    return 'HTTPS 证书校验失败：远程证书不被本机信任。'
        '自签或内网 CA 到「设置 → 网络安全」导入该 CA（校验保持开启，不必关校验）；'
        '也可把远程改成 SSH 绕开证书。${rawTail(raw)}';
  }
  // 推送未被远端接受 / 结果无法核对（1.5.23：push 只认服务端确认）。
  // 必须排在 auth 之前——下面的 auth 桶会吃掉含「权限」字样的消息。
  if (has(['推送未被接受', '无法确认推送结果'])) {
    return '推送未被接受：远端没有收到这次更新，本地提交仍在。'
        '常见原因：令牌只有只读权限（需写权限）、分支保护，或链路抖动。'
        '到「设置 → 代码托管账号」确认令牌权限后重试。${rawTail(raw)}';
  }
  if (has(['auth', '401', '403', 'credential', '权限'])) {
    return '远程认证失败：令牌可能已过期或没有权限，到「设置 → 代码托管账号」或「兼容同步凭据」更新。'
        '${rawTail(raw)}';
  }
  if (has(['non-fast-forward', 'notfastforward', 'rejected', 'cannot push'])) {
    return '推送被拒绝：远程有你本地没有的提交。先「拉取更新」再推送；确认要覆盖远程时才用「强制推送」。';
  }
  if (has(['push 失败'])) {
    // 非"真拒绝"的 push 失败保留原始错误，避免误导（如传输层问题）。
    return '推送失败：$raw';
  }
  if (has(['revspec'])) {
    // revspec 解析失败 ≠ 仓库不存在：多半是远程跟踪引用缺失（远程没有该分支，
    // 或引用被误清理）。2026-10-08 实测曾被误报成「找不到仓库或文件」。
    return '远程跟踪引用缺失（如 origin/main）：远程上可能没有该分支，或引用被误清理。'
        '先「拉取更新」确认远程分支存在，必要时重新绑定上游。${rawTail(raw)}';
  }
  // macOS TCC 拒绝访问时，libgit2 会把 EPERM/EACCES 吞进 "could not find
  // repository"，必须排在 not-found 桶之前，否则被误报成「找不到仓库」
  // （2026-10-14 macOS 实测：文件夹授权被拒后打开仓库即触发）。
  if (has([
    'permission denied',
    'operation not permitted',
    'eperm',
    'eacces',
  ])) {
    return '没有权限访问该路径：macOS 上是隐私授权拦截（弹窗被拒或未弹出）。'
        '到「系统设置 → 隐私与安全性 → 文件与文件夹」勾选 AiwliGit 的'
        '文稿/桌面/下载，或直接授予「完全磁盘访问权限」，重启应用后重试。'
        '${rawTail(raw)}';
  }
  if (has([
    'not a git',
    '不存在',
    'does not exist',
    'could not find',
    'not found',
    'no such',
  ])) {
    return '找不到仓库或文件：路径可能已变化，请刷新或重新选择仓库。';
  }
  return raw;
}

/// 去掉 [friendlyError] 追加的「（原始：…）」尾巴，只留人话。
///
/// 操作条的折叠态用它：人话负责「是什么问题、该怎么办」，原始错误放到
/// 「详情」里展开（且是**未截断**、可长按复制的完整串，见 `rawTail` 的 240
/// 字上限）。两者不重复展示。
String shortReason(String friendly) {
  final i = friendly.lastIndexOf('（原始');
  if (i <= 0) return friendly;
  final head = friendly.substring(0, i).trimRight();
  return head.isEmpty ? friendly : head;
}

void showSnack(BuildContext context, String msg, {bool error = false}) {
  final cs = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 12.5)),
        backgroundColor: error ? cs.error : cs.inverseSurface,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: error ? 4 : 2),
      ),
    );
}

/// 以满高底部弹层打开内容，替代推入二级页（v1.4.2 起的扁平化导航）：
/// 层级更浅、下拉手势即可关闭，且不遮挡工作台状态（返回即见最新结果）。
Future<T?> showFullSheet<T>(BuildContext context, Widget child) {
  final h = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => SizedBox(height: h * 0.93, child: child),
  );
}
