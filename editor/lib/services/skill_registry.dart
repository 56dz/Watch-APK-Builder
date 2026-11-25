import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/skill.dart';

/// 解析 SKILL.md 开头的 YAML frontmatter（只支持 skill 用到的子集：
/// `key: value`、单/双引号、`>` / `|` 块标量、缩进续行）。
Map<String, String> parseFrontmatter(String text) {
  var t = text.replaceAll('\r\n', '\n');
  if (t.startsWith('\uFEFF')) t = t.substring(1);
  final lines = t.split('\n');
  if (lines.isEmpty || lines.first.trim() != '---') return const {};
  final end = lines.indexWhere(
    (l) => l.trim() == '---' || l.trim() == '...',
    1,
  );
  if (end < 0) return const {};
  final body = lines.sublist(1, end);
  final result = <String, String>{};
  final keyRe = RegExp(r'^([A-Za-z0-9_.-]+)\s*:(.*)$');
  var i = 0;
  while (i < body.length) {
    final line = body[i];
    final m = keyRe.firstMatch(line);
    if (m == null || line.startsWith(' ') || line.startsWith('\t')) {
      i++;
      continue;
    }
    final key = m.group(1)!;
    var value = m.group(2)!.trim();
    i++;
    final cont = <String>[];
    while (i < body.length &&
        (body[i].startsWith(' ') ||
            body[i].startsWith('\t') ||
            body[i].trim().isEmpty)) {
      if (keyRe.hasMatch(body[i]) &&
          !body[i].startsWith(' ') &&
          !body[i].startsWith('\t'))
        break;
      cont.add(body[i].trim());
      i++;
    }
    while (cont.isNotEmpty && cont.last.isEmpty) {
      cont.removeLast();
    }
    if (value.startsWith('|') || value.startsWith('>')) {
      final folded = value.startsWith('>');
      value = folded
          ? cont.join(' ').replaceAll(RegExp(r' {2,}'), ' ').trim()
          : cont.join('\n');
    } else {
      if (cont.isNotEmpty)
        value = [value, ...cont].where((s) => s.isNotEmpty).join(' ');
      value = _unquote(value);
    }
    result[key] = value;
  }
  return result;
}

String _unquote(String v) {
  if (v.length >= 2 && v.startsWith("'") && v.endsWith("'")) {
    return v.substring(1, v.length - 1).replaceAll("''", "'");
  }
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    return v
        .substring(1, v.length - 1)
        .replaceAll(r'\"', '"')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\\', r'\');
  }
  return v;
}

/// 校验 skill 内的相对路径，返回 posix 形式；越界或绝对路径返回 null。
String? safeRelative(String relative) {
  final r = relative.trim().replaceAll('\\', '/');
  if (r.isEmpty) return '';
  if (r.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(r)) return null;
  final n = p.posix.normalize(r);
  if (n == '..' || n.startsWith('../')) return null;
  return n == '.' ? '' : n;
}

/// 资源读取抽象（生产环境用 rootBundle，测试用内存实现）。
abstract class AssetReader {
  Future<List<String>> listAssets();
  Future<String> loadString(String key);
  Future<List<int>> loadBytes(String key);
}

/// 不提供任何资源（skill 全部来自软件根目录的 skills/ 文件夹）。
class NoAssetReader implements AssetReader {
  const NoAssetReader();
  @override
  Future<List<String>> listAssets() async => const [];
  @override
  Future<String> loadString(String key) => throw StateError('no asset $key');
  @override
  Future<List<int>> loadBytes(String key) => throw StateError('no asset $key');
}

/// 把随软件打包的 assets/skills/<名称>/... 释放到 [dir]（软件根目录 skills/）。
/// 已存在的文件不覆盖，用户对 skill 的修改会保留。返回新写入的文件数。
Future<int> seedSkills(AssetReader assets, String dir) async {
  const prefix = SkillRegistry.builtinPrefix;
  var n = 0;
  List<String> keys;
  try {
    keys = await assets.listAssets();
  } catch (_) {
    return 0;
  }
  for (final key in keys) {
    if (!key.startsWith(prefix)) continue;
    final rel = safeRelative(key.substring(prefix.length));
    if (rel == null || rel.isEmpty) continue;
    final f = File(p.joinAll([dir, ...rel.split('/')]));
    if (f.existsSync()) continue;
    try {
      final bytes = await assets.loadBytes(key);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
      n++;
    } catch (_) {}
  }
  return n;
}

class SkillException implements Exception {
  final String message;
  const SkillException(this.message);

  @override
  String toString() => message;
}

/// 内置 skill（assets/skills/*）+ 外部目录 skill。同名时外部覆盖内置；
/// 多个外部目录之间，列表中靠前的优先。
class SkillRegistry {
  static const builtinPrefix = 'assets/skills/';

  final AssetReader assets;
  final List<String> Function() externalDirs;
  Map<String, SkillInfo> _skills = {};
  List<String> _assetKeys = [];

  SkillRegistry(this.assets, this.externalDirs);

