import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import 'deepseek_client.dart';

/// 把 OpenAI chat 格式的 messages 转成 Anthropic Messages API 格式。
///
/// - system 消息拼接为 [system] 字符串；
/// - user 的 parts（text / image_url）转为 content blocks；
/// - assistant 的 tool_calls 转为 tool_use 块；
/// - tool 消息转为 user 消息中的 tool_result 块；
/// - 连续同角色消息合并，合并后的 user 消息里 tool_result 排在最前；
/// - 首条必须是 user，空文本块丢弃。
({String system, List<Map<String, dynamic>> messages}) toAnthropicMessages(
  List<Map<String, dynamic>> openAi,
) {
  final systemParts = <String>[];
  final raw = <({String role, List<Map<String, dynamic>> blocks})>[];

  for (final m in openAi) {
    final role = m['role'];
    final content = m['content'];
    switch (role) {
      case 'system':
        final s = _plainText(content);
        if (s.trim().isNotEmpty) systemParts.add(s);
      case 'user':
        raw.add((role: 'user', blocks: _userBlocks(content)));
      case 'assistant':
        final blocks = <Map<String, dynamic>>[];
        final text = _plainText(content);
        if (text.trim().isNotEmpty) blocks.add({'type': 'text', 'text': text});
        final tcs = m['tool_calls'];
        if (tcs is List) {
          for (final t in tcs.whereType<Map>()) {
            final f = (t['function'] as Map?) ?? const {};
            blocks.add({
              'type': 'tool_use',
              'id': '${t['id'] ?? ''}',
              'name': '${f['name'] ?? ''}',
              'input': _decodeArgs(f['arguments']),
            });
          }
        }
        raw.add((role: 'assistant', blocks: blocks));
      case 'tool':
        final c = _plainText(content);
        raw.add((
          role: 'user',
          blocks: [
            {
              'type': 'tool_result',
              'tool_use_id': '${m['tool_call_id'] ?? ''}',
              'content': c.isEmpty ? '（空）' : c,
            },
          ],
        ));
      default:
        break;
    }
  }

  // 合并连续同角色消息。
  final merged = <({String role, List<Map<String, dynamic>> blocks})>[];
  for (final r in raw) {
    if (r.blocks.isEmpty) continue;
    if (merged.isNotEmpty && merged.last.role == r.role) {
      merged.last.blocks.addAll(r.blocks);
    } else {
      merged.add((role: r.role, blocks: [...r.blocks]));
    }
  }

  final out = <Map<String, dynamic>>[];
  if (merged.isNotEmpty && merged.first.role == 'assistant') {
    out.add({'role': 'user', 'content': '（继续）'});
  }
  for (final m in merged) {
    var blocks = m.blocks;
    if (m.role == 'user') {
      blocks = [
        ...blocks.where((b) => b['type'] == 'tool_result'),
        ...blocks.where((b) => b['type'] != 'tool_result'),
      ];
    }
    out.add({'role': m.role, 'content': blocks});
  }
  return (system: systemParts.join('\n\n'), messages: out);
}

/// OpenAI function tools → Anthropic tools。
List<Map<String, dynamic>> toAnthropicTools(
  List<Map<String, dynamic>> openAiTools,
) {
  final out = <Map<String, dynamic>>[];
  for (final t in openAiTools) {
    final f = t['function'];
    if (f is! Map) continue;
    final name = f['name'];
    if (name is! String || name.isEmpty) continue;
    out.add({
      'name': name,
      if (f['description'] is String) 'description': f['description'],
      'input_schema': f['parameters'] is Map
          ? f['parameters']
          : const {'type': 'object', 'properties': {}},
    });
  }
  return out;
}

String _plainText(Object? content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    return content
        .whereType<Map>()
        .where((p) => p['type'] == 'text' && p['text'] is String)
        .map((p) => p['text'] as String)
        .join('\n');
  }
  return '$content';
}

List<Map<String, dynamic>> _userBlocks(Object? content) {
  final blocks = <Map<String, dynamic>>[];
  if (content is String) {
    if (content.trim().isNotEmpty) {
      blocks.add({'type': 'text', 'text': content});
    }
    return blocks;
  }
  if (content is! List) return blocks;
  for (final p in content.whereType<Map>()) {
    switch (p['type']) {
      case 'text':
        final t = p['text'];
        if (t is String && t.trim().isNotEmpty) {
          blocks.add({'type': 'text', 'text': t});
        }
      case 'image_url':
        final iu = p['image_url'];
        final url = iu is Map ? iu['url'] : iu;
        if (url is String && url.isNotEmpty) {
          final img = _imageBlock(url);
          if (img != null) blocks.add(img);
        }
      default:
        break;
    }
  }
  return blocks;
}

