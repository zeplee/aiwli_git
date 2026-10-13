/// 网页登录自动绑定（2026-10-04，v2 免复制）。
///
/// 动机：账号绑定表单字段太多（令牌/组织ID/用户名…），用户不知道怎么填。
/// 这里把「填表」变成「登录一次」：
///   GitHub → 内嵌页直接打开预填 scopes 的新建令牌页，自动点 Generate，
///            JS 正则抓 ghp_ / github_pat_ 令牌，全程无需手填；
///   云效 Codeup → 登录后从 URL 自动抓组织 ID，跳「个人访问令牌」页；
///            创建令牌后免复制：页面文本自动扫描令牌 + 剪贴板 API 钩子
///            （用户点「复制」的瞬间 App 直接拿到值，无需回 App 点按钮）；
///   GitLab → 官方令牌页 + 同款钩子兜底。
///
/// 免复制原理（三层，全部幂等、失败静默降级）：
///   L1 页面文本扫描：令牌值以明文出现在「仅显示一次」弹窗里 → 正则抓取；
///   L2 剪贴板钩子：monkey-patch navigator.clipboard.writeText + copy 事件
///      捕获，网页里点「复制」的瞬间经 JSChannel 回传；
///   L3 底部按钮：读剪贴板兜底（App 有焦点时才读，不主动偷看）。
///
/// 纯函数（extractGithubToken / extractAliyunOrg / plausibleToken）可单测。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 网页登录抓到的结果。[token] 必有；[org] 仅云效有（组织 ID）。
class WebLoginResult {
  final String token;
  final String? org;
  const WebLoginResult(this.token, {this.org});
}

// ============================ 纯函数 ============================

/// 从页面文本抓 GitHub 令牌（经典 ghp_ 36 位 / 细粒度 github_pat_）。
String? extractGithubToken(String pageText) {
  final m = RegExp(
    r'ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{60,}',
  ).firstMatch(pageText);
  return m?.group(0);
}

/// 从云效 URL 抓组织 ID：devops.aliyun.com/{orgId}/… 或 codeup.aliyun.com/{orgId}/…
/// 组织 ID 是纯数字路径段（≥5 位）；仅在 *.aliyun.com 上调用。
String? extractAliyunOrg(String url) {
  if (!url.contains('.aliyun.com')) return null;
  final m = RegExp(
    r'https?://(?:devops|codeup)\.aliyun\.com/(\d{5,})(?:/|\?|$)',
  ).firstMatch(url);
  return m?.group(1);
}

/// 剪贴板/拦截值兜底：像不像一个令牌（非 URL、无空白、够长）。
/// [minLen] 供不同来源收紧：网页拦截值 ≥16，手动粘贴 ≥8。
bool plausibleToken(String? clip, {int minLen = 8}) {
  if (clip == null) return false;
  final t = clip.trim();
  if (t.length < minLen || t.length > 256) return false;
  if (RegExp(r'\s').hasMatch(t)) return false;
  if (t.startsWith('http')) return false;
  return true;
}

// ============================ JS 注入片段 ============================

/// L2 剪贴板钩子：网页点「复制」的瞬间回传值（幂等，全平台通用）。
const _clipHookJs = '''
(function(){
  if (window.__aiwliClipHook) return; window.__aiwliClipHook = true;
  var post = function(s){
    try {
      if (!s) return; s = String(s);
      if (s.length < 8 || s.length > 256) return;
      if (/\\s/.test(s)) return;
      if (/^https?:/i.test(s)) return;
      AiCapture.postMessage(s);
    } catch(e){}
  };
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      var orig = navigator.clipboard.writeText.bind(navigator.clipboard);
      navigator.clipboard.writeText = function(t){ post(t); return orig(t); };
    }
  } catch(e){}
  document.addEventListener('copy', function(e){
    try { post(e.clipboardData ? e.clipboardData.getData('text/plain') : ''); } catch(err){}
  }, true);
})();
''';

/// L1 云效令牌页文本扫描：创建成功后令牌明文出现 → 直接抓，免复制（幂等）。
/// SPA pushState 导航不会重置 window，interval 在站内一直有效；整页加载由
/// onPageFinished 重新注入。
const _codeupPatScanJs = '''
(function(){
  if (window.__aiwliPat) return; window.__aiwliPat = true;
  setInterval(function(){
    try {
      var t = document.body ? document.body.innerText : '';
      var onPat = /personalAccessToken/.test(location.href) ||
                  /个人访问令牌|access token/i.test(t);
      if (!onPat) return;
      var m = t.match(/[A-Za-z0-9_-]{20,}/);
      if (m) AiCapture.postMessage(m[0]);
    } catch(e){}
  }, 900);
})();
''';

