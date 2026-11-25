/// 接口格式。
enum ApiFormat {
  openai('openai', 'OpenAI 兼容（/chat/completions）'),
  anthropic('anthropic', 'Anthropic（/v1/messages）');

  final String id;
  final String label;
  const ApiFormat(this.id, this.label);

  static ApiFormat fromId(String? id) => ApiFormat.values.firstWhere(
    (f) => f.id == id,
    orElse: () => ApiFormat.openai,
  );
}

/// 对话权限。
enum PermissionMode {
  full('full', '完全权限', '写文件、执行命令、安装和 adb shell 直接执行'),
  ask('ask', '每次询问', '写文件、执行命令、安装和 adb shell 每次执行前弹窗确认');

  final String id;
  final String label;
  final String description;
  const PermissionMode(this.id, this.label, this.description);

  static PermissionMode fromId(String? id) => PermissionMode.values.firstWhere(
    (m) => m.id == id,
    orElse: () => PermissionMode.ask,
  );
}

/// 常用模型接口预设。
class ModelPreset {
  final String name;
  final ApiFormat format;
  final String baseUrl;
  final String model;
  final bool vision;
  const ModelPreset(
    this.name,
    this.format,
    this.baseUrl,
    this.model,
    this.vision,
  );
}

/// 应用配置（便携版：保存在软件根目录 config/config.json）。
/// API Key 只保存在本地，toString() 不会输出它。
class AppConfig {
  final ApiFormat apiFormat;
  final String apiKey;
  final String baseUrl;
  final String model;

  /// 模型是否支持图片输入（截图、用户附图会以图片形式发给模型）。
  final bool vision;
  final PermissionMode permission;

  /// 已知工作区（新建项目时可选），第一个是默认工作区。
  final List<String> workspaces;

  /// 左侧列表中的项目（绝对路径，可分布在不同工作区）。
  final List<String> projects;
  final int maxSteps;
  final int commandTimeoutSec;

  /// 是否给模型开放 web_search / web_fetch（免费引擎）。
  final bool webSearch;

  /// 首选搜索引擎：auto / bing / ddg / ddg-lite / searxng。
  final String searchEngine;

  /// 模型响应超时（秒）：等待响应头或流式数据中断超过这个时间就算失败。
  final int requestTimeoutSec;

  /// 模型请求失败（网络错误、超时、429、5xx）后的重试次数，0 表示不重试。
  final int retryCount;

  /// 两次重试之间等待的秒数。
  final int retryDelaySec;

  static const String defaultBaseUrl = 'https://api.deepseek.com';
  static const String defaultModel = 'deepseek-chat';

  static const List<ModelPreset> presets = [
    ModelPreset(
      'DeepSeek',
      ApiFormat.openai,
      'https://api.deepseek.com',
      'deepseek-chat',
      false,
    ),
    ModelPreset(
      'DeepSeek 推理',
      ApiFormat.openai,
      'https://api.deepseek.com',
      'deepseek-reasoner',
      false,
    ),
    ModelPreset(
      'OpenAI',
      ApiFormat.openai,
      'https://api.openai.com/v1',
      'gpt-4o',
      true,
    ),
    ModelPreset(
      'Anthropic Claude',
      ApiFormat.anthropic,
      'https://api.anthropic.com',
      'claude-sonnet-4-5',
      true,
    ),
  ];

  const AppConfig({
    this.apiFormat = ApiFormat.openai,
    this.apiKey = '',
    this.baseUrl = defaultBaseUrl,
    this.model = defaultModel,
    this.vision = false,
    this.permission = PermissionMode.ask,
    this.workspaces = const [],
    this.projects = const [],
    this.maxSteps = 40,
    this.commandTimeoutSec = 300,
    this.webSearch = true,
    this.searchEngine = 'auto',
    this.requestTimeoutSec = 120,
    this.retryCount = 2,
    this.retryDelaySec = 3,
  });

  /// 默认配置：默认工作区为软件根目录下的 workspace/。
  factory AppConfig.defaults({required String defaultWorkspace}) =>
      AppConfig(workspaces: [defaultWorkspace]);

