import 'dart:io';

import 'package:android_watch_editor/services/skill_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

void main() {
  test('解析内置 SKILL.md 的 frontmatter', () {
    final fm = parseFrontmatter(
      File('assets/skills/oppo-watch2-apk/SKILL.md').readAsStringSync(),
    );
    expect(fm['name'], 'oppo-watch2-apk');
    expect(
      fm['description'],
      startsWith('Build, install and debug native Android APKs'),
    );
  });

  test('frontmatter：引号、块标量、CRLF、缺失', () {
    expect(
      parseFrontmatter(
        '---\r\nname: "a-b"\r\ndescription: \'it\'\'s\'\r\n---\r\nbody',
      ),
      {'name': 'a-b', 'description': "it's"},
    );
    final fm = parseFrontmatter(
      '---\nname: x\ndescription: >\n  line one\n  line two\nother: |\n  a\n  b\n---\n',
    );
    expect(fm['description'], 'line one line two');
    expect(fm['other'], 'a\nb');
    expect(parseFrontmatter('# no frontmatter'), isEmpty);
    expect(parseFrontmatter('---\nname: x\n'), isEmpty);
  });

  group('SkillRegistry', () {
    late Directory ext;
    setUp(() {
      ext = tempDir('awe_skills');
      Directory(p.join(ext.path, 'oppo-watch2-apk')).createSync();
      File(p.join(ext.path, 'oppo-watch2-apk', 'SKILL.md')).writeAsStringSync(
        '---\nname: oppo-watch2-apk\ndescription: 外部覆盖版\n---\n# 外部\n',
      );
      Directory(p.join(ext.path, 'round-watch', 'references'))
          .createSync(recursive: true);
      File(p.join(ext.path, 'round-watch', 'SKILL.md')).writeAsStringSync(
        '---\nname: round-watch\ndescription: 圆屏手表\n---\n# 圆屏\n',
      );
      File(p.join(ext.path, 'round-watch', 'references', 'a.md'))
          .writeAsStringSync('参考A');
      File(p.join(ext.path, 'secret.txt')).writeAsStringSync('不应被读到');
    });
    tearDown(() => ext.deleteSync(recursive: true));

    test('内置 skill 列表与读取', () async {
      final reg = SkillRegistry(DiskAssetReader(), () => const []);
      final list = await reg.reload();
      expect(list.map((s) => s.name), contains('oppo-watch2-apk'));
      final s = reg['oppo-watch2-apk']!;
      expect(s.builtin, isTrue);
      expect(s.description, contains('OPPO Watch 2'));
      expect(
        await reg.loadSkill('oppo-watch2-apk'),
        contains('# OPPO Watch 2 原生 APK 开发'),
      );
      expect(
        await reg.readFile('oppo-watch2-apk', 'references/adb.md'),
        contains('adb'),
      );
      expect(
        await reg.readFile('oppo-watch2-apk', 'templates\\build.sh'),
        contains('aapt2'),
      );
      final files = await reg.listFiles('oppo-watch2-apk');
      expect(files, contains('templates/res/values/strings.xml'));
    });

    test('外部同名覆盖内置，新 skill 加入列表', () async {
      final reg = SkillRegistry(DiskAssetReader(), () => [ext.path]);
      final list = await reg.reload();
      expect(
        list.map((s) => s.name),
        containsAll(['oppo-watch2-apk', 'round-watch']),
      );
      expect(reg['oppo-watch2-apk']!.builtin, isFalse);
      expect(reg['oppo-watch2-apk']!.description, '外部覆盖版');
      expect(await reg.loadSkill('oppo-watch2-apk'), contains('# 外部'));
      expect(await reg.readFile('round-watch', 'references/a.md'), '参考A');
    });

    test('read_skill_file 拒绝路径穿越', () async {
      final reg = SkillRegistry(DiskAssetReader(), () => [ext.path]);
      await reg.reload();
      for (final bad in [
        '../secret.txt',
        '..\\secret.txt',
        'references/../../secret.txt',
        '/etc/passwd',
        'C:/Windows/win.ini',
      ]) {
        await expectLater(
          reg.readFile('round-watch', bad),
          throwsA(isA<SkillException>()),
          reason: bad,
        );
      }
      final builtin = SkillRegistry(DiskAssetReader(), () => const []);
      await builtin.reload();
      await expectLater(
        builtin.readFile('oppo-watch2-apk', '../../prompts/system_prompt.md'),
        throwsA(isA<SkillException>()),
      );
      await expectLater(reg.loadSkill('不存在'), throwsA(isA<SkillException>()));
    });

    test('/skill-name 解析', () async {
      final reg = SkillRegistry(
        MapAssetReader({
          'assets/skills/oppo-watch2-apk/SKILL.md':
              '---\nname: oppo-watch2-apk\ndescription: d\n---\n',
        }),
        () => const [],
      );
      await reg.reload();
      final r = reg.parseSlash('/oppo-watch2-apk 做一个计步器');
      expect(r.names, ['oppo-watch2-apk']);
      expect(r.rest, '做一个计步器');
      expect(reg.parseSlash('/unknown 你好').names, isEmpty);
      expect(reg.parseSlash('普通消息 /oppo-watch2-apk').names, isEmpty);
    });
  });
}
