import 'dart:async';
import 'dart:convert';

import 'package:android_watch_editor/services/anthropic_client.dart';
import 'package:android_watch_editor/services/deepseek_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String sseEvents(List<Map<String, dynamic>> events) =>
    events.map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n').join();

final streamEvents = <Map<String, dynamic>>[
  {
    'type': 'message_start',
    'message': {'id': 'msg_1', 'role': 'assistant', 'content': []},
  },
  {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'thinking', 'thinking': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'thinking_delta', 'thinking': '想一'},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'thinking_delta', 'thinking': '想'},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'signature_delta', 'signature': 'sig'},
  },
  {'type': 'content_block_stop', 'index': 0},
  {
    'type': 'content_block_start',
    'index': 1,
    'content_block': {'type': 'text', 'text': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 1,
    'delta': {'type': 'text_delta', 'text': '我先'},
  },
  {'type': 'ping'},
  {
    'type': 'content_block_delta',
    'index': 1,
    'delta': {'type': 'text_delta', 'text': '看看文件。'},
  },
  {'type': 'content_block_stop', 'index': 1},
  {
    'type': 'content_block_start',
    'index': 2,
    'content_block': {
      'type': 'tool_use',
      'id': 'toolu_a',
      'name': 'list_files',
      'input': {},
    },
  },
  {
    'type': 'content_block_delta',
    'index': 2,
    'delta': {'type': 'input_json_delta', 'partial_json': '{"pa'},
  },
  {
    'type': 'content_block_delta',
    'index': 2,
    'delta': {'type': 'input_json_delta', 'partial_json': 'th": "."}'},
  },
  {'type': 'content_block_stop', 'index': 2},
  {
    'type': 'content_block_start',
    'index': 3,
    'content_block': {
      'type': 'tool_use',
      'id': 'toolu_b',
      'name': 'read_file',
      'input': {},
    },
  },
  {
    'type': 'content_block_delta',
    'index': 3,
    'delta': {'type': 'input_json_delta', 'partial_json': '{"path":'},
  },
  {
    'type': 'content_block_delta',
    'index': 3,
    'delta': {'type': 'input_json_delta', 'partial_json': ' "build.sh"}'},
  },
  {'type': 'content_block_stop', 'index': 3},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'tool_use'},
    'usage': {'output_tokens': 10},
  },
  {'type': 'message_stop'},
];

/// 把字节按 7 字节分段逐段推送，模拟任意切分。
http.StreamedResponse chunked(String text, {int status = 200}) {
  final bytes = utf8.encode(text);
  final ctl = StreamController<List<int>>();
  () async {
    for (var i = 0; i < bytes.length; i += 7) {
      ctl.add(bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7));
      await Future<void>.delayed(Duration.zero);
    }
    await ctl.close();
  }();
  return http.StreamedResponse(
    ctl.stream,
    status,
    headers: {'content-type': 'text/event-stream'},
  );
}

AnthropicClient clientWith(
  http.Client c, {
  String key = 'sk-ant-test',
  String base = 'https://api.anthropic.com',
  String model = 'claude-test',
}) => AnthropicClient(
  httpClient: c,
  apiKey: () => key,
  baseUrl: () => base,
  model: () => model,
);

