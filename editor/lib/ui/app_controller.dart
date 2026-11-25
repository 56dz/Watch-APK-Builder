import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/app_config.dart';
import '../models/chat_message.dart';
import '../models/device_profile.dart';
import '../services/adb_service.dart';
import '../services/agent.dart';
import '../services/anthropic_client.dart';
import '../services/bundled_tools.dart';
import '../services/config_store.dart';
import '../services/deepseek_client.dart';
import '../services/device_profiler.dart';
import '../services/process_runner.dart';
import '../services/session_store.dart';
import '../services/skill_registry.dart';
import '../services/tools.dart';
import '../services/web_search.dart';

/// 生产环境的资源读取（rootBundle + AssetManifest）。
class BundleAssetReader implements AssetReader {
  final AssetBundle bundle;
  BundleAssetReader([AssetBundle? b]) : bundle = b ?? rootBundle;

  @override
  Future<List<String>> listAssets() async =>
      (await AssetManifest.loadFromAssetBundle(bundle)).listAssets();

  @override
  Future<String> loadString(String key) => bundle.loadString(key, cache: false);

  @override
  Future<List<int>> loadBytes(String key) async =>
      (await bundle.load(key)).buffer.asUint8List();
}

/// 把 Windows 路径转成正斜杠形式（MSYS bash 与 Windows 程序都认）。
String forwardSlashes(String s) => s.replaceAll('\\', '/');

/// 权限询问回调：[title] 操作类型，[detail] 具体内容。
typedef PermissionHandler = Future<bool> Function(String title, String detail);

/// 应用状态：配置、设备、项目、会话、agent 运行。
class AppController extends ChangeNotifier {
  final ProcessRunner runner;
  final http.Client httpClient;
  final ConfigStore configStore;
  final AssetReader assets;
  final Map<String, String> environment;

  /// 软件根目录布局（tools/、skills/、config/、workspace/）。
  final AppPaths paths;

  AppConfig config = const AppConfig();
  late final AdbService adb = AdbService(runner, () => adbPath);

  String get adbPath => toolOr(paths.adb, 'adb');
  String get sdkPath => toolOr(paths.sdk, '', directory: true);
  String get jdkPath => toolOr(paths.jdk, '', directory: true);
  String get pythonPath => toolOr(paths.python, 'python');
  String get bashPath => toolOr(paths.bash, 'bash');
  String? get r8Path => File(paths.r8).existsSync() ? paths.r8 : null;

  late final DeviceStore deviceStore = DeviceStore(configStore.devicesFile);
  late final DeviceProfiler profiler = DeviceProfiler(adb, deviceStore);

  /// skill 只从软件根目录的 skills/ 读取；首次启动时把随软件打包的 skill 释放到那里。
  late final SkillRegistry skills = SkillRegistry(
    const NoAssetReader(),
    () => [paths.skills],
  );

  late final DeepSeekClient _openAiClient = DeepSeekClient(
    httpClient: httpClient,
    apiKey: () => config.apiKey,
    baseUrl: () => config.baseUrl,
    model: () => config.model,
    timeout: () => Duration(seconds: config.requestTimeoutSec),
  );
  late final AnthropicClient _anthropicClient = AnthropicClient(
    httpClient: httpClient,
    apiKey: () => config.apiKey,
    baseUrl: () => config.baseUrl,
    model: () => config.model,
    timeout: () => Duration(seconds: config.requestTimeoutSec),
  );

  /// 按设置中的接口格式选择客户端。
  ChatClient get client => config.apiFormat == ApiFormat.anthropic
      ? _anthropicClient
      : _openAiClient;

  bool loading = true;
  String basePrompt = '';

  List<AdbDevice> devices = [];
  String? selectedSerial;
  DeviceProfile? profile;
  bool profileFromStore = false;
  bool deviceBusy = false;
  String? deviceError;

