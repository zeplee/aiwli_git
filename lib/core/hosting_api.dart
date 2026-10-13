/// Hosting platform REST clients: GitHub / GitLab / 云效 Codeup.
///
/// Everything the UI shows (repo import, connection test, OAuth device flow)
/// is pure-function parseable — the `parse*` / model mapping helpers have no
/// IO and are covered by unit tests; the request builders only assemble
/// headers/URLs, so tests can assert on them too.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'url_util.dart';

// ============================ models ============================

class CloudRepo {
  final String name; // short name, e.g. `demo`
  final String fullName; // owner/name or path_with_namespace
  final String? description;
  final String? updatedAt; // ISO8601 best effort
  final bool isPrivate;
  final bool isFork; // GitHub `fork` / GitLab `forked_from_project` 存在
  final String httpsUrl;
  final String? sshUrl;
  final String? defaultBranch;
  CloudRepo({
    required this.name,
    required this.fullName,
    this.description,
    this.updatedAt,
    required this.isPrivate,
    this.isFork = false,
    required this.httpsUrl,
    this.sshUrl,
    this.defaultBranch,
  });

  Map<String, Object?> toJson() => {
    'name': name,
    'fullName': fullName,
    'description': ?description,
    'updatedAt': ?updatedAt,
    'private': isPrivate,
    'fork': isFork,
    'httpsUrl': httpsUrl,
    'sshUrl': ?sshUrl,
    'defaultBranch': ?defaultBranch,
  };
}

class HostingException implements Exception {
  final String message;
  HostingException(this.message);
  @override
  String toString() => message;
}

// ======================= account helpers ========================

/// provider: github | codeup | gitlab | generic
String accountProvider(Map<String, Object?> a) =>
    (a['provider'] as String?) ?? 'generic';

String accountLabel(Map<String, Object?> a) =>
    (a['label'] as String?) ?? accountProvider(a);

String? accountHost(Map<String, Object?> a) =>
    ((a['host'] as String?) ?? '').trim().isEmpty
    ? defaultHostFor(accountProvider(a))
    : (a['host'] as String).trim();

String? accountToken(Map<String, Object?> a) {
  final t = (a['pass'] as String?) ?? '';
  return t.trim().isEmpty ? null : t.trim();
}

String? accountOrg(Map<String, Object?> a) {
  final o = (a['org'] as String?) ?? '';
  return o.trim().isEmpty ? null : o.trim();
}

// ===================== pure parse functions =====================

/// GitHub `GET /user/repos` item → [CloudRepo]. Tolerates nulls.
CloudRepo? parseGithubRepo(Map<String, dynamic> j) {
  final name = j['name'] as String?;
  final full = j['full_name'] as String?;
  if (name == null || name.isEmpty) return null;
  return CloudRepo(
    name: name,
    fullName: full ?? name,
    description: j['description'] as String?,
    updatedAt: j['updated_at'] as String?,
    isPrivate: (j['private'] ?? false) as bool,
    isFork: (j['fork'] ?? false) as bool,
    httpsUrl: (j['clone_url'] as String?) ?? '',
    sshUrl: j['ssh_url'] as String?,
    defaultBranch: j['default_branch'] as String?,
  );
}

List<CloudRepo> parseGithubRepos(String body) => [
  for (final x in (jsonDecode(body) as List))
    if (x is Map) ?parseGithubRepo(Map<String, dynamic>.from(x)),
];

/// GitLab / Codeup `GET /api/v4/projects` item → [CloudRepo].
CloudRepo? parseGitlabRepo(Map<String, dynamic> j) {
  final name = j['name'] as String?;
  final path = j['path_with_namespace'] as String? ?? j['path'] as String?;
  if (name == null || name.isEmpty) return null;
  return CloudRepo(
    name: name,
    fullName: path ?? name,
    description: j['description'] as String?,
    updatedAt: j['last_activity_at'] as String?,
    isPrivate: j['visibility'] == 'private',
    isFork: j['forked_from_project'] != null,
    httpsUrl: (j['http_url_to_repo'] as String?) ?? '',
    sshUrl: j['ssh_url_to_repo'] as String?,
    defaultBranch: j['default_branch'] as String?,
  );
}

List<CloudRepo> parseGitlabRepos(String body) => [
  for (final x in (jsonDecode(body) as List))
    if (x is Map) ?parseGitlabRepo(Map<String, dynamic>.from(x)),
];

/// GitHub `GET /user` → login. GitLab/Codeup `GET /api/v4/user` → username.
String? parseWhoami(String provider, String body) {
  final j = jsonDecode(body);
  if (j is! Map) return null;
  final v = provider == 'github' ? j['login'] : (j['username'] ?? j['login']);
  return v is String && v.isNotEmpty ? v : null;
}

// -------------------- 云效响应解析（防御式） --------------------
// 云效 OpenAPI 的响应封装并不统一：有的端点裸数组，有的是 {result: [...]} /
// {data: [...]}。这里统一「剥壳」，字段名也做多路兜底。

Object? _unwrap(Object? j, List<String> keys) {
  if (j is Map) {
    for (final k in keys) {
      final v = j[k];
      if (v is List || v is Map) return v;
    }
  }
  return j;
}

/// 云效仓库项 → [CloudRepo]。
CloudRepo? parseCodeupRepo(Map<String, dynamic> j) {
  final raw = (j['name'] as String?) ?? (j['path'] as String?);
  if (raw == null || raw.isEmpty) return null;
  final name = raw.contains('/') ? raw.split('/').last : raw;
  final visibility = (j['visibility'] as String?)?.toLowerCase();
  return CloudRepo(
    name: name,
    fullName: (j['pathWithNamespace'] as String?) ??
        (j['path'] as String?) ??
        name,
    description: j['description'] as String?,
    updatedAt:
        (j['lastActivityAt'] as String?) ?? (j['updatedAt'] as String?),
    isPrivate: visibility != 'public',
    isFork: j['forkedFrom'] != null,
    httpsUrl: (j['httpUrl'] as String?) ?? (j['webUrl'] as String?) ?? '',
    sshUrl: (j['sshUrl'] as String?) ?? (j['sshCloneUrl'] as String?),
    defaultBranch:
        (j['defaultBranch'] as String?) ?? (j['default_branch'] as String?),
  );
}