void main() {
  group('toAnthropicMessages', () {
    test('多条 system 合并为字符串', () {
      final r = toAnthropicMessages([
        {'role': 'system', 'content': '你是助手。'},
        {'role': 'user', 'content': 'hi'},
        {'role': 'system', 'content': '补充规则。'},
      ]);
      expect(r.system, contains('你是助手。'));
      expect(r.system, contains('补充规则。'));
      expect(r.system.indexOf('你是助手。'), lessThan(r.system.indexOf('补充规则。')));
      expect(r.messages, [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
        },
      ]);
    });

    test('user parts：文本、data URL 图片、http 图片', () {
      final r = toAnthropicMessages([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '看图'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,QUJD'},
            },
            {
              'type': 'image_url',
              'image_url': {'url': 'https://example.com/a.png'},
            },
          ],
        },
      ]);
      expect(r.messages.single['content'], [
        {'type': 'text', 'text': '看图'},
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/jpeg',
            'data': 'QUJD',
          },
        },
        {
          'type': 'image',
          'source': {'type': 'url', 'url': 'https://example.com/a.png'},
        },
      ]);
    });

    test('assistant tool_calls → tool_use；参数解析失败用 {}', () {
      final r = toAnthropicMessages([
        {'role': 'user', 'content': '列文件'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'list_files', 'arguments': '{"path":"."}'},
            },
            {
              'id': 'call_2',
              'type': 'function',
              'function': {'name': 'bad', 'arguments': '{oops'},
            },
          ],
        },
      ]);
      expect(r.messages[1], {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': 'call_1',
            'name': 'list_files',
            'input': {'path': '.'},
          },
          {'type': 'tool_use', 'id': 'call_2', 'name': 'bad', 'input': {}},
        ],
      });
    });

    test('连续 tool 结果合并进一条 user，且 tool_result 排在最前', () {
      final r = toAnthropicMessages([
        {'role': 'user', 'content': '开始'},
        {
          'role': 'assistant',
          'content': '好的',
          'tool_calls': [
            {
              'id': 'a',
              'function': {'name': 'x', 'arguments': '{}'},
            },
            {
              'id': 'b',
              'function': {'name': 'y', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'a', 'content': 'ra'},
        {'role': 'user', 'content': '顺便看看截图'},
        {'role': 'tool', 'tool_call_id': 'b', 'content': ''},
      ]);
      expect(r.messages.length, 3);
      expect(r.messages[1]['content'], [
        {'type': 'text', 'text': '好的'},
        {
          'type': 'tool_use',
          'id': 'a',
          'name': 'x',
          'input': <String, dynamic>{},
        },
        {
          'type': 'tool_use',
          'id': 'b',
          'name': 'y',
          'input': <String, dynamic>{},
        },
      ]);
      expect(r.messages[2], {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'a', 'content': 'ra'},
          {'type': 'tool_result', 'tool_use_id': 'b', 'content': '（空）'},
          {'type': 'text', 'text': '顺便看看截图'},
        ],
      });
    });

    test('首条为 assistant 时补 user；空文本被丢弃', () {
      final r = toAnthropicMessages([
        {'role': 'system', 'content': 's'},
        {'role': 'assistant', 'content': '你好'},
        {'role': 'user', 'content': ''},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '  '},
            {'type': 'text', 'text': '问题'},
          ],
        },
        {'role': 'assistant', 'content': ''},
      ]);
      expect(r.messages, [
        {'role': 'user', 'content': '（继续）'},
        {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': '你好'},
          ],
        },
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '问题'},
          ],
        },
      ]);
      // 角色严格交替
      for (var i = 1; i < r.messages.length; i++) {
        expect(r.messages[i]['role'], isNot(r.messages[i - 1]['role']));
      }
    });
  });

  test('toAnthropicTools', () {
    final t = toAnthropicTools([
      {
        'type': 'function',
        'function': {
          'name': 'read_file',
          'description': '读取文件',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
            },
            'required': ['path'],
          },
        },
      },
    ]);
    expect(t, [
      {
        'name': 'read_file',
        'description': '读取文件',
        'input_schema': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
      },
    ]);
  });

  test('endpoint 规则', () {
    Uri ep(String b) => clientWith(
      MockClient((_) async => http.Response('', 200)),
      base: b,
    ).endpoint;
    expect(ep('').toString(), 'https://api.anthropic.com/v1/messages');
    expect(
      ep('https://api.anthropic.com/').toString(),
      'https://api.anthropic.com/v1/messages',
    );
    expect(
      ep('https://proxy.example.com/v1/').toString(),
      'https://proxy.example.com/v1/messages',
    );
    expect(
      ep('https://proxy.example.com/api/v1/messages/').toString(),
      'https://proxy.example.com/api/v1/messages',
    );
    expect(
      ep('https://proxy.example.com/anthropic').toString(),
      'https://proxy.example.com/anthropic/v1/messages',
    );
  });

  test('stop_reason 映射', () {
    expect(AnthropicStreamAccumulator.mapStopReason('end_turn'), 'stop');
    expect(AnthropicStreamAccumulator.mapStopReason('tool_use'), 'tool_calls');
    expect(AnthropicStreamAccumulator.mapStopReason('max_tokens'), 'length');
    expect(AnthropicStreamAccumulator.mapStopReason('refusal'), 'refusal');
  });

  test('流式：请求头/body、文本+thinking+两个工具调用分片参数', () async {
    late http.BaseRequest captured;
    late String body;
    final client = MockClient.streaming((req, bodyStream) async {
      captured = req;
      body = await bodyStream.bytesToString();
      return chunked(sseEvents(streamEvents));
    });
    final ac = clientWith(client, base: 'https://api.anthropic.com/');
    final deltas = <StreamDelta>[];
    final t = await ac.chat(
      messages: [
        {'role': 'system', 'content': '系统提示'},
        {'role': 'user', 'content': 'hi'},
      ],
      tools: [
        {
          'type': 'function',
          'function': {
            'name': 'list_files',
            'description': 'd',
            'parameters': {'type': 'object', 'properties': {}},
          },
        },
      ],
      onDelta: deltas.add,
    );
    expect(captured.method, 'POST');
    expect(captured.url.toString(), 'https://api.anthropic.com/v1/messages');
    expect(captured.headers['x-api-key'], 'sk-ant-test');
    expect(captured.headers['anthropic-version'], '2023-06-01');
    expect(captured.headers['content-type'], startsWith('application/json'));
    expect(captured.headers['accept'], 'text/event-stream');
    expect(captured.headers.containsKey('Authorization'), isFalse);
    final j = jsonDecode(body) as Map;
    expect(j['model'], 'claude-test');
    expect(j['max_tokens'], 16000);
    expect(j['stream'], isTrue);
    expect(j['system'], '系统提示');
    expect(j['messages'], [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'hi'},
        ],
      },
    ]);
    expect((j['tools'] as List).single['name'], 'list_files');
    expect((j['tools'] as List).single['input_schema'], isA<Map>());

    expect(deltas.map((d) => d.content).join(), '我先看看文件。');
    expect(deltas.map((d) => d.reasoning).join(), '想一想');
    expect(deltas.last.partialToolCalls.length, 2);

    expect(t.content, '我先看看文件。');
    expect(t.reasoning, '想一想');
    expect(t.finishReason, 'tool_calls');
    expect(t.toolCalls.length, 2);
    expect(t.toolCalls[0].id, 'toolu_a');
    expect(t.toolCalls[0].name, 'list_files');
    expect(jsonDecode(t.toolCalls[0].arguments), {'path': '.'});
    expect(t.toolCalls[1].id, 'toolu_b');
    expect(t.toolCalls[1].name, 'read_file');
    expect(jsonDecode(t.toolCalls[1].arguments), {'path': 'build.sh'});
  });

  test('无参数的 tool_use 参数为 {}；end_turn → stop', () async {
    final client = MockClient.streaming(
      (req, s) async => chunked(
        sseEvents([
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'tool_use', 'id': 't1', 'name': 'ping'},
          },
          {'type': 'content_block_stop', 'index': 0},
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
          },
          {'type': 'message_stop'},
        ]),
      ),
    );
    final t = await clientWith(client).chat(
      messages: [
        {'role': 'user', 'content': 'x'},
      ],
    );
    expect(t.toolCalls.single.arguments, '{}');
    expect(t.finishReason, 'stop');
  });

  test('error 事件 → ApiException', () async {
    final client = MockClient.streaming(
      (req, s) async => chunked(
        sseEvents([
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': ''},
          },
          {
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
          },
        ]),
      ),
    );
    await expectLater(
      clientWith(client).chat(
        messages: [
          {'role': 'user', 'content': 'x'},
        ],
      ),
      throwsA(
        isA<ApiException>().having((e) => e.message, 'm', '模型返回错误：Overloaded'),
      ),
    );
  });

  test('HTTP 401 → 中文错误，且不泄露 Key', () async {
    final client = MockClient(
      (req) async => http.Response(
        '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}',
        401,
      ),
    );
    await expectLater(
      clientWith(client, key: 'sk-ant-secret').chat(
        messages: [
          {'role': 'user', 'content': 'x'},
        ],
      ),
      throwsA(
        isA<ApiException>()
            .having((e) => e.message, 'm', contains('API Key 无效'))
            .having(
              (e) => e.message,
              'no key',
              isNot(contains('sk-ant-secret')),
            )
            .having((e) => e.message, 'no brand', isNot(contains('DeepSeek'))),
      ),
    );
  });

  test('HTTP 529 → 服务繁忙', () {
    final m = AnthropicClient.describeHttpError(
      529,
      '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}',
    );
    expect(m, contains('服务繁忙'));
    expect(m, contains('529'));
  });

  test('未设置 Key', () async {
    final ac = AnthropicClient(
      httpClient: MockClient((r) async => http.Response('', 200)),
      apiKey: () => ' ',
      baseUrl: () => '',
      model: () => '',
    );
    await expectLater(
      ac.chat(messages: const []),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'm',
          '尚未设置 API Key，请先在“设置”中填写。',
        ),
      ),
    );
  });

  test('取消 → CancelledException', () async {
    final ctl = StreamController<List<int>>();
    final client = MockClient.streaming((req, s) async {
      return http.StreamedResponse(ctl.stream, 200);
    });
    final cancel = CancelToken();
    final f = clientWith(client).chat(
      messages: [
        {'role': 'user', 'content': 'x'},
      ],
      cancel: cancel,
    );
    ctl.add(
      utf8.encode(
        sseEvents([
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': ''},
          },
        ]),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    cancel.cancel();
    ctl.add(utf8.encode(': ping\n\n'));
    await expectLater(f, throwsA(isA<CancelledException>()));
    await ctl.close();
  });

  test('空闲超时 → ApiException', () async {
    final ctl = StreamController<List<int>>();
    final client = MockClient.streaming(
      (req, s) async => http.StreamedResponse(ctl.stream, 200),
    );
    final ac = AnthropicClient(
      httpClient: client,
      apiKey: () => 'k',
      baseUrl: () => '',
      model: () => '',
      idleTimeout: const Duration(milliseconds: 50),
    );
    await expectLater(
      ac.chat(
        messages: [
          {'role': 'user', 'content': 'x'},
        ],
      ),
      throwsA(
        isA<ApiException>().having((e) => e.message, 'm', contains('超时')),
      ),
    );
    await ctl.close();
  });
}
