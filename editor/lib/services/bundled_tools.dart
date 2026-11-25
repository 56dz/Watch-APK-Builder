import 'dart:io';

import 'package:path/path.dart' as p;

/// 便携版目录布局：所有依赖和数据都在软件根目录（exe 所在目录）下。
///
///   <根目录>/android_watch_editor.exe
///   <根目录>/tools/android-sdk/platform-tools/adb.exe
///   <根目录>/tools/android-sdk/build-tools/33.0.2/...
///   <根目录>/tools/android-sdk/platforms/android-33/android.jar
///   <根目录>/tools/jdk/bin/java.exe
///   <根目录>/tools/python/python.exe
///   <根目录>/tools/git/bin/bash.exe
///   <根目录>/tools/r8.jar
///   <根目录>/skills/<名称>/SKILL.md      skill 目录（可自行增删）
///   <根目录>/config/config.json          设置（含 API Key）
///   <根目录>/config/devices.json         手表型号档案
///   <根目录>/data/                       Flutter 自身的运行资源（不要放别的东西）
///   <根目录>/workspace/                  默认工作区
class AppPaths {
  final String root;
  const AppPaths(this.root);

  /// 以 exe 所在目录为根目录。
  factory AppPaths.locate([String? exePath]) =>
      AppPaths(p.dirname(exePath ?? Platform.resolvedExecutable));

  String get tools => p.join(root, 'tools');
  String get skills => p.join(root, 'skills');
  String get data => p.join(root, 'config');
  String get workspace => p.join(root, 'workspace');

  String get adb => p.join(tools, 'android-sdk', 'platform-tools', 'adb.exe');
  String get sdk => p.join(tools, 'android-sdk');
  String get jdk => p.join(tools, 'jdk');
  String get python => p.join(tools, 'python', 'python.exe');
  String get bash => p.join(tools, 'git', 'bin', 'bash.exe');
  String get r8 => p.join(tools, 'r8.jar');

  /// 自带工具缺失的项（用于启动时提示）。
  List<String> missingTools() => [
    if (!File(adb).existsSync()) 'adb',
    if (!Directory(sdk).existsSync()) 'android-sdk',
    if (!Directory(jdk).existsSync()) 'jdk',
    if (!File(python).existsSync()) 'python',
    if (!File(bash).existsSync()) 'git-bash',
    if (!File(r8).existsSync()) 'r8.jar',
  ];
}

/// 自带工具存在时用自带的，否则退回 [fallback]（如 PATH 中的 "adb"）。
String toolOr(String bundled, String fallback, {bool directory = false}) {
  final ok = directory
      ? Directory(bundled).existsSync()
      : File(bundled).existsSync();
  return ok ? bundled : fallback;
}
