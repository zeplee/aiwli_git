import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/hosting_api.dart';
import '../core/prefs.dart';
import '../core/url_util.dart';
import '../core/version.dart';
import '../engine/ffi.dart' as engine;
import '../mcp/server.dart';
import '../widgets/dialogs.dart';
import 'licenses_page.dart';
import 'web_login_page.dart';

/// 设置页：MCP 服务（开关/URL/令牌/端口）、同步凭据、外观、关于。
class SettingsPage extends StatefulWidget {
  final ValueChanged<String> onThemeChanged; // 'system' | 'dark' | 'light'
  const SettingsPage({super.key, required this.onThemeChanged});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _mcpOn = false;
  int _mcpPort = 8613;
  String _mcpToken = '';
  String _themeName = 'system'; // system | dark | light
  Map<String, Object?>? _cred;
  List<Map<String, Object?>> _accounts = [];
  String _version = '';
  bool _showMcpToken = false;
  bool _mcpBusy = false;
  /// TLS 证书校验逃生口。**默认 false（校验开启）**，见 docs/13。
  bool _skipTls = false;
  /// 信任库诊断文本（系统库路径 / 证书数 / bundle 路径）。
  String _tlsDetail = '';
  /// 已导入的自签 / 内网 CA（{id, label, count}）。
  List<Map<String, Object?>> _cas = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Future.wait([
      Prefs.instance.mcpEnabled(),
      Prefs.instance.mcpPort(),
      Prefs.instance.mcpToken(),
      Prefs.instance.themeModeName(),
      Prefs.instance.credentials(),
      Prefs.instance.accounts(),
      Prefs.instance.skipTlsVerify(),
    ]);
    if (!mounted) return;
    setState(() {
      _mcpOn = r[0] as bool;
      _mcpPort = r[1] as int;
      _mcpToken = r[2] as String;
      _themeName = r[3] as String;
      _cred = r[4] as Map<String, Object?>?;
      _accounts = (r[5] as List).cast<Map<String, Object?>>();
      _skipTls = r[6] as bool;
    });
    // best-effort version from platform
    _loadVersion();
    _loadTlsStatus();
    _loadCa();
  }

  Future<void> _loadCa() async {
    try {
      final r = await engine.caList();
      if (!mounted) return;
      setState(() {
        _cas = [
          for (final x in (r['items'] as List? ?? []))
            if (x is Map) Map<String, Object?>.from(x),
        ];
      });
    } catch (_) {}
  }

  /// 导入自签 / 内网 CA —— 校验保持开启的正解（对比：跳过校验是最后手段）。
  Future<void> _importCa() async {
    final labelCtl = TextEditingController();
    final pemCtl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入自签 / 内网 CA'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: labelCtl,
                  decoration: const InputDecoration(
                    labelText: '名称（便于识别）',
                    hintText: '例如：公司内网 CA',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: pemCtl,
                  maxLines: 7,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  decoration: const InputDecoration(
                    labelText: 'CA 证书（PEM）',
                    hintText:
                        '-----BEGIN CERTIFICATE-----\n…\n-----END CERTIFICATE-----',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '只把这段证书加进本机信任库，用于校验对应服务器；'
                  '不会关闭证书校验，也不影响其他仓库。导入后立即生效。',
                  style: TextStyle(fontSize: 11.5, height: 1.45),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    final label = labelCtl.text;
    final pem = pemCtl.text;
    labelCtl.dispose();
    pemCtl.dispose();
    if (go != true || pem.trim().isEmpty) return;
    try {
      final r = await engine.caImport(label: label, pem: pem);
      await _loadCa();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 ${r['imported'] ?? 1} 张证书，立即生效')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Future<void> _removeCa(Map<String, Object?> ca) async {
    final id = ca['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个 CA？'),
        content: Text(
          '「${ca['label']}」将从本机信任库移除。\n\n'
          '注意：删除后需要重启应用才完全生效 —— OpenSSL 的信任库只能加、不能减。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      await engine.caRemove(id);
      await _loadCa();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已删除（重启应用后彻底生效）')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
    }
  }

  /// 信任库诊断（best-effort：失败只显示"未加载"，不影响页面）。
  Future<void> _loadTlsStatus() async {
    try {
      final s = await engine.tlsStatus();
      if (!mounted) return;
      final ok = s['ok'] == true;
      final detail = (s['detail'] ?? '') as String;
      setState(() {
        _tlsDetail = ok ? detail : '未加载：${s['error'] ?? '未知原因'}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _tlsDetail = '未加载：$e');
    }
  }

  Future<void> _loadVersion() async {
    // version.dart is the single display constant (mirrors pubspec).
    if (mounted) setState(() => _version = appVersion);
  }

  Future<void> _toggleMcp(bool v) async {
    if (_mcpBusy) return;
    if (mounted) setState(() => _mcpBusy = true);
    try {
      if (v) {
        await McpServer.instance.start(_mcpPort, _mcpToken);
        if (!McpServer.instance.running) {
          throw StateError(McpServer.instance.error ?? 'MCP 服务启动失败');
        }
        await Prefs.instance.setMcpEnabled(true);
      } else {
        await McpServer.instance.stop();
        await Prefs.instance.setMcpEnabled(false);
      }
      if (mounted) setState(() => _mcpOn = v);
    } catch (e) {
      if (mounted) {
        showSnack(context, 'MCP 服务${v ? '启动' : '停止'}失败：$e', error: true);
      }
      if (mounted) setState(() => _mcpOn = McpServer.instance.running);
    } finally {
      if (mounted) setState(() => _mcpBusy = false);
    }
  }

  Future<void> _copyMcpConfig() async {
    final cfg = jsonEncode({
      'url': McpServer.instance.url,
      'transport': 'http',
      if (_mcpToken.isNotEmpty)
        'headers': {'Authorization': 'Bearer $_mcpToken'},
    });
    await Clipboard.setData(ClipboardData(text: cfg));
    if (mounted) showSnack(context, '已复制 MCP 连接配置');
  }

  Future<void> _editMcp() async {
    final portStr = await textDialog(context, 'MCP 端口', initial: '$_mcpPort');
    if (!mounted || portStr == null) return;
    final port = int.tryParse(portStr.trim());
    if (port == null || port < 1 || port > 65535) {
      if (mounted) showSnack(context, '端口必须是 1～65535 的数字', error: true);
      return;
    }
    final token = await textDialog(
      context,
      '访问令牌（留空则不校验）',
      initial: _mcpToken,
      obscureText: true,
    );
    if (!mounted || token == null) return;
    if (_mcpOn) {
      await McpServer.instance.start(port, token.trim());
      if (!McpServer.instance.running) {
        if (mounted) {
          showSnack(
            context,
            McpServer.instance.error ?? 'MCP 服务重启失败',
            error: true,
          );
        }
        return;
      }
    }
    try {
      await Prefs.instance.setMcpPort(port);
      await Prefs.instance.setMcpToken(token.trim());
    } catch (e) {
      if (mounted) {
        showSnack(context, 'MCP 配置保存失败：${friendlyError(e)}', error: true);
      }
      return;
    }
    if (mounted) {
      setState(() {
        _mcpPort = port;
        _mcpToken = token.trim();
        _showMcpToken = false;
      });
      showSnack(context, '已保存');
    }
  }

  Future<void> _editCredentials() async {
    final userCtrl = TextEditingController(
      text: (_cred?['user'] as String?) ?? '',
    );
    final passCtrl = TextEditingController(
      text: (_cred?['pass'] as String?) ?? '',
    );
    final ok = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('同步凭据', style: TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: userCtrl,
                decoration: const InputDecoration(labelText: '用户名（HTTPS）'),
                autocorrect: false,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passCtrl,
                decoration: const InputDecoration(
                  labelText: '访问令牌 / 密码',
                  helperText: 'GitHub/GitLab Personal Access Token；AES 加密后存储',
                  helperMaxLines: 2,
                ),
                obscureText: true,
                autocorrect: false,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'clear'),
            child: const Text('清除', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == null || ok == 'cancel') {
      userCtrl.dispose();
      passCtrl.dispose();
      return;
    }
    if (ok == 'clear') {
      await Prefs.instance.setCredentials(null);
      userCtrl.dispose();
      passCtrl.dispose();
      if (mounted) {
        setState(() => _cred = null);
        showSnack(context, '已清除凭据');
      }
      return;
    }
    // ok == 'save'
    final user = userCtrl.text.trim();
    final pass = passCtrl.text;
    if (user.isEmpty && pass.isEmpty) {
      await Prefs.instance.setCredentials(null);
      if (mounted) setState(() => _cred = null);
    } else {
      final m = <String, Object?>{
        if (user.isNotEmpty) 'user': user,
        if (pass.isNotEmpty) 'pass': pass,
      };
      await Prefs.instance.setCredentials(m);
      if (mounted) setState(() => _cred = m);
    }
    userCtrl.dispose();
    passCtrl.dispose();
    if (mounted) showSnack(context, '凭据已加密保存');
  }

  int _testingIndex = -1;

  /// 正在做权限自检的账号下标（v1.5.24），-1 = 空闲。
  int _scopesIndex = -1;

  /// 新增（index=-1）或编辑第 index 个托管账号。
  Future<void> _editAccount(int index) async {
    final existing = index >= 0 ? _accounts[index] : null;
    var provider = existing?['provider'] as String?;
    provider ??= await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('绑定代码托管平台', style: TextStyle(fontSize: 16)),
        children: [
          for (final e in [
            ('github', 'GitHub'),
            ('codeup', '云效 Codeup'),
            ('gitlab', 'GitLab'),
            ('generic', '其他 Git 服务器'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e.$1),
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  e.$1 == 'codeup'
                      ? Icons.cloud
                      : Icons.account_circle_outlined,
                  size: 20,
                ),
                title: Text(e.$2, style: const TextStyle(fontSize: 13)),
              ),
            ),
        ],
      ),
    );
    if (!mounted || provider == null) return;
    final labelCtrl = TextEditingController(
      text: (existing?['label'] as String?) ?? '',
    );
    final hostCtrl = TextEditingController(
      text: (existing?['host'] as String?) ?? (defaultHostFor(provider) ?? ''),
    );
    final orgCtrl = TextEditingController(
      text: (existing?['org'] as String?) ?? '',
    );
    final userCtrl = TextEditingController(
      text: (existing?['user'] as String?) ?? '',
    );
    final tokenCtrl = TextEditingController(
      text: (existing?['pass'] as String?) ?? '',
    );
    final keyCtrl = TextEditingController(
      text: (existing?['keyPath'] as String?) ?? '',
    );
    final phraseCtrl = TextEditingController(
      text: (existing?['passphrase'] as String?) ?? '',
    );
    var ok = false;
    try {
      ok =
          await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(
                index >= 0 ? '编辑账号' : '绑定 ${_providerName(provider!)}',
                style: const TextStyle(fontSize: 16),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 网页登录自动绑定（2026-10-04）：登录一次自动抓令牌/组织ID，
                    // 不再让用户手填下面这一堆字段；下方字段保留作核对与兜底。
                    if (provider == 'github' ||
                        provider == 'codeup' ||
                        provider == 'gitlab') ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(42),
                          ),
                          icon: const Icon(Icons.travel_explore, size: 18),
                          label: const Text('网页登录 · 自动填写（推荐）'),
                          onPressed: () => _webAutoFill(
                            provider!, // 闭包捕获可变量，需手动断言非空
                            labelCtrl: labelCtrl,
                            hostCtrl: hostCtrl,
                            orgCtrl: orgCtrl,
                            userCtrl: userCtrl,
                            tokenCtrl: tokenCtrl,
                          ),
                        ),
                      ),
                    ],
                    TextField(
                      controller: labelCtrl,
                      autofocus: false,
                      decoration: const InputDecoration(
                        labelText: '账号名称',
                        hintText: '个人账号 / 公司云效',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: hostCtrl,
                      decoration: InputDecoration(
                        labelText: '服务器地址',
                        helperText: provider == 'generic'
                            ? '自建 Git 服务的主机名'
                            : '留空使用官方地址',
                        isDense: true,
                      ),
                      autocorrect: false,
                    ),
                    if (provider == 'codeup' || provider == 'generic') ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: orgCtrl,
                        decoration: const InputDecoration(
                          labelText: '组织 / Organization ID（Codeup 需要）',
                          isDense: true,
                        ),
                        autocorrect: false,
                      ),
                    ],
                    const SizedBox(height: 10),
                    TextField(
                      controller: userCtrl,
                      decoration: const InputDecoration(
                        labelText: '用户名（HTTPS 可选）',
                        isDense: true,
                      ),
                      autocorrect: false,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: tokenCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '访问令牌 / 密码',
                        helperText: 'Personal Access Token；AES 加密后仅存本机',
                        isDense: true,
                      ),
                      autocorrect: false,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: keyCtrl,
                      decoration: const InputDecoration(
                        labelText: 'SSH 私钥路径（可选）',
                        hintText: '/sdcard/keys/id_ed25519',
                        isDense: true,
                      ),
                      autocorrect: false,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: phraseCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '私钥口令（可选）',
                        isDense: true,
                      ),
                      autocorrect: false,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存'),
                ),
              ],
            ),
          ) ==
          true;
      if (!ok) return;
      final entry = <String, Object?>{
        'provider': provider,
        if (labelCtrl.text.trim().isNotEmpty) 'label': labelCtrl.text.trim(),
        if (hostCtrl.text.trim().isNotEmpty) 'host': hostCtrl.text.trim(),
        if (orgCtrl.text.trim().isNotEmpty) 'org': orgCtrl.text.trim(),
        if (userCtrl.text.trim().isNotEmpty) 'user': userCtrl.text.trim(),
        if (tokenCtrl.text.isNotEmpty) 'pass': tokenCtrl.text,
        if (keyCtrl.text.trim().isNotEmpty) 'keyPath': keyCtrl.text.trim(),
        if (phraseCtrl.text.isNotEmpty) 'passphrase': phraseCtrl.text,
      };
      final list = [..._accounts];
      if (index >= 0) {
        list[index] = entry;
      } else {
        list.add(entry);
      }
      await Prefs.instance.setAccounts(list);
      if (mounted) {
        setState(() => _accounts = list);
        showSnack(context, '已保存（凭据已加密）');
      }
    } finally {
      labelCtrl.dispose();
      hostCtrl.dispose();
      orgCtrl.dispose();
      userCtrl.dispose();
      tokenCtrl.dispose();
      keyCtrl.dispose();
      phraseCtrl.dispose();
    }
  }

  /// 连接测试：用账号令牌请求平台的身份接口。
  Future<void> _testAccount(int index) async {
    final a = _accounts[index];
    setState(() => _testingIndex = index);
    try {
      final who = await testConnection(a);
      if (mounted) {
        showSnack(context, '连接成功：$who（${_providerName(accountProvider(a))}）');
      }
    } catch (e) {
      if (mounted) showSnack(context, '连接失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _testingIndex = -1);
    }
  }

  /// 网页登录自动绑定（2026-10-04）：内嵌 WebView 登录后自动抓令牌/组织 ID，
  /// 直接填进表单，用户核对后点保存；身份识别失败不阻塞（字段仍可手补）。
  Future<void> _webAutoFill(
    String provider, {
    required TextEditingController labelCtrl,
    required TextEditingController hostCtrl,
    required TextEditingController orgCtrl,
    required TextEditingController userCtrl,
    required TextEditingController tokenCtrl,
  }) async {
    final res = await showWebLogin(
      context,
      provider: provider,
      host: hostCtrl.text.trim(),
    );
    if (res == null || !mounted) return;
    tokenCtrl.text = res.token;
    final org = (res.org ?? '').trim();
    if (org.isNotEmpty && orgCtrl.text.trim().isEmpty) orgCtrl.text = org;
    try {
      final who = await testConnection({
        'provider': provider,
        'pass': res.token,
        if (hostCtrl.text.trim().isNotEmpty) 'host': hostCtrl.text.trim(),
        if (org.isNotEmpty) 'org': org,
      });
      if (userCtrl.text.trim().isEmpty) userCtrl.text = who;
      if (labelCtrl.text.trim().isEmpty) labelCtrl.text = who;
      if (mounted) showSnack(context, '自动填写完成：$who（核对后点「保存」）');
    } catch (_) {
      if (mounted) showSnack(context, '令牌已填入；身份识别失败，可稍后用「测试连接」验证');
    }
  }

  /// 用系统浏览器打开外链（走 App 已有的 gitdeck/sys 通道，无新依赖）。
  Future<void> _openExternal(Uri uri) async {
    const ch = MethodChannel('gitdeck/sys');
    try {
      await ch.invokeMethod('openUrl', {'url': uri.toString()});
    } catch (_) {
      if (mounted) showSnack(context, '打不开浏览器，请手动访问：$uri');
    }
  }

  /// GitHub OAuth 设备码登录（需要用户自己的 OAuth App client_id）。
  ///
  /// v1.5.24 起：「去哪建、勾什么」都做进 App ——
  /// - 登录申请的 scope 已含 `workflow`（[ghOauthScopes]），用户不用再自己
  ///   去设置页勾复选框；这一步正是旧版推送失败的根因。
  /// - 没配过 client_id 时给两条路：建 OAuth App（一键跳转）或用**预勾选好的
  ///   令牌页**（点开就已勾好 repo + workflow）。
  Future<void> _githubOauth() async {
    var clientId = (await Prefs.instance.githubClientId()) ?? '';
    if (clientId.isEmpty) {
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('选一种授权方式', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 330,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '方式 A · App 内一键登录（推荐）',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  '建一次自己的 OAuth App 拿 client_id。之后登录只需：App 内点按钮 → 浏览器确认。'
                  '权限由 App 声明（含 workflow），以后永不需要再到设置页勾复选框。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 14),
                const Text(
                  '方式 B · 用预勾选令牌页（不想建 App 就走这条）',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  '点开即为已勾好 repo + workflow 的页面，点 Generate → 复制 → 粘贴到「访问令牌」。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'b'),
              child: const Text('用令牌页'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'a'),
              child: const Text('建 OAuth App'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'b') {
        await _openExternal(ghNewTokenUri());
        if (mounted) {
          showSnack(
            context,
            '在页面底部点 Generate token（repo + workflow 已勾好），复制后粘贴到「访问令牌」并保存',
          );
        }
        return;
      }
      await _openExternal(ghNewOauthAppUri());
      if (!mounted) return;
      showSnack(
        context,
        '只勾「Enable Device Flow」，名字随便填；建好后复制 Client ID 回到这里',
      );
      final entered = await textDialog(
        context,
        'GitHub OAuth Client ID',
        hint: '形如 Ov23li… / Iv1.…：github.com/settings/developers → 你的 OAuth App',
        confirmLabel: '下一步',
      );
      if (entered == null || entered.trim().isEmpty) return;
      clientId = entered.trim();
      await Prefs.instance.setGithubClientId(clientId);
    }
    if (!mounted) return;
    final token = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeviceFlowDialog(clientId: clientId),
    );
    if (token == null || !mounted) return;
    var label = 'GitHub 账号';
    try {
      label = await testConnection({'provider': 'github', 'pass': token});
    } catch (_) {}
    final list = [..._accounts];
    final i = list.indexWhere((a) => accountProvider(a) == 'github');
    final entry = <String, Object?>{
      'provider': 'github',
      'label': label,
      'host': 'github.com',
      'pass': token,
    };
    if (i >= 0) {
      list[i] = entry;
    } else {
      list.add(entry);
    }
    try {
      await Prefs.instance.setAccounts(list);
    } catch (e) {
      if (mounted) {
        showSnack(context, '账号保存失败：${friendlyError(e)}', error: true);
      }
      return;
    }
    if (mounted) {
      setState(() => _accounts = list);
      showSnack(context, 'GitHub 登录成功：$label');
    }
    // 登录后立刻核一次权限：本次申请应当带上 workflow（ghOauthScopes）。
    // 若你的 OAuth App 是被 GitHub 拒绝该 scope、或用的是别的授权路径，
    // 这里会当场告诉你，而不是等你推 30 秒后才失败。
    try {
      final info = await ghTokenInfo(token);
      final can = info.canPushWorkflow;
      if (mounted && can == false) {
        showSnack(
          context,
          '注意：该令牌没有 workflow 权限，推送含 .github/workflows/ 的提交会被拒绝',
          error: true,
        );
      }
    } catch (_) {
      // 自检失败不影响登录结果，静默即可（用户可随时点「权限」手动复查）。
    }
  }

  /// 问一次 GitHub：这个令牌有哪些 scope（v1.5.24）。
  ///
  /// 把「推 30 秒后才失败」变成「点之前就知道」：令牌缺 workflow 时，推送
  /// 含 `.github/workflows/` 的提交**必然**被服务端拒绝（实测原文见
  /// docs/17）。这里读的是 GitHub 在 `X-OAuth-Scopes` 响应头里回显的真实
  /// 权限，不是 App 的猜测。
  Future<void> _checkScopes(int index) async {
    final a = _accounts[index];
    if (accountProvider(a) != 'github') {
      showSnack(context, '权限自检目前仅支持 GitHub');
      return;
    }
    final token = accountToken(a);
    if (token == null || token.isEmpty) {
      showSnack(context, '该账号没有访问令牌（SSH 方式无需 scope 检查）');
      return;
    }
    setState(() => _scopesIndex = index);
    GhTokenInfo? info;
    Object? err;
    try {
      info = await ghTokenInfo(token);
    } catch (e) {
      err = e;
    }
    if (!mounted) return;
    setState(() => _scopesIndex = -1);
    if (info == null) {
      showSnack(
        context,
        '权限读取失败：${err == null ? '未知错误' : friendlyError(err)}',
        error: true,
      );
      return;
    }
    final can = info.canPushWorkflow;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('令牌权限', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 330,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '账号：${info!.login.isEmpty ? accountLabel(a) : info.login}',
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 6),
              SelectableText(
                'scope：${info.scopeText}',
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 10),
              Text(
                switch (can) {
                  true =>
                    '含 workflow 权限：可以推送含 .github/workflows/ 的提交。',
                  false =>
                    '缺 workflow 权限：推送含 .github/workflows/ 的提交会被 GitHub 拒绝。'
                        '（旧版会把它显示成「推送成功」，1.5.23 起会如实报错。）',
                  null =>
                    '无法自动判定：细粒度令牌与 GitHub App 令牌不返回 scope。'
                        '若推送时报「without workflow scope」，用下面的按钮换一个令牌即可。',
                },
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          if (can != true) ...[
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _openExternal(ghNewTokenUri());
              },
              child: const Text('预勾选令牌页'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _githubOauth();
              },
              child: const Text('App 内重新登录'),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _providerName(String provider) => switch (provider) {
    'github' => 'GitHub',
    'codeup' => '云效 Codeup',
    'gitlab' => 'GitLab',
    _ => '其他 Git 服务器',
  };

  Future<void> _removeAccount(int index) async {
    final a = _accounts[index];
    final ok = await confirmDialog(
      context,
      '移除绑定',
      '移除“${a['label'] ?? ''}”？不会删除仓库远程地址。',
      action: '移除',
      danger: true,
    );
    if (!ok) return;
    final next = [..._accounts]..removeAt(index);
    try {
      await Prefs.instance.setAccounts(next);
    } catch (e) {
      if (mounted) {
        showSnack(context, '账号移除失败：${friendlyError(e)}', error: true);
      }
      return;
    }
    if (mounted) setState(() => _accounts = next);
  }

  Widget _accountsCard() {
    final cs = Theme.of(context).colorScheme;
    return _section(
      icon: Icons.account_balance_outlined,
      title: '代码托管账号',
      subtitle: _accounts.isEmpty ? '未绑定' : '${_accounts.length} 个账号',
      children: [
        Text(
          '绑定后可快速为 GitHub、云效 Codeup、GitLab 等 HTTPS 远程提供凭据，'
          '并支持「仓库 → 添加远程」直接拉取账号名下的仓库列表。'
          'GitHub / 云效绑定推荐点「网页登录 · 自动填写」，登录一次即可，令牌、'
          '组织 ID、用户名全自动抓取。同步仍以仓库远程 URL 为准。点账号可编辑。',
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        for (var i = 0; i < _accounts.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              _accounts[i]['provider'] == 'codeup'
                  ? Icons.cloud
                  : Icons.account_circle_outlined,
              size: 20,
            ),
            title: Text(
              '${_accounts[i]['label']}',
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              '${_providerName('${_accounts[i]['provider']}')} · '
              '${_accounts[i]['host'] ?? '官方地址'}'
              '${_accounts[i]['org'] != null ? ' · org ${_accounts[i]['org']}' : ''}'
              '${_accounts[i]['keyPath'] != null ? ' · SSH' : ''}',
              style: const TextStyle(fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: _testingIndex == i
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_scopesIndex == i)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else if (accountProvider(_accounts[i]) == 'github' &&
                          accountToken(_accounts[i]) != null)
                        IconButton(
                          tooltip: '令牌权限自检（workflow 等）',
                          icon: const Icon(Icons.verified_user_outlined, size: 19),
                          onPressed: () => _checkScopes(i),
                        ),
                      IconButton(
                        tooltip: '测试连接',
                        icon: Icon(Icons.wifi_tethering, size: 19),
                        onPressed: () => _testAccount(i),
                      ),
                      IconButton(
                        tooltip: '编辑',
                        icon: Icon(Icons.edit_outlined, size: 18),
                        onPressed: () => _editAccount(i),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.delete_outline,
                          color: cs.error,
                          size: 19,
                        ),
                        onPressed: () => _removeAccount(i),
                      ),
                    ],
                  ),
            onTap: () => _editAccount(i),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 0,
          children: [
            TextButton.icon(
              onPressed: () => _editAccount(-1),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('绑定账号', style: TextStyle(fontSize: 12)),
            ),
            TextButton.icon(
              onPressed: _githubOauth,
              icon: const Icon(Icons.key_rounded, size: 17),
              label: const Text(
                'GitHub OAuth 登录（设备码）',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _setTheme(String name) async {
    await Prefs.instance.setThemeModeName(name);
    if (!mounted) return;
    setState(() => _themeName = name);
    widget.onThemeChanged(name); // live-apply
  }

  Widget _mcpCard() {
    final srv = McpServer.instance;
    final cs = Theme.of(context).colorScheme;
    return _section(
      icon: Icons.hub_outlined,
      title: 'MCP 服务',
      trailing: _mcpBusy
          ? const SizedBox(
              width: 32,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Switch(value: _mcpOn, onChanged: (v) => _toggleMcp(v)),
      children: [
        Text(
          '让支持 MCP 的 AI 工具连接后直接调用 Git 能力。仅监听本机 (127.0.0.1)。',
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        if (_mcpOn) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  srv.url,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _mcpToken.isEmpty
                            ? '令牌：未设置（仅建议在可信本机环境使用）'
                            : '令牌：${_showMcpToken ? _mcpToken : '••••••••'}',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_mcpToken.isNotEmpty)
                      IconButton(
                        tooltip: _showMcpToken ? '隐藏令牌' : '显示令牌',
                        icon: Icon(
                          _showMcpToken
                              ? Icons.visibility_off
                              : Icons.visibility,
                          size: 17,
                        ),
                        onPressed: () =>
                            setState(() => _showMcpToken = !_showMcpToken),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (srv.error != null) ...[
            const SizedBox(height: 6),
            Text(srv.error!, style: TextStyle(color: cs.error, fontSize: 11)),
          ],
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 0,
            children: [
              TextButton.icon(
                onPressed: _copyMcpConfig,
                icon: const Icon(Icons.copy, size: 15),
                label: const Text('复制连接配置', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: _editMcp,
                child: const Text('端口 / 令牌', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _credCard() {
    final cs = Theme.of(context).colorScheme;
    final has =
        _cred != null && (_cred!['pass'] != null || _cred!['user'] != null);
    return _section(
      icon: Icons.key_outlined,
      title: '兼容同步凭据',
      subtitle: has ? '已保存（AES 加密）' : '未设置',
      onTap: _editCredentials,
      children: [
        Text(
          has
              ? '用于 HTTPS 拉取 / 推送 / 克隆私有仓库。密文通过 Android Keystore 加密存储。'
              : '设置后可用于 HTTPS 拉取 / 推送 / 克隆私有仓库（Personal Access Token）。',
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurfaceVariant,
            height: 1.45,
          ),
        ),
      ],
    );
  }

  Widget _themeCard() {
    final cs = Theme.of(context).colorScheme;
    return _section(
      icon: Icons.palette_outlined,
      title: '外观',
      subtitle: switch (_themeName) {
        'dark' => '深色',
        'light' => '浅色',
        _ => '跟随系统',
      },
      onTap: () async {
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('主题', style: TextStyle(fontSize: 16)),
            children: [
              for (final e in [
                ('system', '跟随系统', Icons.brightness_auto_outlined),
                ('dark', '深色', Icons.dark_mode_outlined),
                ('light', '浅色', Icons.light_mode_outlined),
              ])
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, e.$1),
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      e.$3,
                      size: 20,
                      color: _themeName == e.$1 ? cs.primary : null,
                    ),
                    title: Text(e.$2, style: const TextStyle(fontSize: 13)),
                    trailing: _themeName == e.$1
                        ? Icon(Icons.check, size: 18, color: cs.primary)
                        : null,
                  ),
                ),
            ],
          ),
        );
        if (choice != null) await _setTheme(choice);
      },
      children: [
        Text(
          '深浅色跟随系统或手动固定；Android 12+ 会按壁纸自动取色（Material You）。',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _netCard() {
    final cs = Theme.of(context).colorScheme;
    return _section(
      icon: Icons.shield_outlined,
      title: '网络安全',
      subtitle: _skipTls ? '证书校验已关闭' : '证书校验已开启',
      children: [
        Text(
          'HTTPS 远程默认校验证书，信任库取自 Android 系统 CA（启动时自动加载），'
          'GitHub 这类正规证书的仓库开箱即用，无需任何配置。',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.5),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          value: _skipTls,
          onChanged: _toggleSkipTls,
          title: const Text('跳过 TLS 证书校验', style: TextStyle(fontSize: 13.5)),
          subtitle: Text(
            _skipTls
                ? '⚠️ 已关闭校验 —— 中间人可冒充服务器，请尽快关掉。'
                : '仅用于自签证书仓库，或代理做了 TLS 拦截时临时打开。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.45,
              color: _skipTls ? cs.error : cs.onSurfaceVariant,
            ),
          ),
        ),
        if (_skipTls)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '风险：不校验证书时，网络路径上的攻击者（公共 WiFi、被劫持的 VPN 或代理）'
              '可以冒充 GitHub 等服务器，你的代码和访问令牌可能被窃取，'
              '而且推送 / 拉取会「看起来成功」。能用 SSH 就优先改用 SSH。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: cs.onErrorContainer,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          '信任库状态：$_tlsDetail',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, height: 1.4),
        ),
        const Divider(height: 22),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '自签 / 内网 CA',
                    style: TextStyle(fontSize: 13.5),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _cas.isEmpty
                        ? '未导入。自签证书的仓库在这里导入它的 CA —— 导入后仍然校验证书。'
                        : '已导入 ${_cas.length} 个，证书校验仍然开启。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _importCa,
              child: const Text('导入', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
        for (final c in _cas)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.verified_user_outlined,
              size: 18,
              color: cs.primary,
            ),
            title: Text(
              c['label']?.toString() ?? '',
              style: const TextStyle(fontSize: 12.5),
            ),
            subtitle: Text(
              '${c['count'] ?? 0} 张证书',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: '删除',
              onPressed: () => _removeCa(c),
            ),
          ),
        Text(
          '导入的 CA 与系统 CA 合并成一个信任库文件，供校验使用。'
          '删除后需重启应用才彻底生效（OpenSSL 的信任库只能加、不能减）。',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, height: 1.4),
        ),
      ],
    );
  }

  /// 切换逃生口。开启前必须显式确认 —— 这是一次信任降级，且失败是静默的。
  Future<void> _toggleSkipTls(bool value) async {
    if (value) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('关闭证书校验？'),
          content: const Text(
            '关闭后 AiwliGit 不再核对服务器身份。\n\n'
            '公共 WiFi、被劫持的 VPN 或代理上的攻击者可以冒充 GitHub，'
            '你的代码和访问令牌可能被窃取 —— 而且推送会显示成功。\n\n'
            '仅在你确知原因（例如该仓库使用自签证书）且网络环境可信时开启。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('我已知晓，仍然关闭'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await Prefs.instance.setSkipTlsVerify(value);
    try {
      await engine.setSkipTlsVerify(value);
    } catch (_) {
      // 引擎不可用时开关也照常存盘：下次启动 _boot() 会重新应用
    }
    if (!mounted) return;
    setState(() => _skipTls = value);
  }

  Widget _aboutCard() {
    final cs = Theme.of(context).colorScheme;
    return _section(
      icon: Icons.info_outline,
      title: '关于',
      subtitle: 'AiwliGit $_version',
      children: [
        Text(
          '本地 Git 仓库管理器：工作台（暂存 / 提交 / Diff）、历史、分支、Stash 与远程同步。'
          'git 引擎为 libgit2（Rust FFI），所有数据只保存在本机。',
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.gavel_outlined),
          title: const Text('开源许可'),
          subtitle: const Text('GPL-3.0-or-later · 第三方组件声明'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => const LicensesPage()),
          ),
        ),
      ],
    );
  }

  Widget _section({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
    required List<Widget> children,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: cs.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: [
          _mcpCard(),
          _credCard(),
          _accountsCard(),
          _netCard(),
          _themeCard(),
          _aboutCard(),
        ],
      ),
    );
  }
}

// ==================== GitHub OAuth device-flow dialog ====================

class _DeviceFlowDialog extends StatefulWidget {
  final String clientId;
  const _DeviceFlowDialog({required this.clientId});
  @override
  State<_DeviceFlowDialog> createState() => _DeviceFlowDialogState();
}

class _DeviceFlowDialogState extends State<_DeviceFlowDialog> {
  DeviceCode? _dc;
  String? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final dc = await startDeviceFlow(widget.clientId);
      if (!mounted) return;
      setState(() => _dc = dc);
      final token = await awaitDeviceFlow(widget.clientId, dc);
      if (!mounted) return;
      Navigator.pop(context, token);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _openPage() async {
    const ch = MethodChannel('gitdeck/sys');
    try {
      await ch.invokeMethod('openUrl', {
        'url': _dc?.verificationUri ?? 'https://github.com/login/device',
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('GitHub 登录', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 320,
        child: _dc == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(fontSize: 12.5, color: cs.error),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(onPressed: _run, child: const Text('重试')),
                  ] else
                    const Padding(
                      padding: EdgeInsets.all(18),
                      child: CircularProgressIndicator(),
                    ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '1. 打开授权页面（自动跳转或手动访问）：',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  SelectableText(
                    _dc!.verificationUri,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '2. 输入以下设备码并授权：',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          _dc!.userCode,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                            color: cs.primary,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '复制设备码',
                        icon: Icon(
                          _copied ? Icons.check : Icons.copy,
                          size: 18,
                        ),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: _dc!.userCode),
                          );
                          if (mounted) setState(() => _copied = true);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const LinearProgressIndicator(minHeight: 2),
                  const SizedBox(height: 6),
                  Text(
                    '等待你在浏览器里完成授权…',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
      ),
      actions: [
        if (_dc != null)
          FilledButton.icon(
            onPressed: _openPage,
            icon: const Icon(Icons.open_in_browser, size: 17),
            label: const Text('打开授权页面'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
