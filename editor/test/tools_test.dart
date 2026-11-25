import 'dart:convert';
import 'dart:io';

import 'package:android_watch_editor/services/adb_service.dart';
import 'package:android_watch_editor/services/process_runner.dart';
import 'package:android_watch_editor/services/skill_registry.dart';
import 'package:android_watch_editor/services/tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

void main() {
  late Directory root;
  late Directory project;
  setUp(() {
    root = tempDir('awe_tools');
    project = Directory(p.join(root.path, 'proj'))..createSync();
    File(p.join(root.path, 'outside.txt')).writeAsStringSync('秘密');
  });
  tearDown(() => root.deleteSync(recursive: true));

  ToolExecutor make({
    FakeRunner? runner,
    bool confirm = false,
    bool approve = true,
    String? serial = 's1',
    String? skillsDir,
    void Function(String)? onSkillSaved,
  }) {
    final r = runner ?? FakeRunner();
    return ToolExecutor(
      ToolEnvironment(
        projectDir: project.path,
        runner: r,
        adb: AdbService(r, () => 'adb'),
        skills: SkillRegistry(
          MapAssetReader({}),
          () => skillsDir == null ? const [] : [skillsDir],
        ),
        serial: () => serial,
        skillsDir: skillsDir,
        onSkillSaved: onSkillSaved,
        askPermission: () => confirm,
        confirm: (_, _) async => approve,
        maxOutputChars: 2000,
      ),
    );
  }

  test('save_skill 新建、拒绝重名、覆盖、校验名称', () async {
    final dir = p.join(root.path, 'skills');
    final saved = <String>[];
    final ex = make(skillsDir: dir, onSkillSaved: saved.add);
    final args = {
      'name': 'round-watch-tips',
      'description': "圆屏手表's 踩坑",
      'content': '# 踩坑\n\n- 现象 → 原因 → 解决',
    };
    var r = await ex.execute('save_skill', jsonEncode(args));
    expect(r.isError, isFalse, reason: r.content);
    final md = File(p.join(dir, 'round-watch-tips', 'SKILL.md'))
        .readAsStringSync();
    expect(
      md,
      startsWith(
        "---\nname: round-watch-tips\ndescription: '圆屏手表''s 踩坑'\n---\n\n# 踩坑",
      ),
    );
    expect(saved, ['round-watch-tips']);
    r = await ex.execute('save_skill', jsonEncode(args));
    expect(r.isError, isTrue);
    expect(r.content, contains('已存在'));
    r = await ex.execute(
      'save_skill',
      jsonEncode({...args, 'content': '新内容', 'overwrite': true}),
    );
    expect(r.isError, isFalse, reason: r.content);
    expect(
      File(p.join(dir, 'round-watch-tips', 'SKILL.md')).readAsStringSync(),
      contains('新内容'),
    );
    for (final bad in ['../x', 'a/b', '中文', '.hidden', '']) {
      r = await ex.execute('save_skill', jsonEncode({...args, 'name': bad}));
      expect(r.isError, isTrue, reason: bad);
    }
    expect(Directory(p.join(root.path, 'x')).existsSync(), isFalse);
    r = await make().execute('save_skill', jsonEncode(args));
    expect(r.isError, isTrue);
  });

  test('resolveInProject 拒绝路径穿越', () {
    for (final bad in [
      '../outside.txt',
      '..\\outside.txt',
      'a/../../outside.txt',
      '/etc/passwd',
      'C:\\Windows\\win.ini',
      'D:/x',
    ]) {
      expect(
        () => resolveInProject(project.path, bad),
        throwsA(isA<ToolException>()),
        reason: bad,
      );
    }
    expect(
      resolveInProject(project.path, 'app/src/Main.java'),
      p.join(p.normalize(p.absolute(project.path)), 'app', 'src', 'Main.java'),
    );
    expect(
      resolveInProject(project.path, 'a/../b.txt'),
      p.join(p.normalize(p.absolute(project.path)), 'b.txt'),
    );
  });

  test('文件工具拒绝越界读写', () async {
    final ex = make();
    final r1 = await ex.execute(
      'read_file',
      jsonEncode({'path': '../outside.txt'}),
    );
    expect(r1.isError, isTrue);
    expect(r1.content, contains('拒绝'));
    final r2 = await ex.execute(
      'write_file',
      jsonEncode({'path': '../evil.txt', 'content': 'x'}),
    );
    expect(r2.isError, isTrue);
    expect(File(p.join(root.path, 'evil.txt')).existsSync(), isFalse);
    final r3 = await ex.execute(
      'edit_file',
      jsonEncode({
        'path': '../outside.txt',
        'old_string': '秘密',
        'new_string': 'x',
      }),
    );
    expect(r3.isError, isTrue);
    expect(File(p.join(root.path, 'outside.txt')).readAsStringSync(), '秘密');
    final r4 = await ex.execute('list_files', jsonEncode({'path': '..'}));
    expect(r4.isError, isTrue);
  });

  test('write / read / edit / list', () async {
    final ex = make();
    expect(
      (await ex.execute(
        'write_file',
        jsonEncode({'path': 'app/a.txt', 'content': 'hello\nworld\nhello'}),
      )).isError,
      isFalse,
    );
    final read = await ex.execute(
      'read_file',
      jsonEncode({'path': 'app/a.txt'}),
    );
    expect(read.content, contains('2\tworld'));
    final dup = await ex.execute(
      'edit_file',
      jsonEncode({
        'path': 'app/a.txt',
        'old_string': 'hello',
        'new_string': 'hi',
      }),
    );
    expect(dup.isError, isTrue);
    expect(dup.content, contains('2 次'));
    final all = await ex.execute(
      'edit_file',
      jsonEncode({
        'path': 'app/a.txt',
        'old_string': 'hello',
        'new_string': 'hi',
        'replace_all': true,
      }),
    );
    expect(all.isError, isFalse);
    expect(
      File(p.join(project.path, 'app', 'a.txt')).readAsStringSync(),
      'hi\nworld\nhi',
    );
    final missing = await ex.execute(
      'edit_file',
      jsonEncode({'path': 'app/a.txt', 'old_string': 'zzz', 'new_string': 'y'}),
    );
    expect(missing.isError, isTrue);
    final list = await ex.execute('list_files', '{}');
    expect(list.content, contains('app/a.txt'));
    expect((await ex.execute('read_file', 'not json')).isError, isTrue);
    expect((await ex.execute('nope', '{}')).isError, isTrue);
  });

  test('run_command：确认被拒绝时不执行；输出截断', () async {
    final runner = FakeRunner(
      handler: (e, a) => RunResult.text(0, 'x' * 10000),
    );
    final denied = make(runner: runner, confirm: true, approve: false);
    final r = await denied.execute(
      'run_command',
      jsonEncode({'command': 'bash build.sh'}),
    );
    expect(r.isError, isTrue);
    expect(runner.calls, isEmpty);

    final ok = make(runner: runner, confirm: true, approve: true);
    final r2 = await ok.execute(
      'run_command',
      jsonEncode({'command': 'bash build.sh'}),
    );
    expect(runner.calls.single, ['bash', '-c', 'bash build.sh']);
    expect(r2.content, contains('退出码：0'));
    expect(r2.content, contains('中间省略'));
    expect(r2.content.length, lessThan(2200));
  });

  test('run_command 超时', () async {
    final runner = FakeRunner(
      handler: (e, a) => const RunResult(exitCode: -1, timedOut: true),
    );
    final r = await make(runner: runner).execute(
      'run_command',
      jsonEncode({'command': 'sleep 999', 'timeout_sec': 5}),
    );
    expect(r.isError, isTrue);
    expect(r.content, contains('超时'));
  });

  test('adb screencap 保存到 shots/，logcat 保存到 .editor/', () async {
    final png = [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      ...List.filled(30000, 1),
    ];
    final runner = FakeRunner(
      handler: (e, a) {
        if (a.contains('screencap'))
          return RunResult(exitCode: 0, stdoutBytes: png);
        if (a.contains('logcat'))
          return RunResult.text(0, 'E AndroidRuntime: FATAL EXCEPTION\r\n');
        return RunResult.text(1, '');
      },
    );
    String? shot;
    final ex = ToolExecutor(
      ToolEnvironment(
        projectDir: project.path,
        runner: runner,
        adb: AdbService(runner, () => 'adb'),
        skills: SkillRegistry(MapAssetReader({}), () => const []),
        serial: () => 's1',
        askPermission: () => false,
        confirm: (_, _) async => true,
        onScreenshot: (path) => shot = path,
      ),
    );
    final r = await ex.execute('adb', jsonEncode({'action': 'screencap'}));
    expect(r.isError, isFalse);
    expect(r.images.single, shot);
    expect(p.dirname(shot!), p.join(project.path, 'shots'));
    expect(File(shot!).lengthSync(), png.length);
    expect(runner.calls.last, [
      'adb',
      '-s',
      's1',
      'exec-out',
      'screencap',
      '-p',
    ]);

    final l = await ex.execute(
      'adb',
      jsonEncode({'action': 'logcat', 'filter': 'AndroidRuntime:E *:S'}),
    );
    expect(l.content, contains('FATAL'));
    expect(
      File(p.join(project.path, '.editor', 'last_logcat.txt')).existsSync(),
      isTrue,
    );
    expect(runner.calls.last, [
      'adb',
      '-s',
      's1',
      'logcat',
      '-d',
      '-t',
      '300',
      'AndroidRuntime:E',
      '*:S',
    ]);
  });

  test('adb 未选设备', () async {
    final r = await make(serial: null)
        .execute('adb', jsonEncode({'action': 'shell', 'command': 'ls'}));
    expect(r.isError, isTrue);
    expect(r.content, contains('尚未选择'));
  });
}
