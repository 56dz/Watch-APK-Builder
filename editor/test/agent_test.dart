import 'dart:convert';
import 'dart:io';

import 'package:android_watch_editor/models/chat_message.dart';
import 'package:android_watch_editor/models/device_profile.dart';
import 'package:android_watch_editor/models/skill.dart';
import 'package:android_watch_editor/services/adb_service.dart';
import 'package:android_watch_editor/services/agent.dart';
import 'package:android_watch_editor/services/deepseek_client.dart';
import 'package:android_watch_editor/services/session_store.dart';
import 'package:android_watch_editor/services/skill_registry.dart';
import 'package:android_watch_editor/services/tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

/// 按脚本依次返回回复的假模型，记录每次收到的 messages。
class ScriptedClient implements ChatClient {
  final List<AssistantTurn> turns;
  final List<List<Map<String, dynamic>>> requests = [];
  ScriptedClient(this.turns);

  @override
  Future<AssistantTurn> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    void Function(StreamDelta delta)? onDelta,
    CancelToken? cancel,
  }) async {
    requests.add([
      for (final m in jsonDecode(jsonEncode(messages)) as List)
        (m as Map).cast<String, dynamic>(),
    ]);
    final t = turns[requests.length - 1];
    onDelta?.call(StreamDelta(content: t.content, reasoning: t.reasoning));
    return t;
  }
}

/// 前 [fails] 次抛出 [error]，之后返回 [turn]。
class FlakyClient implements ChatClient {
  final int fails;
  final ApiException error;
  final AssistantTurn turn;
  int calls = 0;
  FlakyClient(this.fails, this.error, this.turn);

  @override
  Future<AssistantTurn> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    void Function(StreamDelta delta)? onDelta,
    CancelToken? cancel,
  }) async {
    calls++;
    onDelta?.call(const StreamDelta(content: '半截'));
    if (calls <= fails) throw error;
    return turn;
  }
}