List<CloudRepo> parseCodeupRepos(String body) {
  final list = _unwrap(jsonDecode(body), const [
    'result',
    'data',
    'items',
    'repositories',
    'list',
  ]);
  if (list is! List) return const [];
  return [
    for (final x in list)
      if (x is Map) ?parseCodeupRepo(Map<String, dynamic>.from(x)),
  ];
}

String? parseCodeupWhoami(String body) {
  final m = _unwrap(jsonDecode(body), const ['result', 'data', 'user']);
  if (m is! Map) return null;
  for (final k in ['name', 'username', 'nickName', 'displayName', 'login']) {
    final v = m[k];
    if (v is String && v.isNotEmpty) return v;
  }
  final id = m['id'];
  return id is num ? id.toString() : null;
}

/// 云效「新建仓库」响应 → [CloudRepo]（裸对象或 {result: {...}} 都吃）。
CloudRepo? parseCodeupCreated(String body) {
  final v = _unwrap(jsonDecode(body), const ['result', 'data']);
  if (v is! Map) return null;
  return parseCodeupRepo(Map<String, dynamic>.from(v));
}

// ======================= request builders =======================

Map<String, String> githubHeaders(String token) => {
  'Authorization': 'Bearer $token',
  'Accept': 'application/vnd.github+json',
  'X-GitHub-Api-Version': '2022-11-28',
  'User-Agent': 'AiwliGit',
};

Map<String, String> gitlabHeaders(String token) => {
  'PRIVATE-TOKEN': token,
  'User-Agent': 'AiwliGit',
};

Uri githubReposUri() => Uri.parse(
  'https://api.github.com/user/repos'
  '?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member',
);

Uri gitlabReposUri(String host, {String? org}) {
  final q = <String, String>{
    'membership': 'true',
    'order_by': 'last_activity_at',
    'per_page': '100',
    'organizationId': ?org,
  };
  return Uri.https(host, '/api/v4/projects', q);
}

/// GitHub 星标列表端点。
Uri githubStarredUri() => Uri.parse(
  'https://api.github.com/user/starred?per_page=100&sort=updated',
);

/// GitLab/Codeup 星标列表端点：`GET /api/v4/projects?starred=true`。
/// 云效兼容层若不认该参数会在请求层被识别并给出友好错误。
Uri gitlabStarredUri(String host, {String? org}) {
  final q = <String, String>{
    'starred': 'true',
    'order_by': 'last_activity_at',
    'per_page': '100',
    'organizationId': ?org,
  };
  return Uri.https(host, '/api/v4/projects', q);
}

Uri whoamiUri(String provider, String host) => Uri.parse(
  provider == 'github'
      ? 'https://api.github.com/user'
      : 'https://$host/api/v4/user',
);

// -------------------- 云效 Codeup OpenAPI --------------------
// ⚠️ `codeup.aliyun.com/api/v4/*` 是「网页会话(cookie)」端点，**不认个人访问令牌**：
// 带 PRIVATE-TOKEN 请求会 302 跳到 account.aliyun.com 登录页并返回 HTML，
// 客户端按 JSON 解析就会炸出 FormatException。云效的令牌 API 在
// openapi-rdc.aliyuncs.com，鉴权头是 `x-yunxiao-token`。
const codeupApiHost = 'openapi-rdc.aliyuncs.com';

Map<String, String> codeupHeaders(String token) => {
  'x-yunxiao-token': token,
  'Accept': 'application/json',
  'User-Agent': 'AiwliGit',
};

/// 当前用户：`GET /oapi/v1/platform/user`。
Uri codeupWhoamiUri() => Uri.https(codeupApiHost, '/oapi/v1/platform/user');

/// 组织下仓库列表：`GET /oapi/v1/codeup/organizations/{orgId}/repositories`。
Uri codeupReposUri(String org, {int page = 1, int perPage = 100}) => Uri.https(
  codeupApiHost,
  '/oapi/v1/codeup/organizations/$org/repositories',
  {
    'page': '$page',
    'perPage': '$perPage',
    'orderBy': 'last_activity_at',
    'sort': 'desc',
  },
);

/// 新建仓库：`POST /oapi/v1/codeup/organizations/{orgId}/repositories`。
Uri codeupCreateRepoUri(String org) => Uri.https(
  codeupApiHost,
  '/oapi/v1/codeup/organizations/$org/repositories',
);

String codeupCreateRepoBody(String name, bool isPrivate) => jsonEncode({
  'name': name,
  'path': name,
  'visibility': isPrivate ? 'private' : 'public',
});

// -------------------- repo creation builders --------------------

/// 新建仓库请求体（纯函数，可测）：
/// GitHub `POST /user/repos` 用 `private`；GitLab/Codeup `POST /api/v4/projects`
/// 用 `visibility`。云效的 GitLab 兼容层同款字段。
String createRepoBody(String provider, String name, bool isPrivate) {
  final j = <String, Object?>{
    'name': name,
    if (provider == 'github') 'private': isPrivate,
    if (provider != 'github') 'visibility': isPrivate ? 'private' : 'public',
  };
  return jsonEncode(j);
}

/// 新建仓库端点（纯函数，可测）。
Uri createRepoUri(String provider, String host) => Uri.parse(
  provider == 'github'
      ? 'https://api.github.com/user/repos'
      : 'https://$host/api/v4/projects',
);

/// 新建仓库响应 → [CloudRepo]（GitHub / GitLab·Codeup 兼容两种响应）。
CloudRepo? parseCreatedRepo(String provider, String body) {
  final j = jsonDecode(body);
  if (j is! Map) return null;
  return provider == 'github'
      ? parseGithubRepo(Map<String, dynamic>.from(j))
      : parseGitlabRepo(Map<String, dynamic>.from(j));
}

// =========================== requests ===========================

const _timeout = Duration(seconds: 15);

