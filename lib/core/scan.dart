import 'dart:io';

import 'package:path/path.dart' as p;

/// Recursively scans well-known storage roots for git repositories.
///
/// Runs inside an isolate (caller wraps with [Isolate.run]) so large trees
/// never block the UI. Depth-limited, skips media/system noise, and stops
/// descending into a discovered repository (its subdirs are not projects).
class RepoScanner {
  RepoScanner._();

  /// Directory names never descended into (system/media/build noise).
  static const _skipNames = <String>{
    'Android',
    'DCIM',
    'Movies',
    'Music',
    'Notifications',
    'Pictures',
    'Recordings',
    'Ringtones',
    'Alarms',
    'Podcasts',
    'MIUI',
    'tencent',
    'download',
    'browser',
    'backups',
    'cache',
    'data',
    'obb',
    'node_modules',
    'build',
    '.gradle',
    '.dart_tool',
    '.idea',
    '.vscode',
    '.recycle',
    '.thumbnails',
    '.cache',
    '.config',
  };

  /// Depth limit relative to each root.
  static const _maxDepth = 4;

  /// Scan the given roots (resolved on the main isolate via
  /// PlatformPaths.scanRoots — path_provider's platform channel cannot be
  /// reached from a background isolate). Returns repo workdir paths
  /// (deduped, sorted). `[missing]` roots are silently skipped.
  static Future<List<String>> scanAll(List<String> roots) async {
    final found = <String>{};
    for (final root in roots) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      await _scanDir(dir, 0, found);
    }
    final out = found.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
  }

  static Future<void> _scanDir(
    Directory dir,
    int depth,
    Set<String> found,
  ) async {
    if (depth > _maxDepth) return;
    final Iterable<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return; // unreadable subtree → skip silently
    }
    for (final e in entries) {
      if (e is! Directory) continue;
      final name = p.basename(e.path);
      if (name == '.git') {
        // `dir` itself is a repository workdir.
        found.add(dir.path);
        return; // don't descend into a repo's internals
      }
      if (name.startsWith('.') || _skipNames.contains(name.toLowerCase())) {
        continue;
      }
      await _scanDir(e, depth + 1, found);
    }
  }

  /// Human-friendly relative time for a unix timestamp.
  static String relTime(int unixSec, DateTime now) {
    if (unixSec <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    final d = now.difference(t);
    if (d.inSeconds < 60) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${t.month}/${t.day}';
  }
}
