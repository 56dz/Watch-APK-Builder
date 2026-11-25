import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_config.dart';
import '../services/bundled_tools.dart';
import '../services/web_search.dart';
import 'app_controller.dart';
import 'glass.dart';

/// 设置：模型接口（OpenAI 兼容 / Anthropic）、API Key、图片输入、对话权限、运行参数。
/// 工具路径不可配置：便携版固定使用软件根目录 tools/ 下的工具。
class SettingsPage extends StatefulWidget {
  final AppController controller;
  const SettingsPage({super.key, required this.controller});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppConfig get _c => widget.controller.config;
  AppPaths get _paths => widget.controller.paths;

  late ApiFormat _format = _c.apiFormat;
  late final _apiKey = TextEditingController(text: _c.apiKey);
  late final _baseUrl = TextEditingController(text: _c.baseUrl);
  late final _model = TextEditingController(text: _c.model);
  late bool _vision = _c.vision;
  late PermissionMode _permission = _c.permission;
  late bool _webSearch = _c.webSearch;
  late String _engine = searchEngines.containsKey(_c.searchEngine)
      ? _c.searchEngine
      : 'auto';
  late final _maxSteps = TextEditingController(text: '${_c.maxSteps}');
  late final _timeout = TextEditingController(text: '${_c.commandTimeoutSec}');
  late final _reqTimeout = TextEditingController(
    text: '${_c.requestTimeoutSec}',
  );
  late final _retries = TextEditingController(text: '${_c.retryCount}');
  late final _retryDelay = TextEditingController(text: '${_c.retryDelaySec}');
  bool _showKey = false;

  @override
  void dispose() {
    for (final t in [
      _apiKey,
      _baseUrl,
      _model,
      _maxSteps,
      _timeout,
      _reqTimeout,
      _retries,
      _retryDelay,
    ]) {
      t.dispose();
    }
    super.dispose();
  }

  void _applyPreset(ModelPreset pr) {
    setState(() {
      _format = pr.format;
      _baseUrl.text = pr.baseUrl;
      _model.text = pr.model;
      _vision = pr.vision;
    });
  }

  Future<void> _save() async {
    final c = _c.copyWith(
      apiFormat: _format,
      apiKey: _apiKey.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      vision: _vision,
      permission: _permission,
      webSearch: _webSearch,
      searchEngine: _engine,
      maxSteps: (int.tryParse(_maxSteps.text.trim()) ?? _c.maxSteps).clamp(
        1,
        200,
      ),
      commandTimeoutSec:
          (int.tryParse(_timeout.text.trim()) ?? _c.commandTimeoutSec).clamp(
            5,
            3600,
          ),
      requestTimeoutSec: _num(_reqTimeout, _c.requestTimeoutSec, 10, 1800),
      retryCount: _num(_retries, _c.retryCount, 0, 10),
      retryDelaySec: _num(_retryDelay, _c.retryDelaySec, 0, 300),
    );
    await widget.controller.saveConfig(c);
    if (mounted) Navigator.of(context).pop();
  }

  static int _num(TextEditingController t, int d, int min, int max) =>
      (int.tryParse(t.text.trim()) ?? d).clamp(min, max);

  Widget _numField(TextEditingController t, String label, String helper) =>
      Expanded(
        child: TextField(
          controller: t,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(
      title,
      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final missing = _paths.missingTools();
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('保存'),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Glass(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _section('模型接口'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('预设：'),
                      ),
                      for (final pr in AppConfig.presets)
                        ActionChip(
                          label: Text(pr.name),
                          onPressed: () => _applyPreset(pr),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<ApiFormat>(
                    segments: [
                      for (final f in ApiFormat.values)
                        ButtonSegment(value: f, label: Text(f.label)),
                    ],
                    selected: {_format},
                    onSelectionChanged: (s) =>
                        setState(() => _format = s.first),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _baseUrl,
                    decoration: InputDecoration(
                      labelText: '接口地址（Base URL）',
                      hintText: _format == ApiFormat.anthropic
                          ? 'https://api.anthropic.com'
                          : 'https://api.deepseek.com',
                      helperText: _format == ApiFormat.anthropic
                          ? '请求 <地址>/v1/messages；地址已以 /v1 结尾时请求 <地址>/messages'
                          : '请求 <地址>/chat/completions（例如 https://api.openai.com/v1）',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _apiKey,
                    obscureText: !_showKey,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      border: const OutlineInputBorder(),
                      helperText: 'Key 只保存在本机：软件目录 config/config.json',
                      suffixIcon: IconButton(
                        tooltip: _showKey ? '隐藏' : '显示',
                        icon: Icon(
                          _showKey ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setState(() => _showKey = !_showKey),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _model,
                    decoration: const InputDecoration(
                      labelText: '模型名',
                      hintText: 'deepseek-chat / gpt-4o / claude-sonnet-4-5 …',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('支持图片输入（多模态）'),
                    subtitle: const Text(
                      '开启后，手表截图和你附加的图片会以图片形式发给模型。模型不支持图片时请关闭，否则接口会报错。',
                    ),
                    value: _vision,
                    onChanged: (v) => setState(() => _vision = v),
                  ),
                  _section('对话权限'),
                  for (final m in PermissionMode.values)
                    RadioListTile<PermissionMode>(
                      contentPadding: EdgeInsets.zero,
                      value: m,
                      groupValue: _permission,
                      onChanged: (v) =>
                          setState(() => _permission = v ?? _permission),
                      title: Text(m.label),
                      subtitle: Text(m.description),
                    ),
                  _section('联网搜索'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许模型联网搜索和读网页'),
                    subtitle: const Text(
                      '提供 web_search / web_fetch 工具，使用 Bing、DuckDuckGo、SearXNG 等免费引擎，不需要 API Key，也不额外计费。',
                    ),
                    value: _webSearch,
                    onChanged: (v) => setState(() => _webSearch = v),
                  ),
                  if (_webSearch)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: DropdownButtonFormField<String>(
                        initialValue: _engine,
                        decoration: const InputDecoration(
                          labelText: '首选搜索引擎',
                          helperText: '首选引擎失败、被拦截或没有相关结果时自动换下一个',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final e in searchEngines.entries)
                            DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                        ],
                        onChanged: (v) =>
                            setState(() => _engine = v ?? _engine),
                      ),
                    ),
                  _section('运行参数'),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _maxSteps,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: '每次请求最多工具步数',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _timeout,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: '单条命令超时（秒）',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _numField(_reqTimeout, '模型超时（秒）', '10–1800，超过这么久没有响应算失败'),
                      const SizedBox(width: 12),
                      _numField(_retries, '失败重试次数', '0–10，0 表示不重试'),
                      const SizedBox(width: 12),
                      _numField(_retryDelay, '重试间隔（秒）', '0–300'),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      '网络错误、超时、429 限流和 5xx 服务端错误会自动重试；API Key 错误、参数错误等不会重试。',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                  _section('软件目录'),
                  SelectableText(
                    '根目录：${_paths.root}\n'
                    'skill：${_paths.skills}（每个子文件夹一个 skill，含 SKILL.md）\n'
                    '设置与设备档案：${_paths.data}\n'
                    '默认工作区：${_c.defaultWorkspace}\n'
                    '自带工具：${_paths.tools}'
                    '${missing.isEmpty ? '（完整）' : '（缺少：${missing.join('、')}）'}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
