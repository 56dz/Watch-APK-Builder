import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/chat_message.dart';
import '../models/device_profile.dart';
import '../models/skill.dart';
import 'deepseek_client.dart';
import 'tools.dart';

/// 组装系统提示：基础提示 + 设备档案 + skill 列表 + 项目目录 + 环境。
String buildSystemPrompt({
  required String base,
  DeviceProfile? device,
  required List<SkillInfo> skills,
  required String projectDir,
  Map<String, String> environment = const {},
}) {
  final b = StringBuffer(base.trim())
    ..writeln()
    ..writeln()
    ..writeln('## 当前设备档案');
  if (device == null) {
    b.writeln('（尚未选择设备。需要设备参数时请提醒用户在右侧设备面板选择手表。）');
  } else {
    b.writeln(device.toPromptText());
    if (device.shape == ScreenShape.suspectedRound && !device.userConfirmed) {
      b.writeln('- 注意：屏幕宽高相等但没有圆屏标志，形状未经用户确认，布局请同时兼容圆屏（内容放在内切圆内）。');
    }
  }
  b
    ..writeln()
    ..writeln('## 可用 skill')
    ..writeln(
      '需要时用 load_skill(name) 读取 SKILL.md 全文，用 read_skill_file(name, relative_path) 读取 references/、templates/ 中的文件。',
    );
  if (skills.isEmpty) {
    b.writeln('（无）');
  } else {
    for (final s in skills) {
      b.writeln('- ${s.name}：${s.description}');
    }
  }
  b
    ..writeln()
    ..writeln('## 当前项目')
    ..writeln('项目目录：$projectDir')
    ..writeln('文件工具只接受相对此目录的路径；run_command 在此目录中用 bash 执行。');
  final envLines = environment.entries
      .where((e) => e.value.trim().isNotEmpty)
      .toList();
  if (envLines.isNotEmpty) {
    b.writeln('run_command 中已设置的环境变量：');
    for (final e in envLines) {
      b.writeln('- ${e.key}=${e.value}');
    }
  }
  return b.toString().trimRight();
}

/// 把会话转换为 API messages：
/// - 跳过只用于界面的消息，不回传 reasoning_content；
/// - 保证每个 tool_call 都有对应的 tool 消息（缺失时补“被中断”），丢弃孤立的 tool 消息；
/// - 最近 [keepRecentTurns] 轮（以用户消息计）保持完整，更早的长工具输出裁剪到 [oldToolChars] 字。
/// 读取图片为 data URL；不存在或过大（>[maxBytes]）时返回 null。
String? imageDataUrl(String path, {int maxBytes = 8 * 1024 * 1024}) {
  final f = File(path);
  if (!f.existsSync()) return null;
  final bytes = f.readAsBytesSync();
  if (bytes.isEmpty || bytes.length > maxBytes) return null;
  final mime = switch (p.extension(path).toLowerCase()) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.webp' => 'image/webp',
    '.gif' => 'image/gif',
    _ => 'image/png',
  };
  return 'data:$mime;base64,${base64Encode(bytes)}';
}

/// OpenAI 多模态 user content：文本 + 图片。
List<Map<String, dynamic>> userParts(String text, List<String> dataUrls) => [
  if (text.trim().isNotEmpty) {'type': 'text', 'text': text},
  for (final u in dataUrls)
    {
      'type': 'image_url',
      'image_url': {'url': u},
    },
];

