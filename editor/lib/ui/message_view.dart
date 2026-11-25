import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'dart:math' as math;

import '../models/chat_message.dart';

/// 单条消息：用户 / 助手（含思考过程、工具调用）/ 工具结果（可折叠，截图缩略图）。
class MessageView extends StatelessWidget {
  final ChatMessage message;
  final bool streaming;
  const MessageView({super.key, required this.message, this.streaming = false});

  static const _mono = TextStyle(fontFamily: 'Consolas', fontSize: 12);

  @override
  Widget build(BuildContext context) {
    final m = message;
    final scheme = Theme.of(context).colorScheme;
    if (m.role == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 680),
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.images.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final img in m.images)
                      if (File(img).existsSync())
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            File(img),
                            height: 120,
                            fit: BoxFit.contain,
                          ),
                        ),
                  ],
                ),
              if (m.images.isNotEmpty) const SizedBox(height: 6),
              SelectableText(m.shownText),
            ],
          ),
        ),
      );
    }
    if (m.role == 'tool') return _toolResult(context);
    final children = <Widget>[];
    if ((m.reasoning ?? '').isNotEmpty) {
      children.add(
        Collapsible(
          dense: true,
          leading: const Icon(Icons.psychology, size: 18),
          title: const Text(
            '思考过程',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          body: (_) => SelectableText(
            m.reasoning!,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    if (m.content.isNotEmpty) {
      children.add(
        SelectableText(
          m.content,
          style: TextStyle(color: m.isError ? Colors.red : null),
        ),
      );
    } else if (streaming && m.toolCalls.isEmpty) {
      children.add(const Text('…', style: TextStyle(color: Colors.grey)));
    }
    for (final t in m.toolCalls) {
      children.add(
        Card(
          margin: const EdgeInsets.only(top: 6),
          child: Collapsible(
            leading: const Icon(Icons.handyman, size: 18),
            title: Text('调用工具：${t.name}', style: const TextStyle(fontSize: 13)),
            subtitle: _oneLine(t.arguments),
            body: (_) => SelectableText(_pretty(t.arguments), style: _mono),
          ),
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 820),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _toolResult(BuildContext context) {
    final m = message;
    return Container(
      constraints: const BoxConstraints(maxWidth: 820),
      margin: const EdgeInsets.only(bottom: 4),
      child: Card(
        color: m.isError ? Colors.red.shade50 : null,
        child: Collapsible(
          leading: Icon(
            m.isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 18,
            color: m.isError ? Colors.red : Colors.green,
          ),
          title: Text(
            '工具结果：${m.toolName ?? ''}',
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: m.images.isEmpty
              ? _oneLine(m.content)
              : '[${m.images.length} 张图片] ${_oneLine(m.content)}',
          body: (_) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final img in m.images)
                if (File(img).existsSync())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(
                          File(img),
                          width: 200,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  m.content.length > 20000
                      ? '${m.content.substring(0, 20000)}…'
                      : m.content,
                  style: _mono,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _pretty(String args) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(args));
    } catch (_) {
      return args;
    }
  }
}

/// 可折叠的条目（替代 ExpansionTile）：
/// - 默认收起，展开后只在需要时才构建详情；
/// - 展开的条目整个滚出可视范围就自动收起（等滚动停下再收，不和拖动/惯性抢位置）；
///   收起位于视口上方的条目时同步减掉滚动偏移，眼前的内容不会跳动。
class Collapsible extends StatefulWidget {
  final Widget leading;
  final Widget title;
  final String? subtitle;
  final WidgetBuilder body;
  final bool initiallyExpanded;
  final bool dense;

  const Collapsible({
    super.key,
    required this.leading,
    required this.title,
    required this.body,
    this.subtitle,
    this.initiallyExpanded = false,
    this.dense = false,
  });

  @override
  State<Collapsible> createState() => CollapsibleState();
}

class CollapsibleState extends State<Collapsible> {
  late bool _open = widget.initiallyExpanded;
  final _bodyKey = GlobalKey();
  ScrollPosition? _pos;

  bool get isOpen => _open;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pos = Scrollable.maybeOf(context)?.position;
    if (!identical(pos, _pos)) {
      _detach();
      _pos = pos;
      _pos?.addListener(_onScroll);
      _pos?.isScrollingNotifier.addListener(_onScroll);
    }
  }

  Timer? _idle;

  void _detach() {
    _pos?.removeListener(_onScroll);
    _pos?.isScrollingNotifier.removeListener(_onScroll);
  }

  @override
  void dispose() {
    _idle?.cancel();
    _detach();
    super.dispose();
  }

  void _onScroll() {
    if (!_open) return;
    _idle?.cancel();
    _idle = Timer(const Duration(milliseconds: 200), _collapseIfHidden);
  }

  void _collapseIfHidden() {
    if (!_open || !mounted) return;
    final pos = _pos;
    if (pos == null || pos.isScrollingNotifier.value) return;
    final scrollable = Scrollable.maybeOf(context);
    final box = context.findRenderObject();
    final vp = scrollable?.context.findRenderObject();
    if (box is! RenderBox || vp is! RenderBox) return;
    if (!box.attached || !vp.attached || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero, ancestor: vp).dy;
    final bottom = top + box.size.height;
    final above = bottom < 0;
    final below = top > vp.size.height;
    if (!above && !below) return;
    final body = _bodyKey.currentContext?.findRenderObject();
    final bodyH = body is RenderBox && body.hasSize ? body.size.height : 0.0;
    // 视口上方的内容变矮了，偏移同步减掉同样的高度；两者在同一帧生效，可见内容不动。
    if (above && bodyH > 0 && pos.axisDirection == AxisDirection.down) {
      pos.jumpTo(math.max(0.0, pos.pixels - bodyH));
    }
    setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final header = InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: widget.dense ? 0 : 12,
          vertical: widget.dense ? 4 : 8,
        ),
        child: Row(
          children: [
            widget.leading,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  widget.title,
                  if ((widget.subtitle ?? '').isNotEmpty)
                    Text(
                      widget.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small?.copyWith(fontSize: 11),
                    ),
                ],
              ),
            ),
            Icon(_open ? Icons.expand_less : Icons.expand_more, size: 20),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        if (_open)
          Padding(
            key: _bodyKey,
            padding: EdgeInsets.fromLTRB(widget.dense ? 0 : 12, 0, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: widget.body(context),
            ),
          ),
      ],
    );
  }
}