void _check(http.Response r, String what) {
  if (r.statusCode >= 200 && r.statusCode < 300) return;
  var detail = r.body;
  if (detail.length > 160) detail = detail.substring(0, 160);
  throw HostingException('$what 失败：HTTP ${r.statusCode} $detail');
}

/// 云效专用：401/403 通常是令牌无效/权限不足，给可操作提示而不是裸 JSON。
void _checkCodeup(http.Response r, String what) {
  if (r.statusCode == 401 || r.statusCode == 403) {
    throw HostingException(
      '$what 失败：云效令牌无效或权限不足（HTTP ${r.statusCode}），'
      '请到「设置 → 代码托管账号」重新绑定（网页登录会自动抓取令牌与组织 ID）',
    );
  }
  _check(r, what);
}

/// 把「响应不是 JSON」翻译成人话（纯函数，可测）。
/// 典型场景：请求打到网页端点被 302 到阿里云登录页，返回 `<!DOCTYPE html>`。
String nonJsonHint(String what, String body) {
  var head = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (head.length > 80) head = '${head.substring(0, 80)}…';
  return '$what：接口返回的不是 JSON（可能命中了网页/登录页）→ $head';
}

T _parseOrHint<T>(String what, String body, T Function(String) parse) {
  try {
    return parse(body);
  } on FormatException {
    throw HostingException(nonJsonHint(what, body));
  }
}

/// List the account's repositories on its hosting provider.
/// [starred] 为 true 时拉取星标仓库（GitHub `/user/starred`；
/// GitLab/Codeup `projects?starred=true`，不支持时抛带指引的错误）。
Future<List<CloudRepo>> listCloudRepos(
  Map<String, Object?> account, {
  bool starred = false,
  http.Client? client,
}) async {
  final provider = accountProvider(account);
  final token = accountToken(account);
  if (token == null) {
    throw HostingException('账号「${accountLabel(account)}」还没有填写访问令牌');
  }
  final c = client ?? http.Client();
  try {
    switch (provider) {
      case 'github':
        final r = await c
            .get(
              starred ? githubStarredUri() : githubReposUri(),
              headers: githubHeaders(token),
            )
            .timeout(_timeout);
        _check(r, starred ? '获取 GitHub 星标列表' : '获取 GitHub 仓库列表');
        return parseGithubRepos(utf8.decode(r.bodyBytes));
      case 'gitlab':
        final host = accountHost(account);
        if (host == null) {
          throw HostingException('账号「${accountLabel(account)}」缺少服务器地址');
        }
        final r = await c
            .get(
              starred
                  ? gitlabStarredUri(host, org: accountOrg(account))
                  : gitlabReposUri(host, org: accountOrg(account)),
              headers: gitlabHeaders(token),
            )
            .timeout(_timeout);
        if (starred &&
            (r.statusCode == 400 ||
                r.statusCode == 403 ||
                r.statusCode == 422)) {
          throw HostingException('该平台不支持星标仓库列表（API 未提供）');
        }
        _check(r, starred ? '获取星标列表' : '获取仓库列表');
        return _parseOrHint<List<CloudRepo>>(
          '获取仓库列表',
          utf8.decode(r.bodyBytes),
          parseGitlabRepos,
        );
      case 'codeup':
        final org = accountOrg(account);
        if (org == null) {
          throw HostingException(
            '账号「${accountLabel(account)}」缺少云效组织 ID：'
            '请用「网页登录」重新绑定（会自动抓取），或手动填写组织 ID',
          );
        }
        if (starred) {
          throw HostingException('云效 OpenAPI 未提供星标仓库列表');
        }
        final r = await c
            .get(codeupReposUri(org), headers: codeupHeaders(token))
            .timeout(_timeout);
        _checkCodeup(r, '获取仓库列表');
        return _parseOrHint<List<CloudRepo>>(
          '获取仓库列表',
          utf8.decode(r.bodyBytes),
          parseCodeupRepos,
        );
      default:
        throw HostingException('「其他 Git 服务器」账号不支持仓库列表，请直接克隆');
    }
  } on TimeoutException {
    throw HostingException('连接超时，请检查网络后重试');
  } finally {
    if (client == null) c.close();
  }
}

/// Create a new repository on the account's hosting provider. Returns the
/// created [CloudRepo]. GitLab/Codeup 用 GitLab 兼容 `POST /api/v4/projects`；
/// 云效若未开放该端点会给出带指引的友好错误。
Future<CloudRepo> createCloudRepo(
  Map<String, Object?> account,
  String name, {
  bool isPrivate = true,
  http.Client? client,
}) async {
  final provider = accountProvider(account);
  final token = accountToken(account);
  if (token == null) {
    throw HostingException('账号「${accountLabel(account)}」还没有填写访问令牌');
  }
  final host = accountHost(account);
  if (provider != 'github' && host == null) {
    throw HostingException('账号「${accountLabel(account)}」缺少服务器地址');
  }
  final c = client ?? http.Client();
  try {
    if (provider == 'codeup') {
      final org = accountOrg(account);
      if (org == null) {
        throw HostingException(
          '账号「${accountLabel(account)}」缺少云效组织 ID：'
          '请用「网页登录」重新绑定（会自动抓取），或手动填写组织 ID',
        );
      }
      final r = await c
          .post(
            codeupCreateRepoUri(org),
            headers: codeupHeaders(token),
            body: codeupCreateRepoBody(name, isPrivate),
          )
          .timeout(_timeout);
      if (r.statusCode == 400 || r.statusCode == 409) {
        throw HostingException('创建失败：很可能已存在同名仓库（HTTP ${r.statusCode}）');
      }
      if (r.statusCode == 401 || r.statusCode == 403 || r.statusCode == 404) {
        throw HostingException(
          '创建被拒绝（HTTP ${r.statusCode}）：请检查云效令牌是否有代码库写入权限，'
          '以及组织 ID 是否正确',
        );
      }
      _check(r, '创建仓库');
      final repo = _parseOrHint(
        '创建仓库',
        utf8.decode(r.bodyBytes),
        parseCodeupCreated,
      );
      if (repo == null) throw HostingException('创建成功但响应无法解析');
      return repo;
    }
    var body = createRepoBody(provider, name, isPrivate);
    var r = await c
        .post(
          createRepoUri(provider, host ?? ''),
          headers: provider == 'github'
              ? githubHeaders(token)
              : gitlabHeaders(token),
          body: body,
        )
        .timeout(_timeout);
    if (r.statusCode == 400 || r.statusCode == 409) {
      throw HostingException('创建失败：很可能已存在同名仓库（HTTP ${r.statusCode}）');
    }
    if (r.statusCode == 403 || r.statusCode == 404) {
      throw HostingException(
        '创建被拒绝（HTTP ${r.statusCode}）：请检查令牌是否勾选了仓库写入权限',
      );
    }
    _check(r, '创建仓库');
    final repo = _parseOrHint(
      '创建仓库',
      utf8.decode(r.bodyBytes),
      (b) => parseCreatedRepo(provider, b),
    );
    if (repo == null) throw HostingException('创建成功但响应无法解析');
    return repo;
  } on TimeoutException {
    throw HostingException('连接超时，请检查网络后重试');
  } finally {
    if (client == null) c.close();
  }
}

