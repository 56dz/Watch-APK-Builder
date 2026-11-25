import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_message.dart';

class CancelToken {
  final Completer<void> _c = Completer<void>();
  bool get isCancelled => _c.isCompleted;
  Future<void> get whenCancelled => _c.future;
  void cancel() {
    if (!_c.isCompleted) _c.complete();
  }
}

class CancelledException implements Exception {
  @override
  String toString() => '已停止';
}

class ApiException implements Exception {
  final String message;

  /// 网络错误、超时、429、5xx 等临时问题，可以重试。
  final bool retryable;
  const ApiException(this.message, {this.retryable = false});

  /// 这些 HTTP 状态码通常是临时问题，值得重试。
  static bool retryableStatus(int s) =>
      s == 408 || s == 409 || s == 425 || s == 429 || s >= 500;

  @override
  String toString() => message;
}

/// 一轮助手回复（流结束后的完整结果）。
class AssistantTurn {
  final String content;
  final String reasoning;
  final List<ToolCall> toolCalls;
  final String? finishReason;

  const AssistantTurn({
    this.content = '',
    this.reasoning = '',
    this.toolCalls = const [],
    this.finishReason,
  });
}

/// 流式增量（用于界面实时显示）。
class StreamDelta {
  final String content;
  final String reasoning;
  final List<ToolCall> partialToolCalls;
  const StreamDelta({
    this.content = '',
    this.reasoning = '',
    this.partialToolCalls = const [],
  });
}

/// 把任意切分的 SSE 文本流切成 data 负载；遇到 [DONE] 后 [done] 为 true。
class SseDecoder {
  final StringBuffer _buf = StringBuffer();
  final List<String> _dataLines = [];
  bool done = false;

  List<String> add(String chunk) {
    _buf.write(chunk);
    final text = _buf.toString();
    final lastNl = text.lastIndexOf('\n');
    if (lastNl < 0) return const [];
    final complete = text.substring(0, lastNl);
    _buf
      ..clear()
      ..write(text.substring(lastNl + 1));
    final out = <String>[];
    for (var line in complete.split('\n')) {
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      _line(line, out);
    }
    return out;
  }

  List<String> close() {
    final out = <String>[];
    final rest = _buf.toString();
    _buf.clear();
    if (rest.isNotEmpty) _line(rest, out);
    _line('', out);
    return out;
  }

  void _line(String line, List<String> out) {
    if (line.isEmpty) {
      if (_dataLines.isNotEmpty) {
        final data = _dataLines.join('\n');
        _dataLines.clear();
        if (data.trim() == '[DONE]') {
          done = true;
        } else {
          out.add(data);
        }
      }
      return;
    }
    if (line.startsWith(':')) return; // 注释 / keep-alive
    if (line.startsWith('data:')) {
      var d = line.substring(5);
      if (d.startsWith(' ')) d = d.substring(1);
      _dataLines.add(d);
    }
  }
}

/// 累积 chat.completion.chunk：content / reasoning_content 直接拼接，
/// tool_calls 按 index 增量拼接（id、name 只在首片出现，arguments 分片到达）。
class ChunkAccumulator {
  final StringBuffer content = StringBuffer();
  final StringBuffer reasoning = StringBuffer();
  final Map<int, _PartialCall> _calls = {};
  String? finishReason;

