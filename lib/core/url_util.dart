/// Pure URL helpers shared by Prefs account matching, the hosting APIs and
/// the MCP tools. No Flutter / IO imports — fully unit-testable.
library;

/// Best-effort host extraction from a remote URL.
///
/// Accepts https://host/..., ssh://git@host:port/..., git@host:path (SCP
/// style) and bare `host:path`. Returns lowercase host or null.
String? hostFromUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return null;
  var rest = raw;
  // Strip scheme.
  final schemeIdx = rest.indexOf('://');
  if (schemeIdx >= 0) {
    rest = rest.substring(schemeIdx + 3);
  }
  // Strip userinfo (git@host:...).
  final at = rest.indexOf('@');
  if (at >= 0 && at < rest.indexOf('/').clamp(0, rest.length)) {
    rest = rest.substring(at + 1);
  }
  // Host is up to '/', ':' or end.
  final end = rest.indexOf(RegExp(r'[/,:]'));
  final host = (end >= 0 ? rest.substring(0, end) : rest).trim();
  if (host.isEmpty || host.contains(RegExp(r'\s'))) return null;
  return host.toLowerCase();
}

/// Default hosting host for a provider (null = must be provided / unknown).
String? defaultHostFor(String provider) => switch (provider) {
  'github' => 'github.com',
  'codeup' => 'codeup.aliyun.com',
  'gitlab' => 'gitlab.com',
  _ => null,
};

/// Extract the `owner/repo` slug from a GitHub remote URL, or null when the
/// URL does not point at github.com or has no two path segments.
///
/// Accepts `https://github.com/o/r(.git)`, `git@github.com:o/r(.git)`,
/// `ssh://git@github.com/o/r(.git)` and bare `github.com:o/r`. Pure function.
String? githubSlugFromUrl(String url) {
  final host = hostFromUrl(url);
  if (host != 'github.com') return null;
  var rest = url.trim();
  final schemeIdx = rest.indexOf('://');
  if (schemeIdx >= 0) rest = rest.substring(schemeIdx + 3);
  final at = rest.indexOf('@');
  if (at >= 0) rest = rest.substring(at + 1);
  if (!rest.toLowerCase().startsWith('github.com')) return null;
  rest = rest.substring('github.com'.length);
  if (rest.startsWith(':') || rest.startsWith('/')) rest = rest.substring(1);
  rest = rest.replaceFirst(RegExp(r'\.git$', caseSensitive: false), '');
  final parts = rest.split('/').where((s) => s.isNotEmpty).toList();
  if (parts.length < 2) return null;
  final owner = parts[0];
  final repo = parts[1];
  if (owner.isEmpty || repo.isEmpty) return null;
  if (owner.contains(RegExp(r'\s')) || repo.contains(RegExp(r'\s'))) {
    return null;
  }
  return '$owner/$repo';
}