/// Connection test: resolve the account's identity. Returns the login name.
Future<String> testConnection(
  Map<String, Object?> account, {
  http.Client? client,
}) async {
  final provider = accountProvider(account);
  final token = accountToken(account);
  if (token == null) {
    throw HostingException('账号「${accountLabel(account)}」还没有填写访问令牌');
  }
  final c = client ?? http.Client();
  try {
    switch (provider) {
      case 'github':
        final r = await c
            .get(whoamiUri('github', ''), headers: githubHeaders(token))
            .timeout(_timeout);
        _check(r, '连接测试');
        return parseWhoami('github', utf8.decode(r.bodyBytes)) ?? '(未知用户)';
      case 'gitlab':
        final host = accountHost(account);
        if (host == null) {
          throw HostingException('账号「${accountLabel(account)}」缺少服务器地址');
        }
        final r = await c
            .get(whoamiUri(provider, host), headers: gitlabHeaders(token))
            .timeout(_timeout);
        _check(r, '连接测试');
        return _parseOrHint<String?>(
              '连接测试',
              utf8.decode(r.bodyBytes),
              (b) => parseWhoami(provider, b),
            ) ??
            '(未知用户)';
      case 'codeup':
        final r = await c
            .get(codeupWhoamiUri(), headers: codeupHeaders(token))
            .timeout(_timeout);
        _checkCodeup(r, '连接测试');
        return _parseOrHint<String?>(
              '连接测试',
              utf8.decode(r.bodyBytes),
              parseCodeupWhoami,
            ) ??
            '(未知用户)';
      default:
        throw HostingException('「其他 Git 服务器」账号请在仓库上直接测试拉取/推送');
    }
  } on TimeoutException {
    throw HostingException('连接超时，请检查网络后重试');
  } finally {
    if (client == null) c.close();
  }
}

// ==================== GitHub OAuth device flow ====================
//
// Device flow needs only a client_id (OAuth App, "Enable Device Flow" checked,
// no client secret). The id is user-provided and stored in prefs — aiwli
// ships none so no one can ride on somebody else's registered app.
//
// ---- 为什么必须申请 workflow 权限（v1.5.24）----
//
// 本 App 的仓库里通常带有 `.github/workflows/*.yml`。GitHub 有一条硬规矩：
// **令牌若没有 `workflow` scope，创建或更新 workflow 文件会被服务端直接拒绝**
// （原始答复：`refusing to allow a Personal Access Token to create or update
// workflow '.github/workflows/ci.yml' without 'workflow' scope`）。
//
// 而这个拒绝发生在 **push 报告（report-status）里**，不是传输层错误：libgit2
// 的 `push()` 照样返回 Ok。1.5.23 之前在 App 侧表现为**假成功**——跟踪引用被
// 写、错误日志零新增、远端一个字节都没收到（1.5.23 已在 Rust 侧挂了
// push_update_reference 回调 + 服务端二次核对，现在会如实报错）。
//
// 所以「自动化授权」的正确做法不是事后补救，而是**在申请时就带上这个 scope**：
// 设备流只需在这一处声明，用户在浏览器里看到的就是 repo + workflow 一起授权，
// 不必自己去设置页勾复选框。**改这一行即可解决根因。**
const ghOauthScopes = 'repo workflow';

class DeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresIn;
  final int interval;
  DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });
}

class DeviceFlowDenied implements Exception {
  final String message;
  DeviceFlowDenied(this.message);
  @override
  String toString() => message;
}

/// Pure mapper for the device-code response (also used by tests).
DeviceCode parseDeviceCode(Map<String, dynamic> j) => DeviceCode(
  deviceCode: j['device_code'] as String? ?? '',
  userCode: j['user_code'] as String? ?? '',
  verificationUri:
      j['verification_uri'] as String? ?? 'https://github.com/login/device',
  expiresIn: (j['expires_in'] as num?)?.toInt() ?? 900,
  interval: (j['interval'] as num?)?.toInt() ?? 5,
);

Future<DeviceCode> startDeviceFlow(
  String clientId, {
  String scopes = ghOauthScopes,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final r = await c
        .post(
          Uri.parse('https://github.com/login/device/code'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'AiwliGit',
          },
          body: {'client_id': clientId, 'scope': scopes},
        )
        .timeout(_timeout);
    _check(r, '获取设备码');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map) throw HostingException('设备码响应异常');
    final dc = parseDeviceCode(Map<String, dynamic>.from(j));
    if (dc.deviceCode.isEmpty || dc.userCode.isEmpty) {
      throw HostingException(
        '设备码响应缺少字段：${r.body.substring(0, r.body.length.clamp(0, 160))}',
      );
    }
    return dc;
  } finally {
    if (client == null) c.close();
  }
}