  /// 自动检测：定时执行 adb devices，插拔手表后自动刷新并选中。
  bool autoDetect = true;
  final Duration pollInterval;
  Timer? _pollTimer;
  bool _polling = false;
  bool _disposed = false;
  String? _lastDeviceSig;

  /// 当前打开的项目（绝对路径）。
  String? currentProject;
  Session session = Session();

  bool running = false;
  CancelToken? _cancel;
  final List<String> logs = [];

  /// 由界面设置：“每次询问”模式下弹窗确认。
  PermissionHandler? confirmHandler;

  AppController({
    required this.runner,
    required this.httpClient,
    required this.configStore,
    required this.assets,
    required this.paths,
    this.environment = const {},
    this.pollInterval = const Duration(seconds: 3),
  });

  /// 左侧项目列表（绝对路径）。
  List<String> get projects => config.projects;
  String? get projectDir => currentProject;
  static String projectName(String path) => p.basename(path);

  Future<void> init() async {
    config = await configStore.load(
      AppConfig.defaults(defaultWorkspace: paths.workspace),
    );
    try {
      basePrompt = await assets.loadString('assets/prompts/system_prompt.md');
    } catch (_) {
      basePrompt = '你是安卓手表 App 开发助手。';
    }
    final seeded = await seedSkills(assets, paths.skills);
    if (seeded > 0) log('已释放 $seeded 个 skill 文件到 ${paths.skills}');
    await skills.reload();
    await _migrateProjects();
    final missing = paths.missingTools();
    if (missing.isNotEmpty) {
      log('软件根目录 tools/ 下缺少：${missing.join('、')}（构建或 adb 可能不可用）');
    }
    loading = false;
    notifyListeners();
    unawaited(refreshDevices());
    _startAutoDetect();
  }

  /// 首次启动（项目列表为空）时，把默认工作区里已有的项目目录加入列表。
  Future<void> _migrateProjects() async {
    if (config.projects.isNotEmpty) {
      return;
    }
    final found = [
      for (final w in config.workspaces)
        for (final n in Workspace(w).listProjects()) p.join(w, n),
    ];
    if (found.isEmpty) return;
    config = config.copyWith(projects: found);
    await _persistConfig();
  }