// ============================ 页面 ============================

Future<WebLoginResult?> showWebLogin(
  BuildContext context, {
  required String provider,
  String? host,
}) => Navigator.push<WebLoginResult>(
  context,
  MaterialPageRoute(builder: (_) => _WebLoginPage(provider: provider, host: host)),
);

class _WebLoginPage extends StatefulWidget {
  final String provider; // github | codeup | gitlab
  final String? host;
  const _WebLoginPage({required this.provider, this.host});
  @override
  State<_WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<_WebLoginPage> {
  late final WebViewController _ctl;
  int _progress = 100;
  String? _org;
  bool _jumpedToPat = false; // 云效：只自动跳令牌页一次，失败后由用户手动导航
  bool _done = false;

  static const _channelName = 'AiCapture';

  @override
  void initState() {
    super.initState();
    _ctl =
        WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..addJavaScriptChannel(
            _channelName,
            onMessageReceived: (m) => _gotToken(m.message),
          )
          ..setNavigationDelegate(
            NavigationDelegate(
              onProgress: (p) => mounted ? setState(() => _progress = p) : null,
              onPageFinished: (_) => _onPage(),
            ),
          );
    _ctl.loadRequest(Uri.parse(_startUrl));
    // 云效是 SPA：登录/选组织多为 pushState 导航，onPageFinished 不可靠 →
    // 轮询 URL（抓组织 ID）+ 周期性补注入（钩子/扫描，幂等）。
    if (widget.provider == 'codeup') {
      Timer.periodic(const Duration(milliseconds: 900), (t) {
        if (!mounted || _done) {
          t.cancel();
          return;
        }
        _pollAliyunUrl();
        _ensureCodeupHelpers();
      });
    }
  }

  String get _startUrl => switch (widget.provider) {
    // 直接请求令牌页：未登录会被 GitHub 带 return_to 弹去登录，登录后原样回来
    // （description/scopes 已预填）；已登录则直达。
    'github' =>
      Uri.https('github.com', '/settings/tokens/new', {
        'description': 'AiwliGit',
        'scopes': 'repo,read:user',
      }).toString(),
    'codeup' => 'https://devops.aliyun.com/',
    _ =>
      'https://${(widget.host ?? '').trim().isEmpty ? 'gitlab.com' : widget.host!.trim()}/-/profile/personal_tokens',
  };

  Future<void> _onPage() async {
    if (!mounted || _done) return;
    switch (widget.provider) {
      case 'github':
        await _injectGithubHelpers();
      case 'codeup':
        await _pollAliyunUrl();
        await _ensureCodeupHelpers();
      default:
        await _injectJs(_clipHookJs);
    }
  }

  Future<void> _injectJs(String js) async {
    try {
      await _ctl.runJavaScript(js);
    } catch (_) {
      // 页面跳转瞬间可能失败，下个周期/页面再试（注入均幂等）
    }
  }

  /// GitHub：剪贴板钩子 + 常驻令牌扫描 + 到达新建令牌页后自动点「Generate token」。
  Future<void> _injectGithubHelpers() async {
    try {
      final url = await _ctl.currentUrl();
      if (url == null || !url.contains('github.com')) return;
    } catch (_) {
      return;
    }
    await _injectJs(_clipHookJs);
    await _injectJs('''
(function(){
  if (window.__aiwliScan) return;
  window.__aiwliScan = setInterval(function(){
    var t = document.body ? (document.body.innerText || '') : '';
    var m = t.match(/ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{60,}/);
    if (m) { clearInterval(window.__aiwliScan); $_channelName.postMessage(m[0]); }
  }, 700);
  if (window.__aiwliClick) return;
  window.__aiwliClick = true;
  setTimeout(function(){
    var btns = document.querySelectorAll('button, input[type=submit], [role=button]');
    for (var i = 0; i < btns.length; i++) {
      var s = btns[i].innerText || btns[i].value || '';
      if (/generate token/i.test(s)) { btns[i].click(); break; }
    }
  }, 1200);
})();
''');
  }

  /// 云效：钩子 + 令牌页扫描（均幂等，每个轮询周期补注入）。
  Future<void> _ensureCodeupHelpers() async {
    await _injectJs(_clipHookJs);
    await _injectJs(_codeupPatScanJs);
  }

  /// 云效：从当前 URL 抓组织 ID；抓到且未跳过则跳「个人访问令牌」页。
  Future<void> _pollAliyunUrl() async {
    if (!mounted || _done) return;
    try {
      final url = await _ctl.currentUrl();
      if (url == null) return;
      final org = extractAliyunOrg(url);
      if (org == null || org.isEmpty || org == _org) return;
      if (!mounted) return;
      setState(() => _org = org);
      if (!_jumpedToPat) {
        _jumpedToPat = true;
        await _ctl.loadRequest(
          Uri.parse('https://codeup.aliyun.com/$org/settings/personalAccessToken'),
        );
      }
    } catch (_) {}
  }

  /// 网页侧回传（L1 扫描 / L2 钩子）：校验后立即返回，免复制。
  void _gotToken(String token) {
    if (_done || !plausibleToken(token, minLen: 16)) return;
    _done = true;
    Navigator.of(context).pop(WebLoginResult(token.trim(), org: _org));
  }

  /// L3 底部兜底按钮：用户在网页里复制令牌后，回这里读剪贴板。
  Future<void> _fromClipboard() async {
    final clip = await Clipboard.getData('text/plain');
    final text = clip?.text;
    final ok =
        widget.provider == 'github'
            ? (extractGithubToken(text ?? '') ??
                (plausibleToken(text) ? text!.trim() : null))
            : (plausibleToken(text) ? text!.trim() : null);
    if (ok == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板里没有令牌：请先在网页里复制令牌再点此按钮')),
        );
      }
      return;
    }
    _done = true;
    if (!mounted) return;
    Navigator.of(context).pop(WebLoginResult(ok, org: _org));
  }

  String get _hintText => switch (widget.provider) {
    'github' =>
      '① 登录 GitHub（已登录会直接跳到令牌页）\n'
          '② 本页会自动生成并抓取令牌，抓到即自动返回\n'
          '③ 若 10 秒无动静：手动点 Generate token 后复制，再点底部按钮',
    'codeup' =>
      '① 登录云效（淘宝 / 支付宝 / 钉钉扫码均可）\n'
          '② App 自动跳到「个人访问令牌」页 → 新建令牌：名称随意（如 AiwliGit），'
          '有效期选最长——云效令牌没有 GitLab 那种权限组，创建后即拥有 API 访问权限\n'
          '③ 创建成功后 App 自动抓取令牌并返回（免复制）\n'
          '若没自动返回：点网页里的「复制」即回，或用底部按钮；'
          '没跳到令牌页时：头像 → 个人设置 → 个人访问令牌',
    _ =>
      '① 登录 GitLab（自建站请先在服务器地址里填好域名）\n'
          '② 打开「Personal Access Tokens」新建令牌（勾选 api、read_repository、write_repository）\n'
          '③ 创建后点网页里的「复制」即自动返回，或用底部按钮',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _ctl.canGoBack()) {
          await _ctl.goBack();
        } else if (context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('网页登录 · 自动绑定', style: const TextStyle(fontSize: 16)),
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    value: _progress / 100,
                    minHeight: 2,
                  ),
                )
              : null,
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Text(
                _hintText,
                style: TextStyle(fontSize: 12, height: 1.5, color: cs.onSurfaceVariant),
              ),
            ),
            if (_org != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Chip(
                    avatar: const Icon(Icons.tag, size: 15),
                    label: Text('组织 ID $_org', style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            Expanded(child: WebViewWidget(controller: _ctl)),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                child: Row(
                  children: [
                    if (widget.provider == 'codeup')
                      TextButton(
                        onPressed: _org == null
                            ? null
                            : () => _ctl.loadRequest(
                                Uri.parse(
                                  'https://codeup.aliyun.com/$_org/settings/personalAccessToken',
                                ),
                              ),
                        child: const Text('去令牌页'),
                      ),
                    const Spacer(),
                    FilledButton.icon(
                      icon: const Icon(Icons.content_paste, size: 17),
                      label: const Text('已复制令牌？点此填入'),
                      onPressed: _fromClipboard,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