List<Map<String, dynamic>> buildApiMessages({
  required String systemPrompt,
  required List<ChatMessage> history,
  int keepRecentTurns = 6,
  int oldToolChars = 600,
  bool vision = false,
  int imageTurns = 2,
  String? Function(String path) loadImage = imageDataUrl,
}) {
  final msgs = history.where((m) => !m.uiOnly).toList();
  var cutoff = 0;
  var seen = 0;
  for (var i = msgs.length - 1; i >= 0; i--) {
    if (msgs[i].role == 'user') {
      seen++;
      if (seen == keepRecentTurns) {
        cutoff = i;
        break;
      }
    }
  }
  // 只有最近 [imageTurns] 轮里的图片会真正发给模型（图片很占上下文）。
  var imageCutoff = msgs.length;
  if (vision && imageTurns > 0) {
    var n = 0;
    imageCutoff = 0;
    for (var k = msgs.length - 1; k >= 0; k--) {
      if (msgs[k].role == 'user' && ++n == imageTurns) {
        imageCutoff = k;
        break;
      }
    }
  }
  List<String> urls(int index, List<String> paths) {
    if (!vision || index < imageCutoff) return const [];
    return [for (final x in paths) ?loadImage(x)];
  }

  final out = <Map<String, dynamic>>[
    {'role': 'system', 'content': systemPrompt},
  ];
  var i = 0;
  while (i < msgs.length) {
    final m = msgs[i];
    final old = i < cutoff;
    if (m.role == 'tool') {
      i++; // 孤立的 tool 消息
      continue;
    }
    if (m.role == 'assistant' && m.toolCalls.isNotEmpty) {
      out.add(m.toApiJson());
      final results = <String, ChatMessage>{};
      var j = i + 1;
      final toolImages = <String>[];
      while (j < msgs.length && msgs[j].role == 'tool') {
        results[msgs[j].toolCallId ?? ''] = msgs[j];
        toolImages.addAll(urls(j, msgs[j].images));
        j++;
      }
      for (final call in m.toolCalls) {
        final r = results[call.id];
        var content = r?.content ?? '（无结果：工具执行被中断）';
        if (old && content.length > oldToolChars) {
          content =
              '${content.substring(0, oldToolChars)}\n…（较早的工具输出已裁剪，原长 ${content.length} 字；需要时请重新执行）';
        }
        out.add({'role': 'tool', 'tool_call_id': call.id, 'content': content});
      }
      // tool 消息只能带文本：工具返回的图片（截图、view_image）放进紧随其后的 user 消息。
      if (toolImages.isNotEmpty) {
        out.add({
          'role': 'user',
          'content': userParts('（以上工具调用返回的图片）', toolImages),
        });
      }
      i = j;
      continue;
    }
    if (m.role == 'assistant' && m.content.trim().isEmpty) {
      i++;
      continue;
    }
    if (m.role == 'user' && m.images.isNotEmpty) {
      final u = urls(i, m.images);
      if (u.isNotEmpty) {
        out.add({'role': 'user', 'content': userParts(m.content, u)});
        i++;
        continue;
      }
    }
    out.add(m.toApiJson());
    i++;
  }
  return out;
}

/// 粗略估算字符数，用于决定是否进一步裁剪。
int estimateChars(List<Map<String, dynamic>> msgs) {
  var n = 0;
  for (final m in msgs) {
    final c = m['content'];
    if (c is String) n += c.length;
    if (c is List) {
      for (final part in c.whereType<Map>()) {
        // 图片按 3000 字估算，不按 base64 长度计算。
        n += part['type'] == 'text' ? '${part['text']}'.length : 3000;
      }
    }
    final t = m['tool_calls'];
    if (t is List) {
      for (final x in t) {
        n += '${(x as Map)['function']}'.length;
      }
    }
  }
  return n;
}

class AgentCallbacks {
  /// 会话有变化（新消息、流式增量、工具结果）。
  final void Function() onUpdate;

  /// 每个工具调用开始/结束时记录日志。
  final void Function(String line)? onLog;

  /// 会话需要持久化时调用。
  final Future<void> Function()? onSave;

  const AgentCallbacks({required this.onUpdate, this.onLog, this.onSave});
}

/// Agent 循环：调用模型 → 执行工具 → 回填结果，直到模型不再调用工具、达到步数上限或被停止。
bool _noVision() => false;

class Agent {
  final ChatClient client;
  final ToolExecutor executor;
  final int maxSteps;
  final int keepRecentTurns;
  final int maxContextChars;

  /// 当前模型是否支持图片输入。
  final bool Function() vision;

  /// 发给模型的工具定义。
  final List<Map<String, dynamic>>? tools;

  /// 模型请求遇到可重试错误（网络、超时、429、5xx）时的重试次数和间隔。
  final int retries;
  final Duration retryDelay;

  Agent({
    this.retries = 0,
    this.retryDelay = const Duration(seconds: 3),
    required this.client,
    required this.executor,
    this.vision = _noVision,
    this.maxSteps = 40,
    this.keepRecentTurns = 6,
    this.maxContextChars = 240000,
    this.tools,
  });

  List<Map<String, dynamic>> _messages(String system, Session session) {
    var keep = keepRecentTurns;
    var msgs = buildApiMessages(
      systemPrompt: system,
      history: session.messages,
      keepRecentTurns: keep,
      vision: vision(),
    );
    while (estimateChars(msgs) > maxContextChars && keep > 1) {
      keep--;
      msgs = buildApiMessages(
        systemPrompt: system,
        history: session.messages,
        keepRecentTurns: keep,
        oldToolChars: 300,
        vision: vision(),
        imageTurns: 1,
      );
    }
    return msgs;
  }