  List<SkillInfo> get skills =>
      _skills.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  SkillInfo? operator [](String name) => _skills[name];

  Future<List<SkillInfo>> reload() async {
    final map = <String, SkillInfo>{};
    try {
      _assetKeys = await assets.listAssets();
    } catch (_) {
      _assetKeys = [];
    }
    for (final key in _assetKeys) {
      final rest = key.startsWith(builtinPrefix)
          ? key.substring(builtinPrefix.length)
          : null;
      if (rest == null) continue;
      final parts = rest.split('/');
      if (parts.length != 2 || parts[1] != 'SKILL.md') continue;
      try {
        final fm = parseFrontmatter(await assets.loadString(key));
        final name = (fm['name'] ?? '').isNotEmpty ? fm['name']! : parts[0];
        map[name] = SkillInfo(
          name: name,
          description: fm['description'] ?? '',
          builtin: true,
          location: '$builtinPrefix${parts[0]}',
        );
      } catch (_) {}
    }
    final external = <String, SkillInfo>{};
    for (final d in externalDirs()) {
      final dir = Directory(d.trim());
      if (d.trim().isEmpty || !dir.existsSync()) continue;
      final subs = dir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final sub in subs) {
        final f = File(p.join(sub.path, 'SKILL.md'));
        if (!f.existsSync()) continue;
        try {
          final fm = parseFrontmatter(f.readAsStringSync());
          final name = (fm['name'] ?? '').isNotEmpty
              ? fm['name']!
              : p.basename(sub.path);
          external.putIfAbsent(
            name,
            () => SkillInfo(
              name: name,
              description: fm['description'] ?? '',
              builtin: false,
              location: sub.path,
            ),
          );
        } catch (_) {}
      }
    }
    map.addAll(external);
    _skills = map;
    return skills;
  }

  SkillInfo _require(String name) {
    final s = _skills[name.trim()];
    if (s == null) {
      throw SkillException('没有名为“$name”的 skill。可用：${_skills.keys.join('、')}');
    }
    return s;
  }

  Future<String> loadSkill(String name) => readFile(name, 'SKILL.md');

  /// 读取 skill 内文件；[relative] 为空时返回文件清单。拒绝路径穿越。
  Future<String> readFile(String name, String relative) async {
    final s = _require(name);
    final rel = safeRelative(relative);
    if (rel == null) throw SkillException('拒绝访问 skill 目录之外的路径：$relative');
    if (rel.isEmpty) return (await listFiles(name)).join('\n');
    if (s.builtin) {
      final key = '${s.location}/$rel';
      if (!_assetKeys.contains(key))
        throw SkillException('skill “$name” 中没有文件 $rel');
      return assets.loadString(key);
    }
    final root = p.normalize(p.absolute(s.location));
    final full = p.normalize(p.join(root, rel));
    if (!p.isWithin(root, full))
      throw SkillException('拒绝访问 skill 目录之外的路径：$relative');
    final f = File(full);
    if (!f.existsSync()) throw SkillException('skill “$name” 中没有文件 $rel');
    final real = p.normalize(f.resolveSymbolicLinksSync());
    final realRoot = p.normalize(Directory(root).resolveSymbolicLinksSync());
    if (!p.isWithin(realRoot, real))
      throw SkillException('拒绝访问 skill 目录之外的路径：$relative');
    return f.readAsString();
  }

  Future<List<String>> listFiles(String name) async {
    final s = _require(name);
    if (s.builtin) {
      final pre = '${s.location}/';
      return _assetKeys
          .where((k) => k.startsWith(pre))
          .map((k) => k.substring(pre.length))
          .toList()
        ..sort();
    }
    final root = Directory(s.location);
    return root
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.relative(f.path, from: root.path).replaceAll('\\', '/'))
        .toList()
      ..sort();
  }

  /// 解析输入开头的 /skill-name（可多个），返回识别到的 skill 名和剩余文本。
  ({List<String> names, String rest}) parseSlash(String input) {
    final names = <String>[];
    var rest = input.trimLeft();
    final re = RegExp(r'^/([A-Za-z0-9_.-]+)(\s+|$)');
    while (true) {
      final m = re.firstMatch(rest);
      if (m == null || !_skills.containsKey(m.group(1))) break;
      names.add(m.group(1)!);
      rest = rest.substring(m.end);
    }
    return (names: names, rest: rest.trim());
  }
}

/// skill 名称：字母、数字、点、下划线、短横线（用作 skills/ 下的目录名和 /调用名）。
final skillNameRe = RegExp(r'^[A-Za-z0-9_.-]+$');

class SkillExistsException implements Exception {
  final String name;
  const SkillExistsException(this.name);
  @override
  String toString() => '已存在名为“$name”的 skill';
}

/// 导入结果。
class SkillImport {
  final String name;
  final String dir;
  final int files;
  final bool addedFrontmatter;
  const SkillImport(this.name, this.dir, this.files, this.addedFrontmatter);
}

String _skillName(String raw) {
  final n = raw
      .trim()
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '');
  return n.replaceAll(RegExp(r'^[.-]+'), '');
}

