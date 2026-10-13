import 'dart:convert';
import 'dart:io';

import 'secure_store.dart';
import 'url_util.dart';

/// JSON prefs in a single stable file.
///
/// Storage location: the app's files dir (queried once from the Android side
/// via MethodChannel), which survives system cache cleanups — code_cache is
/// NOT used because MIUI wipes it (prefs silently disappeared twice in the
/// field). Fallback if the query fails: Directory.systemTemp with the parent
/// dir created before every write.
///
/// Non-sensitive data (last repo / recents / onboarding flag / scan cache /
/// theme mode) is plain text. Remote credentials are AES/GCM-encrypted through
/// Android Keystore ([SecureStore]) and stored only as ciphertext under
/// `credEnc`. Legacy plaintext `cred` entries are migrated to encrypted
/// storage on first read and the plaintext key is removed.
class Prefs {
  static Prefs? _inst;
  static Prefs get instance => _inst ??= Prefs._();
  Prefs._();

  Map<String, dynamic>? _cache;
  String? _dirOverride;
  Future<void> _saveTail = Future<void>.value();

  /// Called once from main() with the Android files dir (may be null on
  /// non-Android builds).
  void setDir(String? dir) {
    _dirOverride = (dir == null || dir.isEmpty) ? null : dir;
    _cache = null; // re-read from the new location
  }