  bool get hasApiKey => apiKey.trim().isNotEmpty;
  bool get askPermission => permission == PermissionMode.ask;
  String get defaultWorkspace => workspaces.isEmpty ? '' : workspaces.first;

  AppConfig copyWith({
    ApiFormat? apiFormat,
    String? apiKey,
    String? baseUrl,
    String? model,
    bool? vision,
    PermissionMode? permission,
    List<String>? workspaces,
    List<String>? projects,
    int? maxSteps,
    int? commandTimeoutSec,
    bool? webSearch,
    String? searchEngine,
    int? requestTimeoutSec,
    int? retryCount,
    int? retryDelaySec,
  }) {
    return AppConfig(
      apiFormat: apiFormat ?? this.apiFormat,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      vision: vision ?? this.vision,
      permission: permission ?? this.permission,
      workspaces: workspaces ?? this.workspaces,
      projects: projects ?? this.projects,
      maxSteps: maxSteps ?? this.maxSteps,
      commandTimeoutSec: commandTimeoutSec ?? this.commandTimeoutSec,
      webSearch: webSearch ?? this.webSearch,
      searchEngine: searchEngine ?? this.searchEngine,
      requestTimeoutSec: requestTimeoutSec ?? this.requestTimeoutSec,
      retryCount: retryCount ?? this.retryCount,
      retryDelaySec: retryDelaySec ?? this.retryDelaySec,
    );
  }

  Map<String, dynamic> toJson() => {
    'apiFormat': apiFormat.id,
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'model': model,
    'vision': vision,
    'permission': permission.id,
    'workspaces': workspaces,
    'projects': projects,
    'maxSteps': maxSteps,
    'commandTimeoutSec': commandTimeoutSec,
    'webSearch': webSearch,
    'searchEngine': searchEngine,
    'requestTimeoutSec': requestTimeoutSec,
    'retryCount': retryCount,
    'retryDelaySec': retryDelaySec,
  };

  /// 缺失的字段取 [defaults] 中的值。
  factory AppConfig.fromJson(Map<String, dynamic> j, AppConfig defaults) {
    String s(String k, String d) => j[k] is String ? j[k] as String : d;
    int i(String k, int d) => j[k] is num ? (j[k] as num).toInt() : d;
    List<String> list(String k) => j[k] is List
        ? (j[k] as List)
              .whereType<String>()
              .where((w) => w.trim().isNotEmpty)
              .toList()
        : <String>[];
    final ws = list('workspaces');
    return AppConfig(
      apiFormat: j['apiFormat'] is String
          ? ApiFormat.fromId(j['apiFormat'] as String)
          : defaults.apiFormat,
      apiKey: s('apiKey', defaults.apiKey),
      baseUrl: s('baseUrl', defaults.baseUrl),
      model: s('model', defaults.model),
      vision: j['vision'] is bool ? j['vision'] as bool : defaults.vision,
      permission: j['permission'] is String
          ? PermissionMode.fromId(j['permission'] as String)
          : defaults.permission,
      workspaces: ws.isEmpty ? defaults.workspaces : ws,
      projects: j['projects'] is List ? list('projects') : defaults.projects,
      maxSteps: i('maxSteps', defaults.maxSteps).clamp(1, 200),
      commandTimeoutSec: i(
        'commandTimeoutSec',
        defaults.commandTimeoutSec,
      ).clamp(5, 3600),
      webSearch: j['webSearch'] is bool
          ? j['webSearch'] as bool
          : defaults.webSearch,
      searchEngine: s('searchEngine', defaults.searchEngine),
      requestTimeoutSec: i(
        'requestTimeoutSec',
        defaults.requestTimeoutSec,
      ).clamp(10, 1800),
      retryCount: i('retryCount', defaults.retryCount).clamp(0, 10),
      retryDelaySec: i('retryDelaySec', defaults.retryDelaySec).clamp(0, 300),
    );
  }

  @override
  String toString() =>
      'AppConfig(format: ${apiFormat.id}, baseUrl: $baseUrl, model: $model, '
      'apiKey: ${hasApiKey ? '******' : '未设置'}, permission: ${permission.id}, '
      'webSearch: $webSearch, workspaces: $workspaces)';
}
