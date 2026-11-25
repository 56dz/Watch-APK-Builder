import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'services/bundled_tools.dart';
import 'services/config_store.dart';
import 'services/process_runner.dart';
import 'ui/app_controller.dart';
import 'ui/glass.dart';
import 'ui/home_page.dart';

const appTitle = '安卓手表软件编辑器';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 便携版：工具、skill、设置和默认工作区都在 exe 所在目录。
  final paths = AppPaths.locate();
  final controller = AppController(
    runner: const IoProcessRunner(),
    httpClient: http.Client(),
    configStore: ConfigStore(Directory(paths.data)),
    assets: BundleAssetReader(),
    environment: Platform.environment,
    paths: paths,
  );
  controller.init();
  runApp(WatchEditorApp(controller: controller));
}

class WatchEditorApp extends StatelessWidget {
  final AppController controller;
  const WatchEditorApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      theme: glassTheme(),
      // 每个页面（含设置页）都铺上同一张渐变背景，玻璃面板叠在上面。
      builder: (context, child) =>
          AppBackdrop(child: child ?? const SizedBox()),
      home: HomePage(controller: controller),
    );
  }
}