/// Poll once for the access token. Returns the token when the user has
/// authorized; returns null while still `pending`; throws when expired or
/// denied. [slowDownDelta] accumulates after a `slow_down` response.
Future<String?> pollDeviceFlowOnce(
  String clientId,
  DeviceCode dc, {
  int slowDownDelta = 0,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final r = await c
        .post(
          Uri.parse('https://github.com/login/oauth/access_token'),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'AiwliGit',
          },
          body: {
            'client_id': clientId,
            'device_code': dc.deviceCode,
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          },
        )
        .timeout(_timeout);
    _check(r, '等待授权');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map) return null;
    final token = j['access_token'] as String?;
    if (token != null && token.isNotEmpty) return token;
    final err = j['error'] as String?;
    switch (err) {
      case 'authorization_pending':
        return null;
      case 'slow_down':
        return null; // caller adds its own backoff
      case 'expired_token':
        throw DeviceFlowDenied('授权码已过期，请重新发起登录');
      case 'access_denied':
        throw DeviceFlowDenied('你取消了授权');
      default:
        if (err != null) throw DeviceFlowDenied('GitHub 授权失败：$err');
        return null;
    }
  } finally {
    if (client == null) c.close();
  }
}

/// Convenience: full polling loop with backoff. Returns the access token.
Future<String> awaitDeviceFlow(
  String clientId,
  DeviceCode dc, {
  void Function()? onTick,
}) async {
  var interval = dc.interval;
  final deadline = DateTime.now().add(Duration(seconds: dc.expiresIn));
  var slowDelta = 0;
  while (DateTime.now().isBefore(deadline)) {
    onTick?.call();
    await Future.delayed(Duration(seconds: interval + slowDelta));
    final token = await pollDeviceFlowOnce(
      clientId,
      dc,
      slowDownDelta: slowDelta,
    );
    if (token != null) return token;
  }
  throw DeviceFlowDenied('授权超时，请重试');
}

// ---------------- 令牌权限自检（v1.5.24） ----------------

/// 预勾选好 `repo` + `workflow` 的经典令牌创建页。
///
/// 用户点开就是**已经勾好两个复选框**的页面，只需滚到底点 Generate →
/// 复制 → 粘回 App。「去设置页找复选框」这一步被彻底消掉。
Uri ghNewTokenUri({String note = 'AiwliGit'}) => Uri.parse(
  'https://github.com/settings/tokens/new'
  '?scopes=repo,workflow&description=${Uri.encodeComponent(note)}',
);

/// 新建 OAuth App 的页面（设备流登录需要它的 client_id）。
///
/// 一次性成本：建好后把 client_id 填进 App，**以后登录永远是 App 内一键**。
/// 建的时候唯一必须勾的是 **Enable Device Flow**，其余随便填。
Uri ghNewOauthAppUri() => Uri.parse('https://github.com/settings/applications/new');

/// GitHub 令牌的**实际能力**。
///
/// `GET /user` 是唯一能顺手问到令牌权限的廉价调用：GitHub 会在响应头
/// `X-OAuth-Scopes` 里回显该令牌拥有的 scope（逗号 + 空格分隔）。
///
/// 边界（诚实说明，别把"问不到"当成"没权限"）：
/// - 经典 PAT / OAuth 令牌 → 有该响应头，[scopes] 可用；
/// - **细粒度 PAT 与 GitHub App 安装令牌不走 OAuth，该头不存在** →
///   [scopes] 为 null，[canPushWorkflow] 也为 null，表示「无法自动判定」，
///   此时 UI 必须说"无法判定"并给手动核对入口，而不是报警。
class GhTokenInfo {
  final String login;

  /// null = 无法自动判定（非 OAuth 令牌）。
  final List<String>? scopes;

  GhTokenInfo({required this.login, required this.scopes});

  /// null = 无法自动判定；true/false = 服务端明确回的 scope 里有/没有 workflow。
  bool? get canPushWorkflow => scopes?.contains('workflow');

  /// 人类可读的权限摘要。
  String get scopeText {
    final s = scopes;
    if (s == null) return '无法自动判定（细粒度令牌或 GitHub App 令牌不返回 scope）';
    if (s.isEmpty) return '无（令牌未授予任何 scope）';
    return s.join('、');
  }
}

/// 问一次 GitHub：这个令牌是谁、有哪些 scope。
///
/// 只做一次 GET /user，不写任何东西；失败原样抛出（由调用方决定是否吞掉）。
Future<GhTokenInfo> ghTokenInfo(String token, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final r = await c
        .get(
          Uri.parse('https://api.github.com/user'),
          headers: githubHeaders(token),
        )
        .timeout(_timeout);
    ghCheck(r, '读取令牌权限');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final login = (j is Map ? (j['login'] as String?) : null) ?? '';
    final raw = r.headers['x-oauth-scopes'];
    final scopes = raw
        ?.split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    return GhTokenInfo(login: login, scopes: scopes);
  } on TimeoutException {
    throw HostingException('连接超时，请检查网络后重试');
  } finally {
    if (client == null) c.close();
  }
}

/// Does the account's provider support the REST import? (used by UI gating)
bool supportsCloudImport(Map<String, Object?> account) =>
    ['github', 'gitlab', 'codeup'].contains(accountProvider(account)) &&
    hostFromUrl(accountHost(account) ?? '') != null;

// ============ GitHub platform API (issues / PRs / releases) ============
//
// Boundary: this layer covers *platform* features the git engine cannot do —
// issues, pull requests, releases, and browsing a repository without
// cloning it. Repo file sync stays with the git engine (clone/fetch/push);
// never route file content through these endpoints for sync purposes.
// MVP is GitHub-only: GitLab/Codeup use numeric project ids and different
// payloads, which deserve their own builders when needed.

final _slugRe = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

/// Validates an `owner/name` slug, returning it trimmed; throws a friendly
/// error otherwise.
String checkGhSlug(String slug) {
  final s = slug.trim();
  if (!_slugRe.hasMatch(s)) {
    throw HostingException(
      'repo 应为 owner/name 形式（如 alice/demo），收到：「$slug」',
    );
  }
  return s;
}

