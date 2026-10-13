import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 跨平台默认位置（1.5.26：桌面端文件管理修复）。
///
/// 目录定位走 path_provider（Documents/Downloads 读系统 Known Folder API，
/// Windows 本地化/重定向目录也正确）；路径运算直接用 package:path（默认
/// context 即当前平台 style，Windows 反斜杠/盘符/大小写不敏感全处理）。
///
/// 唯一保留的平台分支是 Android 的共享存储根：那是 scoped storage 模型
/// 本身的约定（path_provider 在 Android 上返回的是应用私有目录，拿不到
/// 共享存储），不是库的能力缺口。
class PlatformPaths {
  PlatformPaths._();

  /// Android 共享存储根（git FFI 需要真实路径的约定位置）。
  static const androidStorageRoot = '/storage/emulated/0';

  /// 用户主目录（Windows = %USERPROFILE%，POSIX = $HOME）。
  static String get home {
    final env = Platform.environment;
    return env['USERPROFILE'] ??
        env['HOME'] ??
        (Platform.isWindows ? r'C:\Users\Public' : '/');
  }

  /// 扫描根（缺失的由扫描器静默跳过）。
  ///
  /// 必须在主 isolate 调用（path_provider 的平台通道不能进后台 isolate），
  /// 结果作为参数传入扫描 isolate。
  static Future<List<String>> scanRoots() async {
    if (Platform.isAndroid) {
      return const [
        '$androidStorageRoot/Projects',
        '$androidStorageRoot/Documents',
        '$androidStorageRoot/Download',
        androidStorageRoot,
      ];
    }
    final roots = <String>[home];
    for (final d in await Future.wait([
      _safe(getApplicationDocumentsDirectory),
      _safe(getDownloadsDirectory),
    ])) {
      if (d != null && !roots.contains(d.path)) roots.add(d.path);
    }
    final projects = p.join(home, 'Projects');
    if (Directory(projects).existsSync()) roots.add(projects);
    return roots;
  }

  /// 目录选择的起始位置（file_picker 的 initialDirectory）。
  static String get pickerRoot =>
      Platform.isAndroid ? androidStorageRoot : home;

  /// 克隆/新建仓库的默认父目录。
  static Future<String> projectsDir() async {
    if (Platform.isAndroid) return '$androidStorageRoot/Projects';
    final cand = p.join(home, 'Projects');
    return Directory(cand).existsSync() ? cand : home;
  }

  static Future<Directory?> _safe(Future<Directory?> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }
}
