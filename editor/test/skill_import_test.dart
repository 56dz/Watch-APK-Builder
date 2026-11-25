import 'dart:io';

import 'package:android_watch_editor/services/skill_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

void main() {
  late Directory tmp;
  late String skills;
  setUp(() {
    tmp = tempDir('awe_imp');
    skills = p.join(tmp.path, 'skills');
    Directory(skills).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  SkillRegistry reg() => SkillRegistry(const NoAssetReader(), () => [skills]);

  test('上传无 frontmatter 的 md：按文件名命名并补 frontmatter', () async {
    final f = File(p.join(tmp.path, 'heart-rate.md'))
      ..writeAsStringSync('# 心率页面经验\n\n正文');
    final r = await importSkillFrom(f.path, skills);
    expect(r.name, 'heart-rate');
    expect(r.addedFrontmatter, isTrue);
    final s = (await reg().reload()).single;
    expect(s.name, 'heart-rate');
    expect(s.description, '心率页面经验');
    expect(
      await reg().loadSkill('heart-rate').catchError((_) => ''),
      isNotNull,
    );
  });

  test('上传带 frontmatter 的 md：用 name；同名需确认覆盖', () async {
    final f = File(p.join(tmp.path, 'x.md'))
      ..writeAsStringSync('---\nname: watch-ui\ndescription: d1\n---\nbody');
    expect((await importSkillFrom(f.path, skills)).name, 'watch-ui');
    expect(
      () => importSkillFrom(f.path, skills),
      throwsA(isA<SkillExistsException>()),
    );
    f.writeAsStringSync('---\nname: watch-ui\ndescription: d2\n---\nbody');
    await importSkillFrom(f.path, skills, overwrite: true);
    expect((await reg().reload()).single.description, 'd2');
  });

  test('上传文件夹：复制全部文件，跳过 .git；支持外面多套一层', () async {
    final outer = Directory(p.join(tmp.path, 'download'))..createSync();
    final src = Directory(p.join(outer.path, 'my-skill'))..createSync();
    File(p.join(src.path, 'SKILL.md'))
        .writeAsStringSync('---\nname: my-skill\ndescription: d\n---\n');
    File(p.join(src.path, 'references', 'a.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('ref');
    File(p.join(src.path, '.git', 'HEAD'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    final r = await importSkillFrom(outer.path, skills);
    expect(r.name, 'my-skill');
    expect(r.files, 2);
    final files = await (reg()..reload()).reload().then((_) => reg());
    await files.reload();
    expect(await files.listFiles('my-skill'), ['SKILL.md', 'references/a.md']);
  });

  test('拒绝非 md 文件和没有 SKILL.md 的文件夹', () async {
    final t = File(p.join(tmp.path, 'a.txt'))..writeAsStringSync('x');
    expect(
      () => importSkillFrom(t.path, skills),
      throwsA(isA<SkillException>()),
    );
    final d = Directory(p.join(tmp.path, 'empty'))..createSync();
    expect(
      () => importSkillFrom(d.path, skills),
      throwsA(isA<SkillException>()),
    );
  });
}
