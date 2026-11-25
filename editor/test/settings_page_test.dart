import 'dart:io';

import 'package:android_watch_editor/models/app_config.dart';
import 'package:android_watch_editor/services/bundled_tools.dart';
import 'package:android_watch_editor/services/config_store.dart';
import 'package:android_watch_editor/ui/app_controller.dart';
import 'package:android_watch_editor/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  testWidgets('设置页：选 Anthropic 预设并保存，格式、地址、模型一致', (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = tempDir('awe_set');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = AppController(
      runner: FakeRunner(devicesOutput: 'List of devices attached\r\n'),
      httpClient: MockClient((r) async => http.Response('', 500)),
      configStore: ConfigStore(Directory('${dir.path}/config')),
      assets: MapAssetReader({'assets/prompts/system_prompt.md': '# t'}),
      paths: AppPaths(dir.path),
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(c.dispose);
    await tester.runAsync(c.init);
    await tester.pumpWidget(MaterialApp(home: SettingsPage(controller: c)));
    await tester.pump();
    expect(find.text('完全权限'), findsOneWidget);
    expect(find.text('每次询问'), findsOneWidget);

    await tester.tap(find.text('Anthropic Claude'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'API Key'), 'sk-ant');
    await tester.tap(find.text('完全权限'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('保存'));
      await tester.pump();
      final f = File('${dir.path}/config/config.json');
      for (
        var i = 0;
        i < 200 && !(f.existsSync() && f.readAsStringSync().contains('sk-ant'));
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(c.config.apiFormat, ApiFormat.anthropic);
    expect(c.config.baseUrl, 'https://api.anthropic.com');
    expect(c.config.model, 'claude-sonnet-4-5');
    expect(c.config.vision, isTrue);
    expect(c.config.apiKey, 'sk-ant');
    expect(c.config.permission, PermissionMode.full);
    expect(
      File('${dir.path}/config/config.json').readAsStringSync(),
      contains('"apiFormat": "anthropic"'),
    );
  });
}
