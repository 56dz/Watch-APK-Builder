import 'dart:async';
import 'dart:convert';

import 'package:android_watch_editor/services/deepseek_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String sse(List<Map<String, dynamic>> chunks) =>
    '${chunks.map((c) => 'data: ${jsonEncode(c)}\n\n').join()}data: [DONE]\n\n';

Map<String, dynamic> delta(Map<String, dynamic> d, [String? finish]) => {
  'choices': [
    {'index': 0, 'delta': d, 'finish_reason': finish},
  ],
};

final toolCallChunks = [
  delta({'role': 'assistant', 'content': '我先'}),
  delta({'content': '看看文件。'}),
  delta({
    'tool_calls': [
      {
        'index': 0,
        'id': 'call_a',
        'type': 'function',
        'function': {'name': 'list_files', 'arguments': ''},
      },
    ],
  }),
  delta({
    'tool_calls': [
      {
        'index': 0,
        'function': {'arguments': '{"pa'},
      },
    ],
  }),
  delta({
    'tool_calls': [
      {
        'index': 0,
        'function': {'arguments': 'th": "."}'},
      },
      {
        'index': 1,
        'id': 'call_b',
        'type': 'function',
        'function': {'name': 'read_file', 'arguments': '{"path":'},
      },
    ],
  }),
  delta({
    'tool_calls': [
      {
        'index': 1,
        'function': {'arguments': ' "build.sh"}'},
      },
    ],
  }),
  delta({}, 'tool_calls'),
];

void main() {
  test('SseDecoder 处理任意切分、CRLF、注释与 [DONE]', () {
    final dec = SseDecoder();
    const text =
        ': keep-alive\r\n\r\ndata: {"a":1}\r\n\r\ndata: {"b":\n\ndata: 2}\n\ndata: [DONE]\n\n';
    final out = <String>[];
    for (var i = 0; i < text.length; i += 3) {
      out.addAll(
        dec.add(text.substring(i, i + 3 > text.length ? text.length : i + 3)),
      );
    }
    out.addAll(dec.close());
    expect(out, ['{"a":1}', '{"b":', '2}']);
    expect(dec.done, isTrue);
  });

  test('ChunkAccumulator 按 index 增量拼接 tool_calls', () {
    final acc = ChunkAccumulator();
    for (final c in toolCallChunks) {
      acc.addChunk(c);
    }
    final t = acc.build();
    expect(t.content, '我先看看文件。');
    expect(t.finishReason, 'tool_calls');
    expect(t.toolCalls.length, 2);
    expect(t.toolCalls[0].id, 'call_a');
    expect(t.toolCalls[0].name, 'list_files');
    expect(jsonDecode(t.toolCalls[0].arguments), {'path': '.'});
    expect(t.toolCalls[1].id, 'call_b');
    expect(t.toolCalls[1].name, 'read_file');
    expect(jsonDecode(t.toolCalls[1].arguments), {'path': 'build.sh'});
  });

  test('reasoning_content 单独累积', () {
    final acc = ChunkAccumulator()
      ..addChunk(delta({'reasoning_content': '想一'}))
      ..addChunk(delta({'reasoning_content': '想'}))
      ..addChunk(delta({'content': '好的'}, 'stop'));
    final t = acc.build();
    expect(t.reasoning, '想一想');
    expect(t.content, '好的');
    expect(t.toolCalls, isEmpty);
  });

  test('DeepSeekClient 流式请求（假 HTTP，字节逐段到达）', () async {
    late http.BaseRequest captured;
    late String body;
    final client = MockClient.streaming((req, bodyStream) async {
      captured = req;
      body = await bodyStream.bytesToString();
      final bytes = utf8.encode(sse(toolCallChunks));
      final ctl = StreamController<List<int>>();
      () async {
        for (var i = 0; i < bytes.length; i += 7) {
          ctl.add(
            bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7),
          );
          await Future<void>.delayed(Duration.zero);
        }
        await ctl.close();
      }();
      return http.StreamedResponse(
        ctl.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final ds = DeepSeekClient(
      httpClient: client,
      apiKey: () => 'sk-test',
      baseUrl: () => 'https://api.deepseek.com/',
      model: () => 'deepseek-chat',
    );
    final deltas = <String>[];
    final t = await ds.chat(
      messages: [
        {'role': 'user', 'content': 'hi'},
      ],
      tools: [
        {'type': 'function'},
      ],
      onDelta: (d) => deltas.add(d.content),
    );
    expect(
      captured.url.toString(),
      'https://api.deepseek.com/chat/completions',
    );
    expect(captured.headers['Authorization'], 'Bearer sk-test');
    final j = jsonDecode(body) as Map;
    expect(j['stream'], isTrue);
    expect(j['model'], 'deepseek-chat');
    expect(j['tools'], isNotEmpty);
    expect(deltas.join(), '我先看看文件。');
    expect(t.toolCalls.map((c) => c.name), ['list_files', 'read_file']);
  });

  test('HTTP 401 → 中文错误，且不泄露 Key', () async {
    final client = MockClient(
      (req) async =>
          http.Response('{"error":{"message":"Authentication Fails"}}', 401),
    );
    final ds = DeepSeekClient(
      httpClient: client,
      apiKey: () => 'sk-secret',
      baseUrl: () => 'https://api.deepseek.com',
      model: () => 'deepseek-chat',
    );
    await expectLater(
      ds.chat(messages: const []),
      throwsA(
        isA<ApiException>()
            .having((e) => e.message, 'm', contains('API Key 无效'))
            .having((e) => e.message, 'no key', isNot(contains('sk-secret'))),
      ),
    );
  });

  test('未设置 Key', () async {
    final ds = DeepSeekClient(
      httpClient: MockClient((r) async => http.Response('', 200)),
      apiKey: () => '',
      baseUrl: () => '',
      model: () => '',
    );
    await expectLater(
      ds.chat(messages: const []),
      throwsA(isA<ApiException>()),
    );
  });
}
