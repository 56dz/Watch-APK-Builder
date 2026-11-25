import 'dart:io';

import 'package:android_watch_editor/models/app_config.dart';
import 'package:android_watch_editor/services/config_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  test('配置默认值、保存与读取；toString 不含 API Key', () async {
    final dir = tempDir('awe_cfg');
    addTearDown(() => dir.deleteSync(recursive: true));
    final defaults = AppConfig.defaults(defaultWorkspace: r'D:\app\workspace');
    expect(defaults.apiFormat, ApiFormat.openai);
    expect(defaults.baseUrl, 'https://api.deepseek.com');
    expect(defaults.model, 'deepseek-chat');
    expect(defaults.permission, PermissionMode.ask);
    expect(defaults.askPermission, isTrue);
    expect(defaults.defaultWorkspace, r'D:\app\workspace');
    expect(defaults.maxSteps, 40);

    final store = ConfigStore(dir);
    expect((await store.load(defaults)).apiKey, '');
    await store.save(
      defaults.copyWith(
        apiFormat: ApiFormat.anthropic,
        apiKey: 'sk-123',
        model: 'claude-sonnet-4-5',
        vision: true,
        permission: PermissionMode.full,
        workspaces: [r'D:\app\workspace', r'E:\watch'],
        projects: [r'E:\watch\demo'],
      ),
    );
    final back = await store.load(defaults);
    expect(back.apiFormat, ApiFormat.anthropic);
    expect(back.apiKey, 'sk-123');
    expect(back.model, 'claude-sonnet-4-5');
    expect(back.vision, isTrue);
    expect(back.permission, PermissionMode.full);
    expect(back.askPermission, isFalse);
    expect(back.workspaces, [r'D:\app\workspace', r'E:\watch']);
    expect(back.projects, [r'E:\watch\demo']);
    expect(back.toString(), isNot(contains('sk-123')));

    File('${dir.path}/config.json').writeAsStringSync('{broken');
    expect((await store.load(defaults)).apiKey, '');
  });

  test('预设包含 OpenAI 格式和 Anthropic 格式', () {
    expect(AppConfig.presets.map((p) => p.format).toSet(), {
      ApiFormat.openai,
      ApiFormat.anthropic,
    });
    expect(ApiFormat.fromId('anthropic'), ApiFormat.anthropic);
    expect(ApiFormat.fromId('??'), ApiFormat.openai);
    expect(PermissionMode.fromId('full'), PermissionMode.full);
    expect(PermissionMode.fromId(null), PermissionMode.ask);
  });
}
