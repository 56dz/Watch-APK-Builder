import 'dart:ui';

import 'package:flutter/material.dart';

/// 全局圆角。
const double kRadius = 18;
const double kRadiusSmall = 12;

/// 整个窗口的背景：柔和的渐变加几块大色斑，磨砂玻璃面板叠在上面才看得出模糊效果。
class AppBackdrop extends StatelessWidget {
  final Widget child;
  const AppBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    Widget blob(Color c, double size) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [c, c.withValues(alpha: 0)]),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(s.surface, s.primaryContainer, 0.55)!,
                s.surface,
                Color.lerp(s.surface, s.tertiaryContainer, 0.5)!,
              ],
            ),
          ),
        ),
        Positioned(
          left: -160,
          top: -140,
          child: blob(s.primary.withValues(alpha: 0.28), 560),
        ),
        Positioned(
          right: -200,
          top: 120,
          child: blob(s.tertiary.withValues(alpha: 0.22), 620),
        ),
        Positioned(
          left: 280,
          bottom: -260,
          child: blob(s.secondary.withValues(alpha: 0.20), 640),
        ),
        child,
      ],
    );
  }
}

/// 磨砂玻璃面板：背景模糊 + 半透明白 + 细描边 + 圆角 + 轻阴影。
class Glass extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final double blur;
  final double opacity;
  const Glass({
    super.key,
    required this.child,
    this.padding,
    this.radius = kRadius,
    this.blur = 22,
    this.opacity = 0.55,
  });

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: opacity + 0.12),
                  Colors.white.withValues(alpha: opacity - 0.1),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.7),
                width: 1,
              ),
            ),
            child: padding == null
                ? child
                : Padding(padding: padding!, child: child),
          ),
        ),
      ),
    );
  }
}

/// 工具执行日志的一条：圆角小框，按内容着色（✓ 成功、✗ 失败、⟳ 重试、▶ 调用）。
class LogEntry extends StatelessWidget {
  final String line;
  const LogEntry({super.key, required this.line});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    // 日志格式：HH:MM:SS 内容
    final m = RegExp(r'^(\d\d:\d\d:\d\d) (.*)$', dotAll: true).firstMatch(line);
    final time = m?.group(1) ?? '';
    final text = m?.group(2) ?? line;
    final (Color accent, IconData icon) = switch (text) {
      _
          when text.startsWith('✗') ||
              text.contains('失败') ||
              text.contains('错误') =>
        (Colors.red.shade400, Icons.error_outline),
      _ when text.startsWith('⟳') => (Colors.orange.shade600, Icons.autorenew),
      _ when text.startsWith('✓') => (
        Colors.green.shade600,
        Icons.check_circle_outline,
      ),
      _ when text.startsWith('▶') => (s.primary, Icons.play_circle_outline),
      _ => (s.outline, Icons.info_outline),
    };
    final body = text.startsWith(RegExp('[✓✗⟳▶] ')) ? text.substring(2) : text;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.07),
          Colors.white.withValues(alpha: 0.6),
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 14, color: accent),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (time.isNotEmpty)
                  Text(time, style: TextStyle(fontSize: 10, color: s.outline)),
                SelectableText(
                  body,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 圆角主题：按钮、输入框、卡片、对话框、菜单统一圆角，卡片半透明。
ThemeData glassTheme() {
  final base = ThemeData(
    colorSchemeSeed: const Color(0xFF2E7D6B),
    useMaterial3: true,
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'PingFang SC',
      'Noto Sans CJK SC',
    ],
  );
  final s = base.colorScheme;
  const pill = StadiumBorder();
  final rr = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(kRadiusSmall),
  );
  final input = OutlineInputBorder(
    borderRadius: BorderRadius.circular(kRadiusSmall),
    borderSide: BorderSide(color: s.outlineVariant),
  );
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white.withValues(alpha: 0.6),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusSmall + 2),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.8)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    expansionTileTheme: ExpansionTileThemeData(shape: rr, collapsedShape: rr),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: pill),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: pill,
        backgroundColor: Colors.white.withValues(alpha: 0.45),
        side: BorderSide(color: s.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: pill),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.6),
      border: input,
      enabledBorder: input,
      focusedBorder: input.copyWith(
        borderSide: BorderSide(color: s.primary, width: 1.6),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white.withValues(alpha: 0.92),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius + 4),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Colors.white.withValues(alpha: 0.95),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusSmall),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusSmall),
          ),
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusSmall),
      ),
      selectedTileColor: s.primaryContainer.withValues(alpha: 0.55),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusSmall),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: const Color(0xE6303633),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: s.outlineVariant.withValues(alpha: 0.5),
    ),
  );
}