/// 没有 frontmatter 的 md：用第一个标题/第一行生成 name 和 description。
String _withFrontmatter(String md, String name) {
  final lines = md.replaceAll('\r\n', '\n').split('\n');
  var desc = '';
  for (final l in lines) {
    final t = l.trim().replaceFirst(RegExp(r'^#+\s*'), '');
    if (t.isNotEmpty) {
      desc = t;
      break;
    }
  }
  if (desc.length > 200) desc = desc.substring(0, 200);
  final q = desc.replaceAll("'", "''");
  return "---\nname: $name\ndescription: '$q'\n---\n\n$md";
}

/// 把用户选的 .md 文件或文件夹导入到 [skillsDir]/<名称>/。
///
/// - .md 文件：成为 <名称>/SKILL.md。名称取 frontmatter 的 name，否则取文件名
///   （文件名是 SKILL.md 时取它所在文件夹名）。没有 frontmatter 时自动补上。
/// - 文件夹：根目录（或唯一的子文件夹）里必须有 SKILL.md，整个文件夹复制过去，
///   跳过 .git。名称取 frontmatter 的 name，否则取文件夹名。
/// - 同名 skill 已存在时抛 [SkillExistsException]，[overwrite] 为 true 时先删除旧的。
Future<SkillImport> importSkillFrom(
  String source,
  String skillsDir, {
  bool overwrite = false,
}) async {
  final type = FileSystemEntity.typeSync(source);
  if (type == FileSystemEntityType.notFound) {
    throw SkillException('找不到：$source');
  }
  if (type == FileSystemEntityType.file) {
    if (p.extension(source).toLowerCase() != '.md') {
      throw const SkillException('只能导入 .md 文件或包含 SKILL.md 的文件夹');
    }
    final md = await File(source).readAsString();
    final fm = parseFrontmatter(md);
    final base = p.basenameWithoutExtension(source);
    final name = _skillName(
      (fm['name'] ?? '').isNotEmpty
          ? fm['name']!
          : base.toUpperCase() == 'SKILL'
          ? p.basename(p.dirname(source))
          : base,
    );
    if (name.isEmpty || !skillNameRe.hasMatch(name)) {
      throw SkillException('无法从文件名得到合法的 skill 名称（只能用字母、数字、. _ -）：$base');
    }
    final dest = Directory(p.join(skillsDir, name));
    await _prepareDest(dest, name, overwrite);
    final add = fm.isEmpty;
    await File(p.join(dest.path, 'SKILL.md'))
        .writeAsString(add ? _withFrontmatter(md, name) : md);
    return SkillImport(name, dest.path, 1, add);
  }

  var root = Directory(source);
  if (!File(p.join(root.path, 'SKILL.md')).existsSync()) {
    final subs = root
        .listSync()
        .whereType<Directory>()
        .where((d) => File(p.join(d.path, 'SKILL.md')).existsSync())
        .toList();
    if (subs.length != 1) {
      throw const SkillException('文件夹里没有 SKILL.md（skill 文件夹的根目录必须有 SKILL.md）');
    }
    root = subs.single;
  }
  final skillMd = File(p.join(root.path, 'SKILL.md'));
  final fm = parseFrontmatter(await skillMd.readAsString());
  final name = _skillName(
    (fm['name'] ?? '').isNotEmpty ? fm['name']! : p.basename(root.path),
  );
  if (name.isEmpty || !skillNameRe.hasMatch(name)) {
    throw SkillException(
      'skill 名称不合法（只能用字母、数字、. _ -）：${p.basename(root.path)}',
    );
  }
  final dest = Directory(p.join(skillsDir, name));
  final src = p.normalize(p.absolute(root.path));
  final dst = p.normalize(p.absolute(dest.path));
  if (p.equals(src, dst)) {
    throw SkillException('“$name”已经在 skills 文件夹里了');
  }
  if (p.isWithin(src, dst) || p.isWithin(dst, src)) {
    throw const SkillException('不能把 skill 导入到它自己的子文件夹里');
  }
  await _prepareDest(dest, name, overwrite);
  var n = 0;
  await for (final e in root.list(recursive: true, followLinks: false)) {
    final rel = p.relative(e.path, from: root.path);
    if (p.split(rel).contains('.git')) continue;
    final target = p.join(dest.path, rel);
    if (e is Directory) {
      await Directory(target).create(recursive: true);
    } else if (e is File) {
      await File(target).parent.create(recursive: true);
      await e.copy(target);
      n++;
    }
  }
  var add = false;
  if (fm.isEmpty) {
    final f = File(p.join(dest.path, 'SKILL.md'));
    await f.writeAsString(_withFrontmatter(await f.readAsString(), name));
    add = true;
  }
  return SkillImport(name, dest.path, n, add);
}

Future<void> _prepareDest(Directory dest, String name, bool overwrite) async {
  if (dest.existsSync()) {
    if (!overwrite) throw SkillExistsException(name);
    await dest.delete(recursive: true);
  }
  await dest.create(recursive: true);
}
