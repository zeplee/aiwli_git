import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aiwli_git/core/prefs.dart';
import 'package:aiwli_git/engine/ffi.dart' as engine;
import 'package:aiwli_git/ui/app_shell.dart';
import 'package:aiwli_git/ui/theme.dart';
import 'package:aiwli_git/widgets/dialogs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AiwlApp());
}

class AiwlApp extends StatefulWidget {
  const AiwlApp({super.key});
  @override
  State<AiwlApp> createState() => _AiwlAppState();
}

class _AiwlAppState extends State<AiwlApp> {
  String? _repo;
  ThemeMode _themeMode = ThemeMode.system;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  /// Boot sequence (widget initState = engine fully attached, MethodChannel
  /// calls reach the Android side):
  /// 1. Point prefs at the app files dir — code_cache is NOT used because
  ///    MIUI wipes it (prefs silently disappeared in the field).
  /// 2. Hand the same dir to the Rust side so it can materialise the Android
  ///    system CA bundle and load it via `set_ssl_cert_file`, then apply the
  ///    TLS-skip escape hatch (default off). Both must precede any remote op.
  /// 3. Load theme mode.
  /// 4. Restore the last repo after validating it still opens.
  Future<void> _boot() async {
    String? appDir;
    try {
      appDir = await const MethodChannel('gitdeck/sys')
          .invokeMethod<String>('appFilesDir');
    } catch (_) {
      appDir = null;
    }
    Prefs.instance.setDir(appDir); // fallback: systemTemp (+ parent created)

    // 信任库必须在任何远程操作前就位：Rust 侧把 Android 系统 CA 拼成 PEM
    // bundle 写进 app 私有目录，再用 set_ssl_cert_file 加载。
    // 不能把 CA **目录**交给 libgit2（set_ssl_cert_dir）：Android 的文件名是
    // MD5(subject)，而 OpenSSL 3.x 的哈希目录查找器按 SHA1 查找，永远命不中，
    // 且因为查找是惰性的还会返回成功（静默失效）—— 详见 docs/13。
    // 失败不阻塞启动：设置页 →「网络安全」会显示诊断。
    try {
      if (appDir != null && appDir.isNotEmpty) {
        await engine.setCaDir(appDir);
      }
      await engine.setSkipTlsVerify(await Prefs.instance.skipTlsVerify());
    } catch (_) {}

    final themeName = await Prefs.instance.themeModeName();

    String? repo;
    final last = await Prefs.instance.lastRepo();
    if (last != null && last.isNotEmpty) {
      try {
        await engine.openRepo(path: last);
        repo = last;
      } catch (e) {
        // 文件夹可能被移动、卸载或删除；但「存储权限缺失」时目录本身没问题，
        // 不能顺手把「上次仓库」也清掉——授权后应能直接回到这个仓库。
        if (isStorageDeniedError(e)) {
          repo = last; // 保留记忆，工作台会显示授权引导
        } else {
          await Prefs.instance.setLastRepo('');
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _themeMode = _modeFrom(themeName);
      _repo = repo;
      _ready = true;
    });
  }

  static ThemeMode _modeFrom(String name) => switch (name) {
    'dark' => ThemeMode.dark,
    'light' => ThemeMode.light,
    _ => ThemeMode.system,
  };

  Future<void> _setThemeMode(String name) async {
    await Prefs.instance.setThemeModeName(name);
    if (!mounted) return;
    setState(() => _themeMode = _modeFrom(name));
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return _app(
        const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    return _app(AppShell(initialRepo: _repo, onThemeChanged: _setThemeMode));
  }

  /// Material You: wallpaper-derived dynamic schemes on Android 12+;
  /// static graphite/azure fallback when unavailable (lightDyn/darkDyn null).
  Widget _app(Widget home) {
    return DynamicColorBuilder(
      builder: (lightDyn, darkDyn) => MaterialApp(
        title: 'AiwliGit',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(lightDyn),
        darkTheme: AppTheme.dark(darkDyn),
        themeMode: _ready ? _themeMode : ThemeMode.system,
        home: home,
      ),
    );
  }
}
