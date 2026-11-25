import 'package:android_watch_editor/main.dart';

import 'dart:convert';
import 'dart:io';

import 'package:android_watch_editor/services/bundled_tools.dart';
import 'package:android_watch_editor/services/config_store.dart';
import 'package:android_watch_editor/models/chat_message.dart';
import 'package:android_watch_editor/ui/app_controller.dart';
import 'package:android_watch_editor/ui/message_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  testWidgets('主界面显示中文标题、设备档案和空项目提示', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = tempDir('awe_ui');
    addTearDown(() => dir.deleteSync(recursive: true));
    final runner = FakeRunner(
      shellOutputs: oww251,
      devicesOutput: 'List of devices attached\r\n8b47f1c1 device product:OWW251 model:OWW251 transport_id:1\r\n',
    );
    final c = AppController(
      runner: runner,
      httpClient: MockClient((r) async => http.Response('', 500)),
      configStore: ConfigStore(Directory('${dir.path}/data')),
      assets: MapAssetReader({
        'assets/prompts/system_prompt.md': '# 测试',
        'assets/skills/oppo-watch2-apk/SKILL.md':
            '---\nname: oppo-watch2-apk\ndescription: d\n---\n',
      }),
      paths: AppPaths(dir.path),
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await c.init(); // init 会自动刷新设备并选中唯一在线设备
      for (var i = 0; i < 100 && c.profile == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpWidget(WatchEditorApp(controller: c));
    await tester.pump();
    expect(find.text('安卓手表软件编辑器'), findsOneWidget);
    expect(find.text('新建项目'), findsOneWidget);
    expect(find.text('466 x 466 px'), findsOneWidget);
    expect(find.text('圆屏'), findsOneWidget);
    expect(find.text('未设置 API Key'), findsOneWidget);
  });

  testWidgets('打开项目后输入框、总结经验和发送按钮都能正常布局', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = tempDir('awe_ui2');
    addTearDown(() => dir.deleteSync(recursive: true));
    final proj = Directory('${dir.path}/proj')..createSync();
    final c = AppController(
      runner: FakeRunner(),
      httpClient: MockClient((r) async => http.Response('', 500)),
      configStore: ConfigStore(Directory('${dir.path}/data')),
      assets: MapAssetReader({'assets/prompts/system_prompt.md': '# 测试'}),
      paths: AppPaths(dir.path),
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await c.init();
      await c.openProject(proj.path);
    });
    await tester.pumpWidget(WatchEditorApp(controller: c));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('总结经验'), findsOneWidget);
    expect(find.text('发送'), findsOneWidget);
    final send = tester.getRect(find.text('发送'));
    final sum = tester.getRect(find.text('总结经验'));
    expect(sum.bottom, lessThan(send.top));
  });

  testWidgets('打开已有项目停在对话末尾；工具框默认收起，滚出视口后自动收起', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = tempDir('awe_ui3');
    addTearDown(() => dir.deleteSync(recursive: true));
    final proj = Directory('${dir.path}/proj')..createSync();
    final img = File('${dir.path}/shot.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        ),
      );
    final c = AppController(
      runner: FakeRunner(),
      httpClient: MockClient((r) async => http.Response('', 500)),
      configStore: ConfigStore(Directory('${dir.path}/data')),
      assets: MapAssetReader({'assets/prompts/system_prompt.md': '# 测试'}),
      paths: AppPaths(dir.path),
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await c.init();
      await c.openProject(proj.path);
    });
    for (var i = 0; i < 40; i++) {
      c.session.messages.add(ChatMessage.user('第 $i 条需求'));
      c.session.messages.add(
        ChatMessage(
          role: 'tool',
          toolName: 'adb',
          content: '结果详情 $i\n${'行\n' * 30}',
          images: [img.path],
        ),
      );
    }
    // 最后一轮很长，滚到这一轮顶部时末尾的展开框才会离开视口
    for (var k = 0; k < 30; k++) {
      c.session.messages.add(
        ChatMessage(role: 'tool', toolName: 'list_files', content: '其他 $k'),
      );
    }
    c.session.messages.add(
      ChatMessage(
        role: 'tool',
        toolName: 'adb',
        content: '结果详情 末尾',
        images: [img.path],
      ),
    );
    await tester.pumpWidget(WatchEditorApp(controller: c));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);

    // 1：停在末尾
    final pos = tester
        .state<ScrollableState>(
          find
              .byType(Scrollable)
              .at(
                find
                    .byType(Scrollable)
                    .evaluate()
                    .toList()
                    .indexWhere(
                      (e) =>
                          (e.widget as Scrollable).controller != null &&
                          find
                              .descendant(
                                of: find.byWidget(e.widget),
                                matching: find.text('第 39 条需求'),
                              )
                              .evaluate()
                              .isNotEmpty,
                    ),
              ),
        )
        .position;
    expect(pos.pixels, closeTo(pos.maxScrollExtent, 1));
    expect(find.text('第 39 条需求'), findsOneWidget);

    // 2：带图片的工具结果默认收起，不显示图片和详情
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('结果详情 末尾'), findsOneWidget); // 只在单行摘要里
    final last = find.byType(Collapsible).last;
    await tester.tap(last);
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.state<CollapsibleState>(last).isOpen, isTrue);

    // 3/4：滚到顶部，展开框离开视口 → 停下后自动收起，且滚动位置不受影响
    pos.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(pos.pixels, 0);
  });

  testWidgets('打开项目只显示最后一轮，顶部“加载更多”逐轮往前加载且画面不跳', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = tempDir('awe_ui4');
    addTearDown(() => dir.deleteSync(recursive: true));
    final proj = Directory('${dir.path}/proj')..createSync();
    final c = AppController(
      runner: FakeRunner(),
      httpClient: MockClient((r) async => http.Response('', 500)),
      configStore: ConfigStore(Directory('${dir.path}/data')),
      assets: MapAssetReader({'assets/prompts/system_prompt.md': '# 测试'}),
      paths: AppPaths(dir.path),
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      await c.init();
      await c.openProject(proj.path);
    });
    for (var r = 0; r < 3; r++) {
      c.session.messages.add(ChatMessage.user('第 $r 轮需求'));
      for (var k = 0; k < 15; k++) {
        c.session.messages.add(
          ChatMessage(role: 'assistant', content: '回复 $r-$k'),
        );
      }
    }
    await tester.pumpWidget(WatchEditorApp(controller: c));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('第 2 轮需求'), findsOneWidget);
    expect(find.text('第 1 轮需求', skipOffstage: false), findsNothing);
    final more = find.textContaining('加载更多', skipOffstage: false);
    expect(more, findsOneWidget);
    expect(
      find.textContaining('前面还有 2 轮', skipOffstage: false),
      findsOneWidget,
    );

    final pos = tester
        .state<ScrollableState>(
          find
              .ancestor(
                of: find.text('第 2 轮需求'),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position;
    pos.jumpTo(0);
    await tester.pump();
    await tester.tap(more);
    await tester.pump();
    await tester.pump();
    // 新加载的一轮在上方，原来的“第 2 轮需求”仍留在原来的屏幕位置附近，可以继续往上滑
    expect(find.text('第 1 轮需求', skipOffstage: false), findsOneWidget);
    expect(pos.pixels, greaterThan(0));
    expect(
      find.textContaining('前面还有 1 轮', skipOffstage: false),
      findsOneWidget,
    );
    pos.jumpTo(0);
    await tester.pump();
    await tester.tap(find.textContaining('加载更多'));
    await tester.pump();
    await tester.pump();
    expect(find.text('第 0 轮需求', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('加载更多', skipOffstage: false), findsNothing);
  });
}