Map<String, dynamic>? _imageBlock(String url) {
  if (url.startsWith('data:')) {
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    final meta = url.substring(5, comma); // 如 image/png;base64
    final semi = meta.indexOf(';');
    var mediaType = semi < 0 ? meta : meta.substring(0, semi);
    if (mediaType.isEmpty) mediaType = 'image/png';
    return {
      'type': 'image',
      'source': {
        'type': 'base64',
        'media_type': mediaType,
        'data': url.substring(comma + 1),
      },
    };
  }
  return {
    'type': 'image',
    'source': {'type': 'url', 'url': url},
  };
}

Map<String, dynamic> _decodeArgs(Object? args) {
  if (args is Map) return args.cast<String, dynamic>();
  if (args is String && args.trim().isNotEmpty) {
    try {
      final j = jsonDecode(args);
      if (j is Map) return j.cast<String, dynamic>();
    } on FormatException {
      // 解析失败用空对象
    }
  }
  return <String, dynamic>{};
}

/// Anthropic Messages API（/v1/messages）流式客户端。
class AnthropicClient implements ChatClient {
  final http.Client httpClient;
  final String Function() apiKey;
  final String Function() baseUrl;
  final String Function() model;
  final Duration idleTimeout;

  /// 动态超时（来自设置）；为 null 时用 [idleTimeout]。
  final Duration Function()? timeout;
  Duration get _idle => timeout?.call() ?? idleTimeout;
  final int maxTokens;

  static const defaultBaseUrl = 'https://api.anthropic.com';
  static const defaultModel = 'claude-sonnet-4-5';
  static const apiVersion = '2023-06-01';

  AnthropicClient({
    required this.httpClient,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    this.idleTimeout = const Duration(seconds: 120),
    this.maxTokens = 16000,
    this.timeout,
  });

  Uri get endpoint {
    var b = baseUrl().trim();
    if (b.isEmpty) b = defaultBaseUrl;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.endsWith('/messages')) return Uri.parse(b);
    if (b.endsWith('/v1')) return Uri.parse('$b/messages');
    return Uri.parse('$b/v1/messages');
  }

  @override
  Future<AssistantTurn> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    void Function(StreamDelta delta)? onDelta,
    CancelToken? cancel,
  }) async {
    final key = apiKey().trim();
    if (key.isEmpty) {
      throw const ApiException('尚未设置 API Key，请先在“设置”中填写。');
    }
    final converted = toAnthropicMessages(messages);
    final aTools = toAnthropicTools(tools);
    final req = http.AbortableRequest(
      'POST',
      endpoint,
      abortTrigger: cancel?.whenCancelled,
    );
    req.headers.addAll({
      'x-api-key': key,
      'anthropic-version': apiVersion,
      'content-type': 'application/json',
      'accept': 'text/event-stream',
    });
    final m = model().trim();
    req.body = jsonEncode({
      'model': m.isEmpty ? defaultModel : m,
      'max_tokens': maxTokens,
      'stream': true,
      if (converted.system.isNotEmpty) 'system': converted.system,
      'messages': converted.messages,
      if (aTools.isNotEmpty) 'tools': aTools,
    });

    http.StreamedResponse resp;
    try {
      resp = await httpClient.send(req).timeout(_idle);
    } on TimeoutException {
      if (cancel?.isCancelled ?? false) throw CancelledException();
      throw ApiException('模型响应超时（${_idle.inSeconds} 秒没有响应）', retryable: true);
    } on http.RequestAbortedException {
      throw CancelledException();
    } on http.ClientException catch (e) {
      if (cancel?.isCancelled ?? false) throw CancelledException();
      throw ApiException(
        '无法连接模型服务（${endpoint.host}）：${e.message}',
        retryable: true,
      );
    }
    if (resp.statusCode != 200) {
      final body = await resp.stream.bytesToString().catchError((_) => '');
      throw ApiException(
        describeHttpError(resp.statusCode, body),
        retryable: ApiException.retryableStatus(resp.statusCode),
      );
    }

    final dec = SseDecoder();
    final acc = AnthropicStreamAccumulator();
    void handle(List<String> datas) {
      for (final d in datas) {
        Object? j;
        try {
          j = jsonDecode(d);
        } on FormatException {
          continue;
        }
        if (j is! Map) continue;
        final delta = acc.addEvent(j.cast<String, dynamic>());
        if (delta != null) onDelta?.call(delta);
      }
    }

    try {
      await for (final chunk
          in resp.stream
              .timeout(
                _idle,
                onTimeout: (s) {
                  s.addError(
                    ApiException(
                      '模型响应超时（${_idle.inSeconds} 秒无数据）',
                      retryable: true,
                    ),
                  );
                  s.close();
                },
              )
              .transform(utf8.decoder)) {
        if (cancel?.isCancelled ?? false) throw CancelledException();
        handle(dec.add(chunk));
        if (acc.stopped || dec.done) break;
      }
      if (!acc.stopped) handle(dec.close());
    } on http.RequestAbortedException {
      throw CancelledException();
    } on http.ClientException catch (e) {
      if (cancel?.isCancelled ?? false) throw CancelledException();
      throw ApiException('读取模型响应时连接中断：${e.message}', retryable: true);
    }
    if (cancel?.isCancelled ?? false) throw CancelledException();
    return acc.build();
  }

  /// HTTP 错误 → 中文说明（不包含 API Key）。
  static String describeHttpError(int status, String body) {
    var detail = body.trim();
    var errType = '';
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map) {
        final e = j['error'] as Map;
        detail = '${e['message'] ?? detail}';
        errType = '${e['type'] ?? ''}';
      }
    } catch (_) {}
    if (detail.length > 300) detail = '${detail.substring(0, 300)}…';
    final hint = errType == 'overloaded_error'
        ? '服务繁忙（过载），请稍后再试'
        : switch (status) {
            400 => '请求格式错误',
            401 => 'API Key 无效，请在“设置”中检查',
            403 => '没有访问权限',
            404 => '接口地址或模型不存在',
            413 => '请求内容过大',
            429 => '请求过于频繁，请稍后再试',
            500 || 502 || 503 => '服务异常，请稍后再试',
            529 => '服务繁忙（过载），请稍后再试',
            _ => '请求失败',
          };
    return '$hint（HTTP $status）${detail.isEmpty ? '' : '：$detail'}';
  }
}

