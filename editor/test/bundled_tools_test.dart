import 'dart:io';

import 'package:android_watch_editor/services/bundled_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

void main() {
  test('便携版目录：全部在 exe 所在目录下', () {
    final dir = tempDir('awe_paths');
    addTearDown(() => dir.deleteSync(recursive: true));
    final paths = AppPaths.locate(p.join(dir.path, 'android_watch_editor.exe'));
    expect(paths.root, dir.path);
    for (final x in [
      paths.tools,
      paths.skills,
      paths.data,
      paths.workspace,
      paths.adb,
      paths.jdk,
      paths.bash,
      paths.r8,
    ]) {
      expect(p.isWithin(dir.path, x), isTrue, reason: x);
    }
    expect(
      paths.missingTools(),
      containsAll(['adb', 'jdk', 'git-bash', 'r8.jar']),
    );
    expect(toolOr(paths.adb, 'adb'), 'adb');

    File(paths.adb).createSync(recursive: true);
    Directory(paths.jdk).createSync(recursive: true);
    expect(toolOr(paths.adb, 'adb'), paths.adb);
    expect(toolOr(paths.jdk, '', directory: true), paths.jdk);
    expect(paths.missingTools(), isNot(contains('adb')));
  });
}
