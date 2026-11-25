/// 一个可用的 skill（来自 SKILL.md 的 YAML frontmatter）。
class SkillInfo {
  final String name;
  final String description;
  final bool builtin;

  /// 内置 skill 是资源前缀，外部 skill 是目录路径。
  final String location;

  const SkillInfo({
    required this.name,
    required this.description,
    required this.builtin,
    required this.location,
  });
}