void main() {
  late Directory project;
  setUp(() => project = tempDir('awe_agent'));
  tearDown(() => project.deleteSync(recursive: true));

  ToolExecutor executor() {
    final r = FakeRunner();
    return ToolExecutor(
      ToolEnvironment(
        projectDir: project.path,
        runner: r,
        adb: AdbService(r, () => 'adb'),
        skills: SkillRegistry(MapAssetReader({}), () => const []),
        serial: () => null,
        askPermission: () => false,
        confirm: (_, _) async => true,
      ),
    );
  }

  group('模型请求重试', () {
    Future<(FlakyClient, Session, List<String>)> go(
      int fails,
      ApiException err,
      int retries,
    ) async {
      final client = FlakyClient(
        fails,
        err,
        const AssistantTurn(content: '好了', finishReason: 'stop'),
      );
      final session = Session(messages: [ChatMessage.user('hi')]);
      final logs = <String>[];
      await Agent(
        client: client,
        executor: executor(),
        retries: retries,
        retryDelay: Duration.zero,
      ).run(
        session: session,
        systemPrompt: 's',
        callbacks: AgentCallbacks(onUpdate: () {}, onLog: logs.add),
        cancel: CancelToken(),
      );
      return (client, session, logs);
    }

    test('可重试错误按次数重试，成功后丢掉半截输出', () async {
      final (c, s, logs) = await go(
        2,
        const ApiException('超时', retryable: true),
        2,
      );
      expect(c.calls, 3);
      expect(s.messages.last.content, '好了');
      expect(s.messages.where((m) => m.content.contains('半截')), isEmpty);
      expect(logs.where((l) => l.startsWith('⟳')).length, 2);
    });

    test('重试用完后报错并注明重试次数', () async {
      final (c, s, _) = await go(
        5,
        const ApiException('超时', retryable: true),
        2,
      );
      expect(c.calls, 3);
      expect(s.messages.last.isError, isTrue);
      expect(s.messages.last.content, contains('已重试 2 次'));
    });

    test('不可重试错误（如 401）不重试', () async {
      final (c, s, _) = await go(1, const ApiException('API Key 无效'), 3);
      expect(c.calls, 1);
      expect(s.messages.last.content, 'API Key 无效');
    });
  });

  test('一次工具调用后结束；tool_calls / tool_call_id 正确，reasoning 不回传', () async {
    final client = ScriptedClient([
      const AssistantTurn(
        content: '先写文件。',
        reasoning: '用户要一个文件',
        toolCalls: [
          ToolCall(
            id: 'call_1',
            name: 'write_file',
            arguments: '{"path":"hello.txt","content":"你好"}',
          ),
        ],
        finishReason: 'tool_calls',
      ),
      const AssistantTurn(content: '完成了。', finishReason: 'stop'),
    ]);
    final session = Session(messages: [ChatMessage.user('写一个 hello.txt')]);
    var saves = 0;
    final logs = <String>[];
    await Agent(client: client, executor: executor()).run(
      session: session,
      systemPrompt: 'SYS',
      cancel: CancelToken(),
      callbacks: AgentCallbacks(
        onUpdate: () {},
        onLog: logs.add,
        onSave: () async => saves++,
      ),
    );

    expect(File(p.join(project.path, 'hello.txt')).readAsStringSync(), '你好');
    expect(client.requests.length, 2);
    final second = client.requests[1];
    expect(second.first, {'role': 'system', 'content': 'SYS'});
    final asst = second.firstWhere((m) => m['role'] == 'assistant');
    expect(asst['tool_calls'][0]['id'], 'call_1');
    expect(asst['tool_calls'][0]['function']['name'], 'write_file');
    expect(asst.containsKey('reasoning_content'), isFalse);
    expect(jsonEncode(second), isNot(contains('用户要一个文件')));
    final tool = second.firstWhere((m) => m['role'] == 'tool');
    expect(tool['tool_call_id'], 'call_1');
    expect(tool['content'], contains('已创建'));

    expect(session.messages.map((m) => m.role), [
      'user',
      'assistant',
      'tool',
      'assistant',
    ]);
    expect(session.messages[1].reasoning, '用户要一个文件');
    expect(session.messages.last.content, '完成了。');
    expect(saves, greaterThan(0));
    expect(logs.any((l) => l.contains('write_file')), isTrue);
  });

  test('达到最大步数时停止', () async {
    final loop = AssistantTurn(
      toolCalls: [const ToolCall(id: 'c', name: 'list_files', arguments: '{}')],
    );
    final client = ScriptedClient(List.filled(5, loop));
    final session = Session(messages: [ChatMessage.user('x')]);
    await Agent(client: client, executor: executor(), maxSteps: 3).run(
      session: session,
      systemPrompt: 'S',
      cancel: CancelToken(),
      callbacks: AgentCallbacks(onUpdate: () {}),
    );
    expect(client.requests.length, 3);
    expect(session.messages.last.uiOnly, isTrue);
    expect(session.messages.last.content, contains('最大步数'));
  });

  test('已停止时不再调用模型', () async {
    final client = ScriptedClient([]);
    final session = Session(messages: [ChatMessage.user('x')]);
    await Agent(client: client, executor: executor()).run(
      session: session,
      systemPrompt: 'S',
      cancel: CancelToken()..cancel(),
      callbacks: AgentCallbacks(onUpdate: () {}),
    );
    expect(client.requests, isEmpty);
    expect(session.messages.last.content, contains('已停止'));
  });

  test('buildApiMessages：裁剪旧工具输出、补齐缺失结果、跳过 ui 消息', () {
    final history = <ChatMessage>[];
    for (var i = 0; i < 4; i++) {
      history
        ..add(ChatMessage.user('第 $i 轮'))
        ..add(
          ChatMessage(
            role: 'assistant',
            toolCalls: [
              ToolCall(id: 't$i', name: 'run_command', arguments: '{}'),
            ],
          ),
        )
        ..add(
          ChatMessage(
            role: 'tool',
            toolCallId: 't$i',
            toolName: 'run_command',
            content: 'L' * 5000,
          ),
        )
        ..add(ChatMessage(role: 'assistant', content: '好', reasoning: '内部思考'))
        ..add(ChatMessage.note('界面提示'));
    }
    history
      ..add(ChatMessage.user('最后'))
      ..add(
        ChatMessage(
          role: 'assistant',
          toolCalls: [const ToolCall(id: 'lost', name: 'adb', arguments: '{}')],
        ),
      );
    final msgs = buildApiMessages(
      systemPrompt: 'S',
      history: history,
      keepRecentTurns: 2,
      oldToolChars: 100,
    );
    final tools = msgs.where((m) => m['role'] == 'tool').toList();
    expect(tools.length, 5);
    expect((tools[0]['content'] as String).length, lessThan(300));
    expect((tools[2]['content'] as String).length, lessThan(300));
    expect(tools[3]['content'], 'L' * 5000);
    expect(tools[4]['tool_call_id'], 'lost');
    expect(tools[4]['content'], contains('中断'));
    expect(jsonEncode(msgs), isNot(contains('界面提示')));
    expect(jsonEncode(msgs), isNot(contains('内部思考')));
  });

  test('系统提示包含设备档案、skill 列表、项目目录', () {
    final s = buildSystemPrompt(
      base: '# 基础提示',
      device: DeviceProfile(
        model: 'OWW251',
        brand: 'OPPO',
        sdk: 30,
        release: '11',
        widthPx: 466,
        heightPx: 466,
        density: 320,
        flagRound: true,
        shape: ScreenShape.round,
      ),
      skills: const [
        SkillInfo(
          name: 'oppo-watch2-apk',
          description: 'Build APK',
          builtin: true,
          location: '',
        ),
      ],
      projectDir: 'D:/ws/demo',
    );
    expect(s, startsWith('# 基础提示'));
    expect(s, contains('OWW251'));
    expect(s, contains('圆屏'));
    expect(s, contains('466 x 466 px'));
    expect(s, contains('density 320'));
    expect(s, contains('API 30'));
    expect(s, contains('- oppo-watch2-apk：Build APK'));
    expect(s, contains('D:/ws/demo'));
  });

  test('会话持久化往返', () async {
    final s = Session(
      messages: [
        ChatMessage.user('hi'),
        ChatMessage(
          role: 'assistant',
          toolCalls: [const ToolCall(id: 'a', name: 'x', arguments: '{}')],
          reasoning: 'r',
        ),
        ChatMessage(
          role: 'tool',
          toolCallId: 'a',
          toolName: 'x',
          content: 'ok',
          images: ['shots/a.png'],
        ),
      ],
      lastScreenshot: 'shots/a.png',
    );
    await SessionStore.save(project.path, s);
    expect(
      File(p.join(project.path, '.editor', 'session.json')).existsSync(),
      isTrue,
    );
    final back = await SessionStore.load(project.path);
    expect(back.messages.length, 3);
    expect(back.messages[1].toolCalls.single.id, 'a');
    expect(back.messages[2].toolCallId, 'a');
    expect(back.messages[2].images, ['shots/a.png']);
    expect(back.lastScreenshot, 'shots/a.png');
  });
}
