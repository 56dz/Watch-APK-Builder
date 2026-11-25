import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/app_config.dart';
import '../models/chat_message.dart';
import '../services/file_dialogs.dart';
import '../services/skill_registry.dart';
import '../models/device_profile.dart';
import 'app_controller.dart';
import 'glass.dart';
import 'message_view.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  final AppController controller;
  const HomePage({super.key, required this.controller});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  /// 待发送的附加图片。
  final List<String> _attachments = [];

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.confirmHandler = _confirmPermission;
    c.addListener(_onChange);
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    _input.dispose();
    _lateJump?.cancel();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 上一次渲染的项目；切换项目后滚到对话末尾。
  String? _shownProject;

  /// 对话区从第几条消息开始显示。打开项目时只显示最后一轮（最后一条用户消息起），
  /// 滑到顶部点“加载更多”再往前加载一轮。
  int _start = 0;

  /// 第 [from] 条之前最近一轮的起点（用户消息）；没有更早的就返回 0。
  static int _roundStart(List<ChatMessage> msgs, int from) {
    for (var i = from - 1; i >= 0; i--) {
      if (msgs[i].role == 'user') return i;
    }
    return 0;
  }

  /// 往前多加载一轮，并保持当前看到的内容不动（新增的高度补到滚动偏移上）。
  void _loadEarlier() {
    final msgs = c.session.messages;
    final before = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    setState(() => _start = _roundStart(msgs, _start));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      pos.jumpTo(
        (pos.pixels + pos.maxScrollExtent - before).clamp(
          0.0,
          pos.maxScrollExtent,
        ),
      );
    });
  }

  void _onChange() {
    if (!mounted) return;
    // 只有原本就停在底部附近时才跟随新输出，用户往上翻看时不打扰。
    final follow = c.running && _atBottom();
    setState(() {});
    if (follow) _scrollToEnd();
  }

  bool _atBottom() {
    if (!_scroll.hasClients) return true;
    final pos = _scroll.position;
    return pos.maxScrollExtent - pos.pixels < 48;
  }

  /// 等布局完成后跳到末尾；图片解码会晚一两帧改变高度，再补跳一次。
  Timer? _lateJump;

  void _scrollToEnd() {
    void jump() {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      jump();
      _lateJump?.cancel();
      _lateJump = Timer(const Duration(milliseconds: 120), jump);
    });
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// “每次询问”模式：写文件、执行命令、安装、adb shell 前弹窗。
  Future<bool> _confirmPermission(String title, String detail) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('允许 AI $title？'),
        content: SizedBox(
          width: 620,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(
              detail,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('拒绝'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx, true);
              await c.saveConfig(
                c.config.copyWith(permission: PermissionMode.full),
              );
            },
            child: const Text('允许，并切换为完全权限'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('允许'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _send([String? text, String? display]) async {
    final t = text ?? _input.text;
    final imgs = text == null ? List<String>.of(_attachments) : <String>[];
    if (t.trim().isEmpty && imgs.isEmpty) return;
    if (text == null) {
      _input.clear();
      setState(_attachments.clear);
    }
    final err = await c.send(
      t.trim().isEmpty ? '请看我附加的图片。' : t,
      display: display,
      images: imgs,
    );
    if (err != null) {
      if (text == null) {
        _input.text = t;
        setState(() => _attachments.addAll(imgs));
      }
      _toast(err);
    }
  }

  /// 让 agent 把本次对话的经验写成 skill。输入框里有文字时作为补充要求一起发送。
  Future<void> _summarizeSkill() async {
    final extra = _input.text.trim();
    if (extra.isNotEmpty) _input.clear();
    await _send(
      summarizeSkillPrompt(extra),
      extra.isEmpty ? '总结经验，写入新的 skill' : '总结经验，写入新的 skill：$extra',
    );
  }

  Future<void> _pickImages() async {
    final files = await FileDialogs.pickImages();
    if (files.isEmpty || !mounted) return;
    setState(() {
      for (final f in files) {
        if (!_attachments.contains(f)) _attachments.add(f);
      }
    });
    if (!c.config.vision) {
      _toast('当前模型未开启“支持图片输入”，图片会保存到项目里，但模型看不到图片内容。可在设置中切换。');
    }
  }

  Future<void> _newProject() async {
    final ctl = TextEditingController();
    final workspaces = [...c.config.workspaces];
    var ws = c.config.defaultWorkspace;
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('新建项目'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: ctl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '项目名（作为工作区下的子目录名）',
                    hintText: '例如 step_counter',
                  ),
                  onSubmitted: (v) => Navigator.pop(ctx, (v, ws)),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: ws,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '工作区'),
                        items: [
                          for (final w in workspaces)
                            DropdownMenuItem(
                              value: w,
                              child: Text(
                                w == c.config.defaultWorkspace ? '$w（默认）' : w,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setD(() => ws = v ?? ws),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final d = await FileDialogs.pickDirectory(initial: ws);
                        if (d == null) return;
                        final n = p.normalize(d);
                        setD(() {
                          if (!workspaces.any((w) => p.equals(w, n))) {
                            workspaces.add(n);
                          }
                          ws = workspaces.firstWhere((w) => p.equals(w, n));
                        });
                      },
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('浏览…'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '项目将创建在：${p.join(ws, ctl.text.trim().isEmpty ? '<项目名>' : ctl.text.trim())}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, (ctl.text, ws)),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    ctl.dispose();
    if (result == null || result.$1.trim().isEmpty) return;
    final err = await c.createProject(result.$1, workspace: result.$2);
    if (err != null) _toast(err);
  }

  Future<bool> _ask(String title, String text, String okLabel) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(okLabel),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _projectMenu(String path, Offset pos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.delete_outline, color: Colors.red),
            title: Text('删除会话'),
          ),
        ),
        const PopupMenuItem(
          value: 'clear',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.delete_sweep),
            title: Text('清空对话'),
          ),
        ),
      ],
    );
    if (action == null || !mounted) return;
    final name = AppController.projectName(path);
    if (action == 'clear') {
      if (await _ask('清空对话', '清空“$name”的对话历史？会话保留在列表中，项目文件不会被删除。', '清空')) {
        await c.clearSessionOf(path);
      }
      return;
    }
    if (await _ask(
      '删除会话',
      '从列表中删除“$name”并清除它的对话记录？\n项目文件保留在磁盘上：\n$path',
      '删除',
    )) {
      await c.deleteSession(path);
    }
  }

  Future<void> _bugReport() async {
    final ctl = TextEditingController();
    final desc = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('报告 Bug'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctl,
            autofocus: true,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: '描述你看到的问题（会自动附上最近一次 logcat 和截图路径）',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (desc == null || desc.trim().isEmpty) return;
    final ctx = await c.bugReportContext();
    await _send(
      '【Bug 报告】${desc.trim()}\n\n$ctx\n请先复现并定位原因（必要时重新抓 logcat、截图），修复后重新构建、安装并截图验证。',
      '【Bug 报告】${desc.trim()}',
    );
  }

  void _addFeature() {
    _input.text = '【添加功能】';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _focus.requestFocus();
  }

  void _rebuild() {
    _send(
      '请重新构建并安装：在项目目录执行 bash build.sh，构建成功后用 adb 安装 app.apk、启动主 Activity 并截图确认；失败时分析输出并修复。',
      '【重新构建并安装】',
    );
  }

  /// 导入 skill：.md 文件或包含 SKILL.md 的文件夹。
  Future<void> _importSkills(List<String> sources) async {
    final done = <String>[];
    for (final src in sources) {
      try {
        SkillImport r;
        try {
          r = await c.importSkill(src);
        } on SkillExistsException catch (e) {
          if (!mounted) return;
          final ok = await _ask(
            '覆盖 skill',
            '已存在名为“${e.name}”的 skill，用新导入的内容替换它？',
            '覆盖',
          );
          if (!ok) continue;
          r = await c.importSkill(src, overwrite: true);
        }
        done.add(r.addedFrontmatter ? '${r.name}（已自动补充名称和描述）' : r.name);
      } catch (e) {
        _toast('导入失败：$e');
      }
    }
    if (done.isNotEmpty) _toast('已导入 skill：${done.join('、')}');
  }

  Future<void> _openSkills() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: c,
        builder: (ctx, _) => AlertDialog(
          title: const Text('技能（skill）'),
          content: SizedBox(
            width: 600,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '上传一个 .md 文件，或一个根目录含 SKILL.md 的文件夹。'
                  '导入后在输入框里用 /名称 调用，AI 也会按需自动加载。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: c.skills.skills.isEmpty
                      ? const Center(child: Text('还没有 skill'))
                      : ListView(
                          children: [
                            for (final s in c.skills.skills)
                              ListTile(
                                dense: true,
                                leading: const Icon(Icons.extension, size: 18),
                                title: Text('/${s.name}'),
                                subtitle: Text(
                                  s.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                final files = await FileDialogs.pickMarkdown();
                if (files.isNotEmpty) await _importSkills(files);
              },
              icon: const Icon(Icons.upload_file, size: 18),
              label: const Text('上传 .md 文件'),
            ),
            TextButton.icon(
              onPressed: () async {
                final d = await FileDialogs.pickDirectory(
                  title: '选择 skill 文件夹（根目录含 SKILL.md）',
                );
                if (d != null) await _importSkills([d]);
              },
              icon: const Icon(Icons.drive_folder_upload, size: 18),
              label: const Text('上传文件夹'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SettingsPage(controller: c)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (c.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          c.currentProject == null
              ? '安卓手表软件编辑器'
              : '安卓手表软件编辑器 — ${AppController.projectName(c.currentProject!)}',
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                '${c.config.model}  ·  ${c.config.permission.label}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ),
          if (!c.config.hasApiKey)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Center(
                child: Text('未设置 API Key', style: TextStyle(color: Colors.red)),
              ),
            ),
          IconButton(
            tooltip: '技能（skill）：上传 .md 文件或文件夹',
            icon: const Icon(Icons.extension),
            onPressed: c.running ? null : _openSkills,
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 230, child: Glass(child: _projectPane())),
            const SizedBox(width: 12),
            Expanded(child: Glass(child: _chatPane())),
            const SizedBox(width: 12),
            SizedBox(width: 330, child: Glass(child: _sidePane())),
          ],
        ),
      ),
    );
  }

  Widget _projectPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
          child: FilledButton.icon(
            onPressed: c.running ? null : _newProject,
            icon: const Icon(Icons.add),
            label: const Text('新建项目'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text('项目 / 会话', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: c.projects.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    '还没有项目。每个手表 App 对应工作区下的一个子目录。',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  children: [
                    for (final pr in c.projects)
                      GestureDetector(
                        onSecondaryTapDown: c.running
                            ? null
                            : (d) => _projectMenu(pr, d.globalPosition),
                        child: Tooltip(
                          message: '$pr\n右键可删除会话或清空对话',
                          waitDuration: const Duration(milliseconds: 800),
                          child: ListTile(
                            dense: true,
                            leading: const Icon(Icons.watch, size: 18),
                            title: Text(
                              AppController.projectName(pr),
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              p.dirname(pr),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 10),
                            ),
                            selected: pr == c.currentProject,
                            onTap: c.running ? null : () => c.openProject(pr),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        const Divider(height: 1, indent: 12, endIndent: 12),
        Padding(
          padding: const EdgeInsets.all(10),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            onPressed: c.running || c.projects.isEmpty
                ? null
                : () async {
                    if (await _ask(
                      '移除全部会话',
                      '从列表中移除全部 ${c.projects.length} 个会话并清除对话记录？\n项目文件保留在磁盘上。',
                      '全部移除',
                    )) {
                      await c.deleteAllSessions();
                    }
                  },
            icon: const Icon(Icons.delete_forever, size: 18),
            label: const Text('移除全部会话'),
          ),
        ),
      ],
    );
  }

  Widget _chatPane() {
    if (c.currentProject == null) {
      return const Center(child: Text('在左侧新建或选择一个项目开始。'));
    }
    final msgs = c.session.messages;
    if (c.currentProject != _shownProject) {
      _shownProject = c.currentProject;
      _start = _roundStart(msgs, msgs.length);
      _scrollToEnd();
    }
    if (_start > msgs.length) _start = _roundStart(msgs, msgs.length); // 被清空过
    return Column(
      children: [
        Expanded(
          child: msgs.isEmpty
              ? const Center(
                  child: Text(
                    '描述你想要的手表 App，例如：“做一个圆屏计步表盘，显示今日步数和电量”。',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              // 用整列布局而不是 ListView.builder：懒加载按估算高度算滚动范围，
              // 条目高度不一（展开的工具框）时滚动条会乱跳。
              : Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    key: ValueKey(c.currentProject),
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_start > 0)
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: TextButton.icon(
                                onPressed: _loadEarlier,
                                icon: const Icon(Icons.expand_less, size: 18),
                                label: Text(
                                  '加载更多（上一轮对话，前面还有 ${msgs.take(_start).where((m) => m.role == 'user').length} 轮）',
                                ),
                              ),
                            ),
                          ),
                        for (var i = _start; i < msgs.length; i++)
                          MessageView(
                            key: ValueKey(i),
                            message: msgs[i],
                            streaming: c.running && i == msgs.length - 1,
                          ),
                      ],
                    ),
                  ),
                ),
        ),
        const Divider(height: 1, indent: 12, endIndent: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: c.running ? null : _bugReport,
                icon: const Icon(Icons.bug_report, size: 18),
                label: const Text('报告 Bug'),
              ),
              OutlinedButton.icon(
                onPressed: c.running ? null : _addFeature,
                icon: const Icon(Icons.add_circle_outline, size: 18),
                label: const Text('添加功能'),
              ),
              OutlinedButton.icon(
                onPressed: c.running ? null : _rebuild,
                icon: const Icon(Icons.build, size: 18),
                label: const Text('重新构建并安装'),
              ),
            ],
          ),
        ),
        if (_attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in _attachments)
                  InputChip(
                    avatar: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Image.file(
                        File(a),
                        width: 24,
                        height: 24,
                        fit: BoxFit.cover,
                      ),
                    ),
                    label: Text(
                      p.basename(a),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onDeleted: () => setState(() => _attachments.remove(a)),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '附加图片（设计图、问题截图）',
                onPressed: c.running ? null : _pickImages,
                icon: const Icon(Icons.image_outlined),
              ),
              Expanded(
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): () {
                      if (!c.running) _send();
                    },
                  },
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    minLines: 3,
                    maxLines: 8,
                    decoration: InputDecoration(
                      hintText:
                          '描述你想要的手表功能…（Ctrl+Enter 发送，/skill-name 显式调用 skill）',
                      border: const OutlineInputBorder(),
                      helperText: c.skills.skills.isEmpty
                          ? null
                          : '可用 skill：${c.skills.skills.map((s) => '/${s.name}').join('  ')}',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Row 给子项的宽度不受限，stretch 必须配 IntrinsicWidth，否则整行布局失败。
              IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Tooltip(
                      message: '让 AI 回顾本次对话，把踩过的坑、注意事项和经验写成新的 skill',
                      child: OutlinedButton.icon(
                        onPressed: c.running || c.session.messages.isEmpty
                            ? null
                            : _summarizeSkill,
                        icon: const Icon(Icons.auto_stories_outlined, size: 18),
                        label: const Text('总结经验'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    c.running
                        ? FilledButton.tonalIcon(
                            onPressed: c.stop,
                            icon: const Icon(Icons.stop),
                            label: const Text('停止'),
                          )
                        : FilledButton.icon(
                            onPressed: () => _send(),
                            icon: const Icon(Icons.send),
                            label: const Text('发送'),
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sidePane() {
    final pr = c.profile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '设备',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (c.deviceBusy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const Text('自动检测', style: TextStyle(fontSize: 12)),
              Tooltip(
                message: '每 ${c.pollInterval.inSeconds} 秒检查一次 adb 设备，插上手表后自动识别',
                child: Switch(value: c.autoDetect, onChanged: c.setAutoDetect),
              ),
              IconButton(
                tooltip: '刷新设备列表',
                icon: const Icon(Icons.refresh),
                onPressed: c.deviceBusy ? null : c.refreshDevices,
              ),
            ],
          ),
        ),
        if (c.devices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButton<String>(
              isExpanded: true,
              value: c.devices.any((d) => d.serial == c.selectedSerial)
                  ? c.selectedSerial
                  : null,
              hint: const Text('选择设备'),
              items: [
                for (final d in c.devices)
                  DropdownMenuItem(
                    value: d.serial,
                    enabled: d.isOnline,
                    child: Text(
                      '${d.model.isEmpty ? d.serial : d.model}（${d.stateLabel}）',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: c.deviceBusy
                  ? null
                  : (s) => s == null ? null : c.selectDevice(s),
            ),
          ),
        if (c.deviceError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              c.deviceError!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        if (pr != null) _profileCard(pr),
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 8, 12, 2),
          child: Text('工具执行日志', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            reverse: true,
            itemCount: c.logs.length,
            itemBuilder: (_, i) =>
                LogEntry(line: c.logs[c.logs.length - 1 - i]),
          ),
        ),
      ],
    );
  }

  Widget _profileCard(DeviceProfile pr) {
    final rows = <(String, String)>[
      ('型号', '${pr.brand} ${pr.model}'.trim()),
      ('系统', 'Android ${pr.release} / API ${pr.sdk ?? '?'}'),
      ('ABI', pr.abi),
      ('屏幕', '${pr.shape.label}${pr.userConfirmed ? '（已确认）' : ''}'),
      ('像素', '${pr.widthPx} x ${pr.heightPx} px'),
      ('密度', '${pr.density} dpi → ${pr.dpLabel}'),
      ('来源', c.profileFromStore ? '设备档案库' : '刚刚采样'),
    ];
    return Card(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        r.$1,
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(r.$2, style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            if (pr.shape == ScreenShape.suspectedRound &&
                !pr.userConfirmed) ...[
              const SizedBox(height: 6),
              const Text(
                '屏幕宽高相等但没有圆屏标志，请确认实际形状：',
                style: TextStyle(color: Colors.orange, fontSize: 12),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed: () => c.confirmShape(ScreenShape.round),
                    child: const Text('是圆屏'),
                  ),
                  TextButton(
                    onPressed: () => c.confirmShape(ScreenShape.square),
                    child: const Text('是方屏'),
                  ),
                ],
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: c.deviceBusy || c.selectedSerial == null
                    ? null
                    : () => c.selectDevice(c.selectedSerial!, resample: true),
                icon: const Icon(Icons.sensors, size: 16),
                label: const Text('重新采样'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