  /// 调用模型；遇到可重试的错误时清掉本次不完整的输出，等待 [retryDelay] 后重试，最多 [retries] 次。
  Future<AssistantTurn> _chatWithRetry({
    required List<Map<String, dynamic>> messages,
    required ChatMessage assistant,
    required AgentCallbacks callbacks,
    required CancelToken cancel,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await client.chat(
          messages: messages,
          tools: tools ?? toolSchemas,
          cancel: cancel,
          onDelta: (d) {
            if (d.content.isNotEmpty) assistant.content += d.content;
            if (d.reasoning.isNotEmpty) {
              assistant.reasoning = (assistant.reasoning ?? '') + d.reasoning;
            }
            if (d.partialToolCalls.isNotEmpty) {
              assistant.toolCalls = d.partialToolCalls;
            }
            callbacks.onUpdate();
          },
        );
      } on ApiException catch (e) {
        if (!e.retryable || attempt >= retries || cancel.isCancelled) {
          if (attempt == 0) rethrow;
          throw ApiException('${e.message}（已重试 $attempt 次）');
        }
        assistant
          ..content = ''
          ..reasoning = null
          ..toolCalls = [];
        callbacks.onLog?.call(
          '⟳ 模型请求失败：${e.message}；${retryDelay.inSeconds} 秒后第 ${attempt + 1}/$retries 次重试',
        );
        callbacks.onUpdate();
        await Future.any([
          Future<void>.delayed(retryDelay),
          cancel.whenCancelled,
        ]);
        if (cancel.isCancelled) throw CancelledException();
      }
    }
  }

  /// 运行一次用户请求。用户消息应已加入 [session]。
  Future<void> run({
    required Session session,
    required String systemPrompt,
    required AgentCallbacks callbacks,
    required CancelToken cancel,
  }) async {
    Future<void> save() async => callbacks.onSave?.call();
    for (var step = 1; step <= maxSteps; step++) {
      if (cancel.isCancelled) {
        session.messages.add(ChatMessage.note('已停止。'));
        break;
      }
      final assistant = ChatMessage(role: 'assistant');
      session.messages.add(assistant);
      callbacks.onUpdate();
      AssistantTurn turn;
      try {
        turn = await _chatWithRetry(
          messages: _messages(systemPrompt, session),
          assistant: assistant,
          callbacks: callbacks,
          cancel: cancel,
        );
      } on CancelledException {
        _dropIncomplete(session, assistant);
        session.messages.add(ChatMessage.note('已停止。'));
        await save();
        callbacks.onUpdate();
        return;
      } catch (e) {
        _dropIncomplete(session, assistant);
        session.messages.add(
          ChatMessage.note(
            e is ApiException ? e.message : '调用模型失败：$e',
            error: true,
          ),
        );
        await save();
        callbacks.onUpdate();
        return;
      }
      assistant
        ..content = turn.content
        ..reasoning = turn.reasoning.isEmpty ? null : turn.reasoning
        ..toolCalls = turn.toolCalls;
      if (turn.toolCalls.isEmpty) {
        if (assistant.content.trim().isEmpty && assistant.reasoning == null) {
          session.messages.remove(assistant);
        }
        await save();
        callbacks.onUpdate();
        return;
      }
      await save();
      callbacks.onUpdate();
      for (final call in turn.toolCalls) {
        final msg = ChatMessage(
          role: 'tool',
          toolCallId: call.id,
          toolName: call.name,
          content: '执行中…',
        );
        session.messages.add(msg);
        callbacks.onUpdate();
        if (cancel.isCancelled) {
          msg
            ..content = '用户已停止，未执行。'
            ..isError = true;
          continue;
        }
        callbacks.onLog?.call('▶ ${call.name} ${_short(call.arguments)}');
        final sw = Stopwatch()..start();
        ToolResult r;
        try {
          r = await executor.execute(call.name, call.arguments);
        } catch (e) {
          r = ToolResult.error('工具执行异常：$e');
        }
        msg
          ..content = r.content
          ..isError = r.isError
          ..images = r.images;
        callbacks.onLog?.call(
          '${r.isError ? '✗' : '✓'} ${call.name}（${sw.elapsedMilliseconds} ms）${_short(r.content)}',
        );
        callbacks.onUpdate();
        await save();
      }
    }
    if (!cancel.isCancelled) {
      session.messages.add(
        ChatMessage.note('已达到最大步数 $maxSteps，暂停。可以发送“继续”让我接着做。'),
      );
    }
    await save();
    callbacks.onUpdate();
  }

  static void _dropIncomplete(Session session, ChatMessage assistant) {
    assistant.toolCalls = [];
    if (assistant.content.trim().isEmpty) {
      session.messages.remove(assistant);
    } else {
      assistant.content += '\n（回复被中断）';
    }
  }

  static String _short(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > 120 ? '${one.substring(0, 120)}…' : one;
  }
}