/// 累积 Anthropic 流式事件（content_block_start / delta / message_delta …）。
class AnthropicStreamAccumulator {
  final StringBuffer content = StringBuffer();
  final StringBuffer reasoning = StringBuffer();
  final Map<int, _Block> _blocks = {};
  String? finishReason;
  bool stopped = false;

  /// 处理一个事件；有增量时返回 [StreamDelta]。error 事件抛出 [ApiException]。
  StreamDelta? addEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'error':
        final err = e['error'];
        final msg = err is Map ? (err['message'] ?? err['type'] ?? err) : err;
        throw ApiException('模型返回错误：$msg');
      case 'content_block_start':
        final index = (e['index'] as num?)?.toInt() ?? _blocks.length;
        final cb = (e['content_block'] as Map?) ?? const {};
        final type = '${cb['type'] ?? ''}';
        final b = _Block(type);
        _blocks[index] = b;
        if (type == 'tool_use') {
          b.id = '${cb['id'] ?? ''}';
          b.name = '${cb['name'] ?? ''}';
          return _delta();
        }
        if (type == 'text' && cb['text'] is String) {
          final t = cb['text'] as String;
          if (t.isNotEmpty) {
            content.write(t);
            return _delta(content: t);
          }
        }
        return null;
      case 'content_block_delta':
        final index = (e['index'] as num?)?.toInt() ?? -1;
        final d = (e['delta'] as Map?) ?? const {};
        switch (d['type']) {
          case 'text_delta':
            final t = d['text'] is String ? d['text'] as String : '';
            content.write(t);
            return _delta(content: t);
          case 'thinking_delta':
            final t = d['thinking'] is String ? d['thinking'] as String : '';
            reasoning.write(t);
            return _delta(reasoning: t);
          case 'input_json_delta':
            final p = d['partial_json'] is String
                ? d['partial_json'] as String
                : '';
            final b = _blocks.putIfAbsent(index, () => _Block('tool_use'));
            b.args.write(p);
            return _delta();
          default:
            return null;
        }
      case 'message_delta':
        final d = (e['delta'] as Map?) ?? const {};
        final sr = d['stop_reason'];
        if (sr is String) finishReason = mapStopReason(sr);
        return null;
      case 'message_stop':
        stopped = true;
        return null;
      default:
        return null;
    }
  }

  StreamDelta _delta({String content = '', String reasoning = ''}) =>
      StreamDelta(
        content: content,
        reasoning: reasoning,
        partialToolCalls: toolCalls,
      );

  /// Anthropic stop_reason → OpenAI finish_reason。
  static String mapStopReason(String r) => switch (r) {
    'end_turn' => 'stop',
    'tool_use' => 'tool_calls',
    'max_tokens' => 'length',
    _ => r,
  };

  List<ToolCall> get toolCalls {
    final keys =
        _blocks.keys.where((k) => _blocks[k]!.type == 'tool_use').toList()
          ..sort();
    return [
      for (final k in keys)
        ToolCall(
          id: _blocks[k]!.id.isEmpty ? 'toolu_$k' : _blocks[k]!.id,
          name: _blocks[k]!.name,
          arguments: _blocks[k]!.args.isEmpty
              ? '{}'
              : _blocks[k]!.args.toString(),
        ),
    ];
  }

  AssistantTurn build() => AssistantTurn(
    content: content.toString(),
    reasoning: reasoning.toString(),
    toolCalls: toolCalls,
    finishReason: finishReason,
  );
}

class _Block {
  final String type;
  String id = '';
  String name = '';
  final StringBuffer args = StringBuffer();
  _Block(this.type);
}