  void _startAutoDetect() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!autoDetect || _disposed) return;
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(pollDevices()));
  }

  void setAutoDetect(bool value) {
    autoDetect = value;
    _startAutoDetect();
    log(value ? '已开启设备自动检测' : '已关闭设备自动检测');
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void log(String line) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    logs.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} $line');
    if (logs.length > 500) logs.removeRange(0, logs.length - 500);
    notifyListeners();
  }

  Future<void> _persistConfig() async {
    try {
      await configStore.save(config);
    } on FileSystemException catch (e) {
      log('保存设置失败：${e.message}');
    }
  }

  Future<void> saveConfig(AppConfig c) async {
    config = c;
    await _persistConfig();
    await skills.reload();
    log('设置已保存');
    notifyListeners();
  }

  /// 导入 .md 文件或 skill 文件夹到 skills/；同名时抛 [SkillExistsException]。
  Future<SkillImport> importSkill(
    String source, {
    bool overwrite = false,
  }) async {
    final r = await importSkillFrom(source, paths.skills, overwrite: overwrite);
    await skills.reload();
    log('已导入 skill：${r.name}（${r.files} 个文件）');
    notifyListeners();
    return r;
  }

  /// 重新扫描 skills/ 目录。
  Future<void> reloadSkills() async {
    await skills.reload();
    log('已重新加载 skill：${skills.skills.length} 个');
    notifyListeners();
  }

  // ---------------- 设备 ----------------

  /// 手动刷新（刷新按钮、启动时）。
  Future<void> refreshDevices() async {
    deviceBusy = true;
    deviceError = null;
    notifyListeners();
    List<AdbDevice>? list;
    try {
      list = await adb.devices();
    } on AdbException catch (e) {
      deviceError = e.message;
    } finally {
      deviceBusy = false;
      notifyListeners();
    }
    if (list != null) await _applyDevices(list, announce: false);
  }

  /// 自动检测的一次轮询：设备列表（序列号 + 状态）有变化时才更新界面。
  Future<void> pollDevices() async {
    if (_polling || deviceBusy || _disposed) return;
    _polling = true;
    try {
      final list = await adb.devices();
      final sig = list.map((d) => '${d.serial}:${d.state}').join(',');
      if (sig == _lastDeviceSig && (list.isNotEmpty || deviceError != null))
        return;
      await _applyDevices(list, announce: true);
    } on AdbException catch (e) {
      _lastDeviceSig = null;
      if (deviceError != e.message) {
        deviceError = e.message;
        notifyListeners();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _applyDevices(
    List<AdbDevice> list, {
    required bool announce,
  }) async {
    if (_disposed) return;
    final before = {for (final d in devices) d.serial: d.state};
    _lastDeviceSig = list.map((d) => '${d.serial}:${d.state}').join(',');
    if (announce) {
      for (final d in list) {
        if (before[d.serial] == null)
          log('检测到设备：${d.model.isEmpty ? d.serial : d.model}（${d.stateLabel}）');
        else if (before[d.serial] != d.state)
          log(
            '设备状态变化：${d.model.isEmpty ? d.serial : d.model} → ${d.stateLabel}',
          );
      }
      for (final s in before.keys) {
        if (!list.any((d) => d.serial == s)) log('设备已断开：$s');
      }
    }
    devices = list;
    final online = list.where((d) => d.isOnline).toList();
    if (selectedSerial != null &&
        !online.any((d) => d.serial == selectedSerial)) {
      selectedSerial = null;
      profile = null;
    }
    deviceError = null;
    if (list.isEmpty) {
      deviceError = autoDetect
          ? '没有检测到设备。请用 USB 连接手表并开启 adb 调试，连接后会自动识别。'
          : '没有检测到设备。请用 USB 连接手表并开启 adb 调试。';
    } else if (online.isEmpty) {
      final d = list.first;
      deviceError = d.state == 'unauthorized'
          ? '设备 ${d.serial} 未授权：请在手表上点“允许 USB 调试”，授权后会自动识别。'
          : '设备 ${d.serial} 当前状态为 ${d.stateLabel}：请重新插拔 USB。';
    }
    notifyListeners();
    if (selectedSerial == null && online.isNotEmpty) {
      // 优先选新出现的设备，否则选第一台在线设备。
      final fresh = online.where(
        (d) => !before.containsKey(d.serial) || before[d.serial] != 'device',
      );
      await selectDevice(
        (fresh.isNotEmpty ? fresh.first : online.first).serial,
      );
    }
  }

  Future<void> selectDevice(String serial, {bool resample = false}) async {
    selectedSerial = serial;
    deviceBusy = true;
    deviceError = null;
    notifyListeners();
    try {
      final model = await adb.getProp(serial, 'ro.product.model');
      final r = await profiler.profileFor(
        serial,
        model: model,
        resample: resample,
      );
      profile = r.profile;
      profileFromStore = r.fromStore;
      log(
        '${r.fromStore ? '读取设备档案' : '已采样设备'}：${r.profile.model} ${r.profile.shape.label} ${r.profile.widthPx}x${r.profile.heightPx}',
      );
    } on AdbException catch (e) {
      deviceError = e.message;
      profile = null;
    } finally {
      deviceBusy = false;
      notifyListeners();
    }
  }

  Future<void> confirmShape(ScreenShape shape) async {
    final pr = profile;
    if (pr == null) return;
    profile = pr.copyWith(shape: shape, userConfirmed: true);
    await deviceStore.put(profile!);
    log('已确认 ${pr.model} 为${shape.label}');
    notifyListeners();
  }

  // ---------------- 项目与会话 ----------------

  /// 在 [workspace] 下新建项目 [name] 并打开。返回错误提示，null 表示成功。
  Future<String?> createProject(String name, {String? workspace}) async {
    final ws = (workspace ?? config.defaultWorkspace).trim();
    if (ws.isEmpty) return '请选择工作区';
    String dir;
    try {
      await Directory(ws).create(recursive: true);
      dir = await Workspace(ws).create(name);
    } on FormatException catch (e) {
      return e.message;
    } on FileSystemException catch (e) {
      return '创建失败：${e.message}';
    }
    final norm = p.normalize(ws);
    final wss = [
      ...config.workspaces,
      if (!config.workspaces.any((w) => p.equals(w, norm))) norm,
    ];
    config = config.copyWith(
      workspaces: wss,
      projects: [...config.projects.where((x) => !p.equals(x, dir)), dir],
    );
    await _persistConfig();
    await openProject(dir);
    return null;
  }

  Future<void> openProject(String path) async {
    if (running) return;
    currentProject = path;
    session = await SessionStore.load(path);
    notifyListeners();
  }

  Future<void> _saveSession() async {
    final dir = projectDir;
    if (dir == null) return;
    try {
      await SessionStore.save(dir, session);
    } on FileSystemException catch (e) {
      log('保存会话失败：${e.message}');
    }
  }

  /// 从列表中删除会话：删除对话记录，项目文件保留在磁盘上。
  Future<void> deleteSession(String path) async {
    if (running) return;
    await SessionStore.delete(path);
    config = config.copyWith(
      projects: config.projects.where((x) => !p.equals(x, path)).toList(),
    );
    await _persistConfig();
    if (currentProject != null && p.equals(currentProject!, path)) {
      currentProject = null;
      session = Session();
    }
    log('已删除会话：${projectName(path)}（项目文件保留在 ${forwardSlashes(path)}）');
    notifyListeners();
  }

  /// 移除全部会话。
  Future<void> deleteAllSessions() async {
    if (running) return;
    for (final x in config.projects) {
      await SessionStore.delete(x);
    }
    final n = config.projects.length;
    config = config.copyWith(projects: const []);
    await _persistConfig();
    currentProject = null;
    session = Session();
    log('已移除全部会话（$n 个），项目文件保留在磁盘上');
    notifyListeners();
  }

  Future<void> clearSession() async {
    if (running) return;
    session = Session();
    await _saveSession();
    notifyListeners();
  }

  /// 清空某个项目的对话记录（项目保留在列表中，项目文件不动）。
  Future<void> clearSessionOf(String path) async {
    if (running) return;
    if (currentProject != null && p.equals(currentProject!, path)) {
      await clearSession();
    } else {
      await SessionStore.delete(path);
    }
    log('已清空对话：${projectName(path)}');
    notifyListeners();
  }

  /// 把工作区加入列表（新建项目对话框中选择的文件夹）。
  Future<void> addWorkspace(String dir) async {
    final norm = p.normalize(dir);
    if (config.workspaces.any((w) => p.equals(w, norm))) return;
    config = config.copyWith(workspaces: [...config.workspaces, norm]);
    await _persistConfig();
    notifyListeners();
  }

  Map<String, String> get commandEnv {
    final sdk = sdkPath, jdk = jdkPath, py = pythonPath, adbExe = adbPath;
    // 把工具目录放到 PATH 最前面，命令里直接写 adb / java / python 也能用自带的。
    final extra = <String>[
      if (p.isAbsolute(adbExe)) p.dirname(adbExe),
      if (jdk.isNotEmpty) p.join(jdk, 'bin'),
      if (p.isAbsolute(py)) p.dirname(py),
    ];
    final pathKey = environment.keys.firstWhere(
      (k) => k.toLowerCase() == 'path',
      orElse: () => 'PATH',
    );
    return {
      if (sdk.isNotEmpty) 'SDK': forwardSlashes(sdk),
      if (sdk.isNotEmpty) 'ANDROID_HOME': forwardSlashes(sdk),
      if (jdk.isNotEmpty) 'JDK': forwardSlashes(jdk),
      if (jdk.isNotEmpty) 'JAVA_HOME': jdk,
      if (py.isNotEmpty) 'PYTHON': forwardSlashes(py),
      if (adbExe.isNotEmpty) 'ADB': forwardSlashes(adbExe),
      'R8_JAR': ?(r8Path == null ? null : forwardSlashes(r8Path!)),
      if (extra.isNotEmpty)
        pathKey: [...extra, ?environment[pathKey]].join(';'),
      'ANDROID_SERIAL': ?selectedSerial,
      // 不要全局设置 MSYS_NO_PATHCONV=1：build.sh 里 pwd 得到的 /c/... 路径
      // 需要 MSYS 自动转换后才能传给 aapt2.exe 等 Windows 程序。
    };
  }

  // ---------------- Agent ----------------

  /// 把用户附加的图片复制到 <项目>/attachments/，返回新路径。
  Future<List<String>> _importImages(String dir, List<String> images) async {
    final out = <String>[];
    if (images.isEmpty) return out;
    final att = Directory(p.join(dir, 'attachments'));
    await att.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    var i = 0;
    for (final src in images) {
      final f = File(src);
      if (!f.existsSync()) continue;
      final ext = p.extension(src).toLowerCase();
      if (!imageExtensions.contains(ext)) continue;
      final dst = p.join(att.path, 'img_${stamp}_${i++}$ext');
      await f.copy(dst);
      out.add(dst);
    }
    return out;
  }

  /// 发送用户消息并运行 agent；返回错误提示（null 表示已开始）。
  /// [images] 为用户附加的图片文件路径。
  Future<String?> send(
    String text, {
    String? display,
    List<String> images = const [],
  }) async {
    final dir = projectDir;
    if (dir == null) return '请先在左侧新建或选择一个项目';
    if (running) return '正在运行中';
    if (!config.hasApiKey) return '请先在设置中填写 API Key';
    final input = text.trim();
    if (input.isEmpty && images.isEmpty) return null;

    await skills.reload();
    final slash = skills.parseSlash(input);
    var content = input;
    if (slash.names.isNotEmpty) {
      final b = StringBuffer();
      for (final n in slash.names) {
        try {
          b
            ..writeln('<skill name="$n">')
            ..writeln(await skills.loadSkill(n))
            ..writeln('</skill>');
        } on SkillException catch (e) {
          return e.message;
        }
      }
      b
        ..writeln()
        ..writeln('用户显式调用了以上 skill，请按其中的说明完成下面的请求：')
        ..write(slash.rest.isEmpty ? '（按 skill 的说明开始）' : slash.rest);
      content = b.toString();
      log('注入 skill：${slash.names.join('、')}');
    }
    await Directory(dir).create(recursive: true);
    final imported = await _importImages(dir, images);
    if (imported.isNotEmpty) {
      final rel = imported
          .map((x) => forwardSlashes(p.relative(x, from: dir)))
          .join('、');
      content +=
          '\n\n（用户附加了 ${imported.length} 张图片，已保存到项目内：$rel'
          '${config.vision ? '' : '。当前模型未开启图片输入，你看不到图片内容，需要时请让用户描述'}）';
    }
    session.messages.add(
      ChatMessage(
        role: 'user',
        content: content,
        display: display ?? (content == input ? null : input),
        images: imported,
      ),
    );
    await _saveSession();

    running = true;
    final cancel = _cancel = CancelToken();
    notifyListeners();

    final executor = ToolExecutor(
      ToolEnvironment(
        projectDir: dir,
        runner: runner,
        adb: adb,
        skills: skills,
        serial: () => selectedSerial,
        bashPath: bashPath,
        extraEnv: commandEnv,
        askPermission: () => config.askPermission,
        confirm: (title, detail) async =>
            await confirmHandler?.call(title, detail) ?? false,
        vision: () => config.vision,
        commandTimeout: Duration(seconds: config.commandTimeoutSec),
        onScreenshot: (path) => session.lastScreenshot = path,
        onLogcat: (path) => session.lastLogcatPath = path,
        web: config.webSearch ? WebSearch(client: httpClient) : null,
        searchEngine: () => config.searchEngine,
        skillsDir: paths.skills,
        onSkillSaved: (name) =>
            log('已保存 skill：$name（${forwardSlashes(paths.skills)}/$name）'),
      ),
    );
    final agent = Agent(
      client: client,
      executor: executor,
      maxSteps: config.maxSteps,
      retries: config.retryCount,
      retryDelay: Duration(seconds: config.retryDelaySec),
      vision: () => config.vision,
      tools: toolSchemasFor(web: config.webSearch),
    );
    final system = buildSystemPrompt(
      base: basePrompt,
      device: profile,
      skills: skills.skills,
      projectDir: dir,
      environment: commandEnv,
    );
    try {
      await agent.run(
        session: session,
        systemPrompt: system,
        cancel: cancel,
        callbacks: AgentCallbacks(
          onUpdate: notifyListeners,
          onLog: log,
          onSave: _saveSession,
        ),
      );
    } finally {
      running = false;
      _cancel = null;
      await _saveSession();
      notifyListeners();
    }
    return null;
  }

  void stop() {
    _cancel?.cancel();
    log('请求停止');
  }

  /// “报告 Bug”的上下文：最近一次 logcat 内容（截尾）和截图路径。
  Future<String> bugReportContext() async {
    final b = StringBuffer();
    final logPath = session.lastLogcatPath;
    if (logPath != null && File(logPath).existsSync()) {
      var text = await File(logPath).readAsString();
      if (text.length > 6000) text = text.substring(text.length - 6000);
      b
        ..writeln('最近一次 logcat（${forwardSlashes(logPath)}，末尾部分）：')
        ..writeln('```')
        ..writeln(text.trim())
        ..writeln('```');
    } else {
      b.writeln('（还没有 logcat 记录，可用 adb logcat 获取）');
    }
    final shot = session.lastScreenshot;
    b.writeln(shot != null ? '最近一次截图：${forwardSlashes(shot)}' : '（还没有截图）');
    return b.toString();
  }
}

/// "总结经验"按钮发给 agent 的指令。[extra] 是用户在输入框里写的补充要求。
String summarizeSkillPrompt([String extra = '']) {
  final b = StringBuffer()
    ..writeln(
      '请回顾本次对话从头到现在的全部过程，把踩过的坑、注意事项和可复用的经验整理成一个新的 skill，用 save_skill 工具保存。',
    )
    ..writeln()
    ..writeln('要求：')
    ..writeln(
      '1. 只写本次对话里真实遇到并验证过的内容：报错原文和根因、最终有效的解决办法、构建/安装/adb 的正确命令、设备与屏幕适配（形状、分辨率、安全边距）、接口与数据解析细节。不要编造，不要写泛泛的常识。',
    )
    ..writeln('2. 每条坑写成"现象 → 原因 → 解决办法"；必要时附关键代码片段或命令。')
    ..writeln('3. 结构：适用场景、设备信息、构建流程、踩坑清单、注意事项、可复用代码片段。')
    ..writeln('4. name 用小写英文加连字符，体现设备或主题；description 一句话说清什么时候该加载它。')
    ..writeln(
      '5. 保存前先看已有 skill 列表：如果已有覆盖同一主题的 skill，先 load_skill 读出来，把新经验合并进去后用 overwrite=true 覆盖；否则新建。不要修改内置 skill（oppo-watch2-apk）。',
    )
    ..writeln('6. 保存后用一两句话告诉我 skill 名称和收录了哪几条要点。');
  if (extra.isNotEmpty) {
    b
      ..writeln()
      ..writeln('补充要求：$extra');
  }
  return b.toString().trimRight();
}