/// Resolves the GitHub `owner/repo` slug, shared by the MCP tools and the UI
/// panel: [explicitRepo] wins when non-empty; otherwise [remotes] is scanned
/// origin-first. Callers map the engine's RemoteInfo into (name:, url:)
/// records so this file stays free of engine imports. Pure function.
String ghSlugPick(
  String explicitRepo,
  List<({String name, String url})> remotes,
) {
  final explicit = explicitRepo.trim();
  if (explicit.isNotEmpty) return checkGhSlug(explicit);
  if (remotes.isEmpty) {
    throw HostingException('该仓库没有远程，请显式指定 repo（owner/name）');
  }
  final url = remotes
      .firstWhere((r) => r.name == 'origin', orElse: () => remotes.first)
      .url;
  final slug = githubSlugFromUrl(url);
  if (slug == null) {
    throw HostingException(
      '远程 $url 不是 GitHub 仓库（平台工具目前仅支持 GitHub）；请显式指定 repo（owner/name）',
    );
  }
  return slug;
}

/// Clips a long text for tool output, appending a truncation marker.
String? clipText(String? s, int max) {
  if (s == null) return null;
  if (s.length <= max) return s;
  return '${s.substring(0, max)}…（已截断，原文 ${s.length} 字符）';
}

// ------------------------- URI builders (pure) -------------------------

Uri ghRepoUri(String slug) =>
    Uri.https('api.github.com', '/repos/${checkGhSlug(slug)}');

/// 远程引用（tag/分支）删除等操作：ref 形如 `tags/v1.0.0` 或 `heads/main`。
Uri ghRefUri(String slug, String ref) =>
    Uri.https('api.github.com', '/repos/${checkGhSlug(slug)}/git/refs/$ref');

/// 按 tag 定位 release（GET，返回含 id 的 release JSON；404=不存在）。
Uri ghReleaseByTagUri(String slug, String tag) => Uri.https(
  'api.github.com',
  '/repos/${checkGhSlug(slug)}/releases/tags/$tag',
);

/// 按 id 操作 release（DELETE 删除等）。
Uri ghReleaseUri(String slug, int id) => Uri.https(
  'api.github.com',
  '/repos/${checkGhSlug(slug)}/releases/$id',
);

Uri ghIssuesUri(
  String slug, {
  int page = 1,
  int perPage = 30,
  String state = 'open',
}) => Uri.https('api.github.com', '/repos/${checkGhSlug(slug)}/issues', {
  'state': state,
  'page': '$page',
  'per_page': '${perPage.clamp(1, 100)}',
});

Uri ghIssueUri(String slug, int number) =>
    Uri.https('api.github.com', '/repos/${checkGhSlug(slug)}/issues/$number');

Uri ghIssueCommentsUri(String slug, int number, {int perPage = 30}) => Uri.https(
  'api.github.com',
  '/repos/${checkGhSlug(slug)}/issues/$number/comments',
  {'per_page': '${perPage.clamp(1, 100)}'},
);

Uri ghPullsUri(
  String slug, {
  int page = 1,
  int perPage = 30,
  String state = 'open',
}) => Uri.https('api.github.com', '/repos/${checkGhSlug(slug)}/pulls', {
  'state': state,
  'page': '$page',
  'per_page': '${perPage.clamp(1, 100)}',
});

Uri ghPullUri(String slug, int number) =>
    Uri.https('api.github.com', '/repos/${checkGhSlug(slug)}/pulls/$number');

Uri ghPullMergeUri(String slug, int number) => Uri.https(
  'api.github.com',
  '/repos/${checkGhSlug(slug)}/pulls/$number/merge',
);

Uri ghReleasesUri(String slug, {int perPage = 10}) => Uri.https(
  'api.github.com',
  '/repos/${checkGhSlug(slug)}/releases',
  {'per_page': '${perPage.clamp(1, 100)}'},
);

Uri ghTreeUri(String slug, String ref, {bool recursive = true}) => Uri.https(
  'api.github.com',
  '/repos/${checkGhSlug(slug)}/git/trees/$ref',
  recursive ? {'recursive': '1'} : null,
);

Uri ghContentUri(String slug, String path, {String ref = 'HEAD'}) {
  final p = path.startsWith('/') ? path.substring(1) : path;
  return Uri.https(
    'api.github.com',
    '/repos/${checkGhSlug(slug)}/contents/$p',
    ref.isEmpty ? null : {'ref': ref},
  );
}

Uri ghSearchReposUri(String query, {int perPage = 20}) => Uri.https(
  'api.github.com',
  '/search/repositories',
  {'q': query, 'per_page': '${perPage.clamp(1, 100)}'},
);

// ------------------------ body builders (pure) ------------------------

String ghIssueCreateBody(
  String title, {
  String? body,
  List<String> labels = const [],
}) => jsonEncode({
  'title': title,
  if (body != null && body.isNotEmpty) 'body': body,
  if (labels.isNotEmpty) 'labels': labels,
});

String ghIssuePatchBody({String? title, String? body, String? state}) {
  final j = <String, Object?>{'title': ?title, 'body': ?body, 'state': ?state};
  if (j.isEmpty) throw HostingException('没有要修改的字段');
  return jsonEncode(j);
}

String ghPrPatchBody({String? title, String? body, String? state}) {
  final j = <String, Object?>{'title': ?title, 'body': ?body, 'state': ?state};
  if (j.isEmpty) throw HostingException('没有要修改的字段');
  return jsonEncode(j);
}

String ghCommentBody(String text) => jsonEncode({'body': text});

String ghPrMergeBody({
  String method = 'merge',
  String? commitTitle,
  String? sha,
}) {
  const methods = {'merge', 'squash', 'rebase'};
  if (!methods.contains(method)) {
    throw HostingException('合并方式仅支持 merge / squash / rebase，收到：$method');
  }
  return jsonEncode({
    'merge_method': method,
    if (commitTitle != null && commitTitle.isNotEmpty) 'commit_title': commitTitle,
    if (sha != null && sha.isNotEmpty) 'sha': sha,
  });
}

// ---------------------- response parsers (pure) ----------------------