  Future<String> get _file async {
    final dir = _dirOverride ?? Directory.systemTemp.path;
    return '$dir/gitdeck_prefs.json';
  }

  Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final f = File(await _file);
      if (await f.exists()) {
        _cache = Map<String, dynamic>.from(
          jsonDecode(await f.readAsString()) as Map,
        );
      }
    } catch (_) {}
    _cache ??= {};
    return _cache!;
  }

  /// Serialize writes so rapid UI actions cannot overwrite each other's prefs.
  /// The returned future deliberately propagates I/O failures: callers that
  /// show a success state must not claim a setting was saved when it was not.
  Future<void> _save() {
    final next = _saveTail.catchError((_) {}).then((_) async {
      final f = File(await _file);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(_cache));
    });
    _saveTail = next;
    return next;
  }

  Future<Map<String, Object?>?> credentials() async {
    final c = await _load();
    final blob = c['credEnc'] as String?;
    if (blob != null) {
      final plain = await SecureStore.decrypt(blob);
      if (plain != null) {
        try {
          final m = jsonDecode(plain);
          if (m is Map) return Map<String, Object?>.from(m);
        } catch (_) {}
      }
      // Unreadable blob (e.g. Keystore key lost after reinstall) → drop it.
      c.remove('credEnc');
      await _save();
      return null;
    }
    // Legacy plaintext entry → migrate to encrypted storage, drop plaintext.
    final legacy = c['cred'];
    if (legacy is Map && legacy.isNotEmpty) {
      final m = Map<String, Object?>.from(legacy);
      await setCredentials(m);
      return m;
    }
    return null;
  }

  /// Named hosting accounts. Secrets are encrypted together with the account list.
  /// provider: github | codeup | gitlab | generic; host is optional for custom Git servers.
  Future<List<Map<String, Object?>>> accounts() async {
    final c = await _load();
    final blob = c['accountsEnc'] as String?;
    if (blob != null) {
      final plain = await SecureStore.decrypt(blob);
      if (plain != null) {
        try {
          final value = jsonDecode(plain);
          if (value is List) {
            return [
              for (final x in value)
                if (x is Map) Map<String, Object?>.from(x),
            ];
          }
        } catch (_) {}
      }
      c.remove('accountsEnc');
      await _save();
    }
    return [];
  }

  /// Select the first bound account matching a remote host. Exact host matches
  /// win; a provider default is used only when no custom host was entered.
  Future<Map<String, Object?>?> credentialsForUrl(String url) async {
    final host = hostFromUrl(url);
    if (host == null || host.isEmpty) return credentials();
    final list = await accounts();
    for (final a in list) {
      final configured =
          ((a['host'] as String?)?.trim().isNotEmpty == true
                  ? (a['host'] as String).trim()
                  : (defaultHostFor((a['provider'] as String?) ?? 'generic') ??
                        ''))
              .toLowerCase();
      if (configured == host) {
        return {
          if (a['user'] is String && (a['user'] as String).isNotEmpty)
            'user': a['user'],
          if (a['pass'] is String && (a['pass'] as String).isNotEmpty)
            'pass': a['pass'],
          if (a['keyPath'] is String) 'keyPath': a['keyPath'],
          if (a['passphrase'] is String) 'passphrase': a['passphrase'],
        };
      }
    }
    return credentials();
  }

  Future<void> setAccounts(List<Map<String, Object?>> value) async {
    final c = await _load();
    final blob = await SecureStore.encrypt(jsonEncode(value));
    if (blob == null) {
      // Do not silently write tokens in plaintext. Accounts are optional on platforms
      // without a secure keystore; the normal per-repo credential flow remains usable.
      c.remove('accountsEnc');
    } else {
      c['accountsEnc'] = blob;
    }
    await _save();
  }

  Future<void> setCredentials(Map<String, Object?>? cred) async {
    final c = await _load();
    c.remove(
      'cred',
    ); // plaintext is never kept once secure storage is available
    if (cred == null || cred.isEmpty) {
      c.remove('credEnc');
      await _save();
      return;
    }
    final blob = await SecureStore.encrypt(jsonEncode(cred));
    if (blob != null) {
      c['credEnc'] = blob;
    } else {
      // No secure channel (non-Android builds): fall back to plaintext so the
      // feature keeps working there. Documented limitation, Android is primary.
      c['cred'] = cred;
    }
    await _save();
  }

  Future<String?> lastRepo() async => (await _load())['lastRepo'] as String?;
  Future<void> setLastRepo(String path) async {
    (await _load())['lastRepo'] = path;
    if (path.isNotEmpty) await addRecent(path);
    await _save();
  }

  /// Persisted recently-opened repos (most recent first, dedup, cap 10).
  Future<List<String>> recents() async {
    final r = (await _load())['recents'];
    return r is List
        ? [
            for (final x in r)
              if (x is String) x,
          ]
        : [];
  }

  Future<void> addRecent(String path) async {
    final c = await _load();
    final list = <String>[path, ...?((c['recents'] as List?)?.cast<String>())];
    final dedup = <String>[];
    for (final p in list) {
      if (!dedup.contains(p)) dedup.add(p);
    }
    c['recents'] = dedup.take(10).toList();
    await _save();
  }

  // ---- repo scan cache (工程目录页的扫描结果) ----
  Future<List<String>> scanCache() async {
    final r = (await _load())['scanCache'];
    return r is List
        ? [
            for (final x in r)
              if (x is String) x,
          ]
        : [];
  }

  Future<void> setScanCache(List<String> repos) async {
    (await _load())['scanCache'] = repos;
    (await _load())['scanAt'] = DateTime.now().millisecondsSinceEpoch;
    await _save();
  }

  /// When the scan cache was last written (epoch ms), or 0.
  Future<int> scanAt() async => (await _load())['scanAt'] as int? ?? 0;

  // ---- 手动排序（侧栏长按拖动，v1.4.4）----
  /// 用户手动排定的仓库顺序（完整路径，可能含已失效条目）。
  Future<List<String>> repoOrder() async {
    final r = (await _load())['repoOrder'];
    return r is List
        ? [
            for (final x in r)
              if (x is String) x,
          ]
        : [];
  }

  Future<void> setRepoOrder(List<String> repos) async {
    (await _load())['repoOrder'] = repos;
    await _save();
  }

  // ---- 侧栏隐藏仓库（只从 AiwliGit 列表移除，不删除磁盘内容）----
  Future<List<String>> hiddenRepos() async {
    final r = (await _load())['hiddenRepos'];
    return r is List
        ? [
            for (final x in r)
              if (x is String) x,
          ]
        : [];
  }

  Future<void> hideRepo(String path) async {
    final c = await _load();
    final list = <String>[
      path,
      ...?((c['hiddenRepos'] as List?)?.cast<String>()),
    ];
    c['hiddenRepos'] = {...list}.toList();
    await _save();
  }

  Future<void> unhideRepo(String path) async {
    final c = await _load();
    final list = (c['hiddenRepos'] as List?)?.where((x) => x != path).toList();
    if (list == null || list.isEmpty) {
      c.remove('hiddenRepos');
    } else {
      c['hiddenRepos'] = list;
    }
    await _save();
  }

  // ---- MCP service ----
  Future<bool> mcpEnabled() async => (await _load())['mcpEnabled'] == true;
  Future<void> setMcpEnabled(bool v) async {
    (await _load())['mcpEnabled'] = v;
    await _save();
  }

  Future<int> mcpPort() async => (await _load())['mcpPort'] as int? ?? 8613;
  Future<void> setMcpPort(int port) async {
    (await _load())['mcpPort'] = port;
    await _save();
  }

  Future<String> mcpToken() async =>
      (await _load())['mcpToken'] as String? ?? '';
  Future<void> setMcpToken(String token) async {
    (await _load())['mcpToken'] = token;
    await _save();
  }

  /// GitHub OAuth device-flow client id (user-registered OAuth App).
  Future<String?> githubClientId() async =>
      (await _load())['githubClientId'] as String?;
  Future<void> setGithubClientId(String v) async {
    (await _load())['githubClientId'] = v.trim();
    await _save();
  }

  /// Path of the app-managed SSH known_hosts file (stable prefs dir).
  Future<String> sshKnownHostsPath() async {
    final dir = _dirOverride ?? Directory.systemTemp.path;
    return '$dir/gitdeck_known_hosts';
  }

  /// First-run onboarding card has been acknowledged.
  Future<bool> onboarded() async => (await _load())['onboarded'] == true;
  Future<void> setOnboarded() async {
    (await _load())['onboarded'] = true;
    await _save();
  }

  // ---- 网络安全：TLS 证书校验逃生口 ----
  /// 跳过 TLS 证书校验。**默认 false（校验开启）**。
  ///
  /// 开启后等价于「`certificate_check` 无条件返回 `Ok`」的方案：
  /// 任何中间人（含 VPN / 代理的 TLS 拦截）都无法被发现，代码与访问令牌
  /// 可能被窃取。仅在自签证书仓库等**确知原因**的场景临时开启。见 docs/13。
  Future<bool> skipTlsVerify() async => (await _load())['skipTlsVerify'] == true;

  Future<void> setSkipTlsVerify(bool v) async {
    (await _load())['skipTlsVerify'] = v;
    await _save();
  }

  // ---- theme mode: 'system' | 'dark' | 'light' ----
  Future<String> themeModeName() async =>
      (await _load())['themeMode'] as String? ?? 'system';

  Future<void> setThemeModeName(String name) async {
    (await _load())['themeMode'] = name;
    await _save();
  }
}
