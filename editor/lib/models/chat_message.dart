/// 一次函数调用。
class ToolCall {
  final String id;
  final String name;
  final String arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };

  factory ToolCall.fromJson(Map<String, dynamic> j) {
    final f = (j['function'] as Map?)?.cast<String, dynamic>() ?? const {};
    return ToolCall(
      id: j['id'] as String? ?? '',
      name: f['name'] as String? ?? '',
      arguments: f['arguments'] as String? ?? '',
    );
  }
}

/// 会话消息。
///
/// [reasoning]（deepseek-reasoner 的 reasoning_content）、[display]、[images]
/// 只用于界面显示，[toApiJson] 不会把它们发给模型；[uiOnly] 的消息（错误提示等）
/// 不会进入发给模型的 messages。
class ChatMessage {
  final String role;
  String content;
  String? display;
  String? reasoning;
  List<ToolCall> toolCalls;
  String? toolCallId;
  String? toolName;
  List<String> images;
  bool uiOnly;
  bool isError;

  ChatMessage({
    required this.role,
    this.content = '',
    this.display,
    this.reasoning,
    List<ToolCall>? toolCalls,
    this.toolCallId,
    this.toolName,
    List<String>? images,
    this.uiOnly = false,
    this.isError = false,
  }) : toolCalls = toolCalls ?? [],
       images = images ?? [];

  factory ChatMessage.user(String content, {String? display}) =>
      ChatMessage(role: 'user', content: content, display: display);

  factory ChatMessage.note(String text, {bool error = false}) => ChatMessage(
    role: 'assistant',
    content: text,
    uiOnly: true,
    isError: error,
  );

  String get shownText => display ?? content;

  /// 发给 chat completions 的格式。
  Map<String, dynamic> toApiJson({String? contentOverride}) {
    final c = contentOverride ?? content;
    final m = <String, dynamic>{'role': role};
    if (role == 'assistant' && toolCalls.isNotEmpty) {
      m['content'] = c.isEmpty ? null : c;
      m['tool_calls'] = toolCalls.map((t) => t.toJson()).toList();
    } else {
      m['content'] = c;
    }
    if (role == 'tool') m['tool_call_id'] = toolCallId ?? '';
    return m;
  }

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    if (display != null) 'display': display,
    if (reasoning != null && reasoning!.isNotEmpty) 'reasoning': reasoning,
    if (toolCalls.isNotEmpty)
      'tool_calls': toolCalls.map((t) => t.toJson()).toList(),
    if (toolCallId != null) 'tool_call_id': toolCallId,
    if (toolName != null) 'tool_name': toolName,
    if (images.isNotEmpty) 'images': images,
    if (uiOnly) 'ui_only': true,
    if (isError) 'is_error': true,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    role: j['role'] as String? ?? 'user',
    content: j['content'] as String? ?? '',
    display: j['display'] as String?,
    reasoning: j['reasoning'] as String?,
    toolCalls: (j['tool_calls'] as List?)
        ?.whereType<Map>()
        .map((e) => ToolCall.fromJson(e.cast<String, dynamic>()))
        .toList(),
    toolCallId: j['tool_call_id'] as String?,
    toolName: j['tool_name'] as String?,
    images: (j['images'] as List?)?.whereType<String>().toList(),
    uiOnly: j['ui_only'] == true,
    isError: j['is_error'] == true,
  );
}

/// 一个项目的会话（持久化到 <项目>/.editor/session.json）。
class Session {
  final List<ChatMessage> messages;
  String? lastLogcatPath;
  String? lastScreenshot;

  Session({
    List<ChatMessage>? messages,
    this.lastLogcatPath,
    this.lastScreenshot,
  }) : messages = messages ?? [];

  Map<String, dynamic> toJson() => {
    'version': 1,
    'messages': messages.map((m) => m.toJson()).toList(),
    'lastLogcatPath': lastLogcatPath,
    'lastScreenshot': lastScreenshot,
  };

  factory Session.fromJson(Map<String, dynamic> j) => Session(
    messages: (j['messages'] as List?)
        ?.whereType<Map>()
        .map((e) => ChatMessage.fromJson(e.cast<String, dynamic>()))
        .toList(),
    lastLogcatPath: j['lastLogcatPath'] as String?,
    lastScreenshot: j['lastScreenshot'] as String?,
  );
}
