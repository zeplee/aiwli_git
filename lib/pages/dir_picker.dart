import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/platform_paths.dart';
import '../engine/ffi.dart';
import '../widgets/dialogs.dart';

/// 「选择本地仓库」目录选择（全平台一个 API）。
///
/// file_picker 五端通用（Android SAF / iOS UIDocumentPicker /
/// Windows IFileDialog / macOS NSOpenPanel / Linux GTK），不再维护自研
/// 目录浏览器——此前浏览器起点硬编码 /storage/emulated/0，桌面端打开即
/// 「无法读取」；原生对话框还自带最近位置、搜索与权限处理。
///
/// 选中非 Git 目录时弹窗确认后 git init 收编（原 DirPickerSheet 的行为，
/// 逻辑移到这里）。返回仓库根路径；用户取消返回 null。
Future<String?> showDirPicker(BuildContext context) async {
  final path = await FilePicker.getDirectoryPath(
    dialogTitle: '选择本地仓库（普通文件夹将初始化为 Git 仓库）',
    initialDirectory: PlatformPaths.pickerRoot,
  );
  if (path == null || path.isEmpty) return null;
  if (!context.mounted) return path;
  final isRepo =
      FileSystemEntity.typeSync('$path/.git') !=
      FileSystemEntityType.notFound;
  if (isRepo) return path;
  final ok = await confirmDialog(
    context,
    '初始化 Git 仓库？',
    '「$path」还不是 Git 仓库。\n\n'
        '初始化不会改动里面的文件：只创建 .git，'
        '现有文件会显示为未跟踪，由你决定何时提交。',
    action: '初始化并打开',
  );
  if (!ok || !context.mounted) return null;
  try {
    await initRepo(path: path);
    return path;
  } catch (e) {
    if (context.mounted) showSnack(context, friendlyError(e), error: true);
    return null;
  }
}