/// GitHub issue list/detail item → compact map. Returns null for PR entries
/// (`GET /issues` also returns pull requests) unless
/// [includePullRequests]; null for malformed payloads.
Map<String, Object?>? parseGhIssue(
  Map<String, dynamic> j, {
  bool includePullRequests = false,
}) {
  final isPr = j['pull_request'] != null;
  if (isPr && !includePullRequests) return null;
  final n = j['number'];
  final title = j['title'];
  if (n is! num || title is! String) return null;
  return {
    'number': n.toInt(),
    'title': title,
    'isPr': isPr,
    'state': j['state'] as String?,
    'author': (j['user'] as Map?)?['login'] as String?,
    'labels': [
      for (final l in (j['labels'] as List? ?? <Object?>[]))
        if (l is Map) l['name'],
    ],
    'createdAt': j['created_at'] as String?,
    'updatedAt': j['updated_at'] as String?,
    'commentCount': j['comments'] is num ? (j['comments'] as num).toInt() : null,
    'url': j['html_url'] as String?,
    'body': clipText(j['body'] as String?, 2048),
  };
}

List<Map<String, Object?>> parseGhIssues(String body) => [
  for (final x in (jsonDecode(body) as List))
    if (x is Map) ?parseGhIssue(Map<String, dynamic>.from(x)),
];

Map<String, Object?>? parseGhComment(Map<String, dynamic> j) {
  final id = j['id'];
  if (id is! num) return null;
  return {
    'id': id.toInt(),
    'author': (j['user'] as Map?)?['login'] as String?,
    'createdAt': j['created_at'] as String?,
    'body': clipText(j['body'] as String?, 4096),
  };
}

List<Map<String, Object?>> parseGhComments(String body) => [
  for (final x in (jsonDecode(body) as List))
    if (x is Map) ?parseGhComment(Map<String, dynamic>.from(x)),
];

/// GitHub PR list/detail item → compact map. Null for malformed payloads.
Map<String, Object?>? parseGhPr(Map<String, dynamic> j) {
  final n = j['number'];
  final title = j['title'];
  if (n is! num || title is! String) return null;
  final head = j['head'] as Map?;
  final base = j['base'] as Map?;
  return {
    'number': n.toInt(),
    'title': title,
    'state': j['state'] as String?,
    'draft': (j['draft'] ?? false) as bool,
    'merged': (j['merged'] ?? false) as bool,
    'author': (j['user'] as Map?)?['login'] as String?,
    'headRef': head?['ref'] as String?,
    'headSha': head?['sha'] as String?,
    'baseRef': base?['ref'] as String?,
    'mergeable': j['mergeable'], // true / false / null(服务端仍在计算)
    'changedFiles': j['changed_files'] is num
        ? (j['changed_files'] as num).toInt()
        : null,
    'additions': j['additions'] is num ? (j['additions'] as num).toInt() : null,
    'deletions': j['deletions'] is num ? (j['deletions'] as num).toInt() : null,
    'createdAt': j['created_at'] as String?,
    'updatedAt': j['updated_at'] as String?,
    'url': j['html_url'] as String?,
    'body': clipText(j['body'] as String?, 2048),
  };
}

List<Map<String, Object?>> parseGhPrs(String body) => [
  for (final x in (jsonDecode(body) as List))
    if (x is Map) ?parseGhPr(Map<String, dynamic>.from(x)),
];

Map<String, Object?>? parseGhRelease(Map<String, dynamic> j) {
  final tag = j['tag_name'] as String?;
  if (tag == null || tag.isEmpty) return null;
  return {
    'tagName': tag,
    'name': j['name'] as String?,
    'prerelease': (j['prerelease'] ?? false) as bool,
    'publishedAt': j['published_at'] as String?,
    'author': (j['author'] as Map?)?['login'] as String?,
    'url': j['html_url'] as String?,
    'assets': [
      for (final a in (j['assets'] as List? ?? <Object?>[]))
        if (a is Map)
          {
            'name': a['name'],
            'size': a['size'] is num ? (a['size'] as num).toInt() : null,
            'downloadUrl': a['browser_download_url'],
          },
    ],
    'body': clipText(j['body'] as String?, 2048),
  };
}

List<Map<String, Object?>> parseGhReleases(String body) => [
  for (final x in (jsonDecode(body) as List))
    if (x is Map) ?parseGhRelease(Map<String, dynamic>.from(x)),
];

/// Tree listing → compact entries. [maxEntries] caps client memory; both the
/// GitHub `truncated` flag (server cut) and the client overflow count are
/// surfaced so callers can warn about incomplete results.
Map<String, Object?> parseGhTree(String body, {int maxEntries = 500}) {
  final j = jsonDecode(body);
  if (j is! Map) throw HostingException('树响应无法解析');
  final entries = <Map<String, Object?>>[];
  var overflow = 0;
  for (final e in (j['tree'] as List? ?? <Object?>[])) {
    if (e is! Map) continue;
    if (entries.length >= maxEntries) {
      overflow++;
      continue;
    }
    entries.add({
      'path': e['path'] as String?,
      'type': e['type'] as String?, // blob | tree | commit(子模块)
      'size': e['size'] is num ? (e['size'] as num).toInt() : null,
    });
  }
  return {
    'sha': j['sha'] as String?,
    'serverTruncated': (j['truncated'] ?? false) as bool,
    'entryCount': entries.length,
    'clientOverflow': overflow,
    'entries': entries,
  };
}

/// Contents API file → text. Files >1MB arrive without inline content
/// (encoding "none"); callers should fall back to the git engine for those.
/// Binary detection: a decoded NUL byte marks the file as binary.
Map<String, Object?>? parseGhFileContent(String body, {int maxTextChars = 16384}) {
  final j = jsonDecode(body);
  if (j is List) {
    throw HostingException('该路径是目录，请用 gh_tree_list 浏览');
  }
  if (j is! Map) return null;
  final content = (j['content'] as String?) ?? '';
  final encoding = (j['encoding'] as String?) ?? 'none';
  String? text;
  var textTruncated = false;
  var binary = false;
  if (encoding == 'base64' && content.isNotEmpty) {
    final raw = utf8.decode(
      base64.decode(content.replaceAll('\n', '')),
      allowMalformed: true,
    );
    if (raw.contains('\u0000')) {
      binary = true;
    } else if (raw.length <= maxTextChars) {
      text = raw;
    } else {
      text = raw.substring(0, maxTextChars);
      textTruncated = true;
    }
  }
  return {
    'name': j['name'] as String?,
    'path': j['path'] as String?,
    'size': j['size'] is num ? (j['size'] as num).toInt() : null,
    'binary': binary,
    'tooLargeForInline': encoding != 'base64' || content.isEmpty,
    'text': text,
    'textTruncated': textTruncated,
    'htmlUrl': j['html_url'] as String?,
  };
}