  StreamDelta addChunk(Map<String, dynamic> chunk) {
    final choices = chunk['choices'];
    if (choices is! List || choices.isEmpty) return const StreamDelta();
    final choice = (choices.first as Map).cast<String, dynamic>();
    final fr = choice['finish_reason'];
    if (fr is String) finishReason = fr;
    final delta =
        (choice['delta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final c = delta['content'] is String ? delta['content'] as String : '';
    final r = delta['reasoning_content'] is String
        ? delta['reasoning_content'] as String
        : '';
    content.write(c);
    reasoning.write(r);
    final tcs = delta['tool_calls'];
    if (tcs is List) {
      for (final raw in tcs.whereType<Map>()) {
        final t = raw.cast<String, dynamic>();
        final index = (t['index'] as num?)?.toInt() ?? _calls.length;
        final pc = _calls.putIfAbsent(index, () => _PartialCall());
        final id = t['id'];
        if (id is String && id.isNotEmpty) pc.id = id;
        final f = (t['function'] as Map?)?.cast<String, dynamic>();
        if (f != null) {
          final name = f['name'];
          if (name is String && name.isNotEmpty) pc.name.write(name);
          final args = f['arguments'];
          if (args is String) pc.arguments.write(args);
        }
      }
    }
    return StreamDelta(
      content: c,
      reasoning: r,
      partialToolCalls: tcs is List ? toolCalls : const [],
    );
  }

  List<ToolCall> get toolCalls {
    final keys = _calls.keys.toList()..sort();
    return [
      for (final k in keys)
        ToolCall(
          id: _calls[k]!.id.isEmpty ? 'call_$k' : _calls[k]!.id,
          name: _calls[k]!.name.toString(),
          arguments: _calls[k]!.arguments.toString(),
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

class _PartialCall {
  String id = '';
  final StringBuffer name = StringBuffer();
  final StringBuffer arguments = StringBuffer();
}

/// 聊天模型客户端抽象（测试注入假实现）。
abstract class ChatClient {
  Future<AssistantTurn> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    void Function(StreamDelta delta)? onDelta,
    CancelToken? cancel,
  });
}

/// OpenAI 兼容 chat completions 流式客户端（DeepSeek、OpenAI 及其它兼容服务）。
class DeepSeekClient implements ChatClient {
  final http.Client httpClient;
  final String Function() apiKey;
  final String Function() baseUrl;
  final String Function() model;
  final Duration idleTimeout;

  /// 动态超时（来自设置）；为 null 时用 [idleTimeout]。
  final Duration Function()? timeout;
  Duration get _idle => timeout?.call() ?? idleTimeout;
  final int? maxTokens;

  DeepSeekClient({
    this.maxTokens,
    required this.httpClient,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    this.idleTimeout = const Duration(seconds: 120),
    this.timeout,
  });

  Uri get endpoint {
    var b = baseUrl().trim();
    if (b.isEmpty) b = 'https://api.deepseek.com';
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return Uri.parse('$b/chat/completions');
  }

  @override
  Future<AssistantTurn> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    void Function(StreamDelta delta)? onDelta,
    CancelToken? cancel,
  }) async {
    final key = apiKey().trim();
    if (key.isEmpty) throw const ApiException('尚未设置 API Key，请先在“设置”中填写。');
    final req = http.AbortableRequest(
      'POST',
      endpoint,
      abortTrigger: cancel?.whenCancelled,
    );
    req.headers.addAll({
      'Authorization': 'Bearer $key',
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    });
    req.body = jsonEncode({
      'model': model().trim().isEmpty ? 'deepseek-chat' : model().trim(),
      if (maxTokens != null) 'max_tokens': maxTokens,
      'messages': messages,
      'stream': true,
      if (tools.isNotEmpty) 'tools': tools,
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
    final acc = ChunkAccumulator();
    void handle(List<String> datas) {
      for (final d in datas) {
        Object? j;
        try {
          j = jsonDecode(d);
        } on FormatException {
          continue;
        }
        if (j is! Map) continue;
        final err = j['error'];
        if (err is Map) throw ApiException('模型返回错误：${err['message'] ?? err}');
        final delta = acc.addChunk(j.cast<String, dynamic>());
        onDelta?.call(delta);
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
        if (dec.done) break;
      }
      handle(dec.close());
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
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map)
        detail = '${(j['error'] as Map)['message'] ?? detail}';
    } catch (_) {}
    if (detail.length > 300) detail = '${detail.substring(0, 300)}…';
    final hint = switch (status) {
      400 => '请求格式错误',
      401 => 'API Key 无效，请在“设置”中检查',
      402 => '账户余额不足',
      422 => '请求参数错误',
      429 => '请求过于频繁，请稍后再试',
      500 || 502 || 503 => '模型服务繁忙，请稍后再试',
      _ => '请求失败',
    };
    return '$hint（HTTP $status）${detail.isEmpty ? '' : '：$detail'}';
  }
}