Map<String, Object?>? parseGhSearch(String body) {
  final j = jsonDecode(body);
  if (j is! Map) return null;
  return {
    'totalCount': j['total_count'] is num
        ? (j['total_count'] as num).toInt()
        : null,
    'items': [
      for (final x in (j['items'] as List? ?? <Object?>[]))
        if (x is Map)
          {
            'fullName': x['full_name'],
            'description': clipText(x['description'] as String?, 256),
            'stars': x['stargazers_count'] is num
                ? (x['stargazers_count'] as num).toInt()
                : null,
            'defaultBranch': x['default_branch'],
            'updatedAt': x['updated_at'],
          },
    ],
  };
}

Map<String, Object?>? parseGhRepoDetail(Map<String, dynamic> j) {
  final full = j['full_name'] as String?;
  if (full == null || full.isEmpty) return null;
  return {
    'fullName': full,
    'description': clipText(j['description'] as String?, 512),
    'private': (j['private'] ?? false) as bool,
    'fork': (j['fork'] ?? false) as bool,
    'defaultBranch': j['default_branch'] as String?,
    'stars': j['stargazers_count'] is num
        ? (j['stargazers_count'] as num).toInt()
        : null,
    'forks': j['forks_count'] is num ? (j['forks_count'] as num).toInt() : null,
    'openIssues': j['open_issues_count'] is num
        ? (j['open_issues_count'] as num).toInt()
        : null,
    'updatedAt': j['updated_at'] as String?,
    // pushed_at 才是「最后一次推送落地」的时间：updated_at 会被 star、
    // 改描述、开 issue 等一堆无关动作刷新，拿它判断「推送有没有上去」会误判。
    // （本轮破案时正是靠 pushed_at 与 updatedAt 一起定性。）
    'pushedAt': j['pushed_at'] as String?,
    'createdAt': j['created_at'] as String?,
    'size': j['size'] is num ? (j['size'] as num).toInt() : null,
    'httpsUrl': j['clone_url'] as String?,
    'sshUrl': j['ssh_url'] as String?,
  };
}

// --------------------------- request layer ---------------------------

/// Status mapping, split from [ghRequest] so tests can feed canned responses.
void ghCheck(http.Response r, String what) {
  final code = r.statusCode;
  if (code >= 200 && code < 300) return;
  var detail = '';
  try {
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is Map) detail = (j['message'] as String?) ?? '';
  } catch (_) {}
  switch (code) {
    case 401:
      throw HostingException('GitHub 令牌无效或已过期，请到「设置 → 账号管理」重新授权');
    case 403:
    case 429:
      if (r.headers['x-ratelimit-remaining'] == '0') {
        final reset = int.tryParse(r.headers['x-ratelimit-reset'] ?? '');
        final at = reset == null
            ? '稍后'
            : DateTime.fromMillisecondsSinceEpoch(
                reset * 1000,
              ).toIso8601String();
        throw HostingException('GitHub API 速率已达上限，重置于 $at（UTC）');
      }
      throw HostingException('GitHub 拒绝了请求（HTTP $code）${detail.isEmpty ? '' : '：$detail'}');
    case 404:
      throw HostingException(
        '未找到（HTTP 404）：仓库/条目不存在、无权限或路径有误'
        '${detail.isEmpty ? '' : ' — $detail'}',
      );
    case 405:
      throw HostingException('无法合并该 PR（HTTP 405）${detail.isEmpty ? '' : '：$detail'}');
    case 409:
      // 空仓库也是 409：message = "Git Repository is empty."。旧实现一律报成
      // 「合并冲突」，于是首次推送前的仓库浏览会被彻底误导 —— v1.5.24 实测
      // 撞上过（gh_tree_list 对一个刚建的空仓库返回 409）。
      if (detail.toLowerCase().contains('empty')) {
        throw HostingException(
          '远端仓库还是空的（GitHub：$detail）——先成功推送一次，这里才有内容',
        );
      }
      throw HostingException('合并冲突或状态已变化（HTTP 409）${detail.isEmpty ? '' : '：$detail'}');
    case 422:
      throw HostingException('GitHub 校验未通过（HTTP 422）${detail.isEmpty ? '' : '：$detail'}');
    default:
      var short = detail.isEmpty ? utf8.decode(r.bodyBytes) : detail;
      if (short.length > 160) short = short.substring(0, 160);
      throw HostingException('$what 失败：HTTP $code $short');
  }
}

/// Unified GitHub REST call with friendly error mapping. Returns the decoded
/// UTF-8 body ('' for empty responses like a merge without content).
Future<String> ghRequest(
  String method,
  Uri uri, {
  required String token,
  String? body,
  Map<String, String>? extraHeaders,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final headers = {...githubHeaders(token), ...?extraHeaders};
    final r = await switch (method.toUpperCase()) {
      'GET' => c.get(uri, headers: headers),
      'POST' => c.post(uri, headers: headers, body: body ?? ''),
      'PATCH' => c.patch(uri, headers: headers, body: body ?? ''),
      'PUT' => c.put(uri, headers: headers, body: body ?? ''),
      'DELETE' => c.delete(uri, headers: headers),
      _ => throw HostingException('不支持的 HTTP 方法：$method'),
    }.timeout(_timeout);
    ghCheck(r, uri.path);
    return utf8.decode(r.bodyBytes);
  } on TimeoutException {
    throw HostingException('连接超时，请检查网络后重试');
  } finally {
    if (client == null) c.close();
  }
}
