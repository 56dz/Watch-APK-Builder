import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Flutter 资源声明不递归：assets/ 下每个文件所在目录都必须在 pubspec.yaml 中声明。
void main() {
  test('assets/ 下每个文件都已在 pubspec.yaml 声明', () {
    final lines = File('pubspec.yaml').readAsLinesSync();
    final start = lines.indexWhere(
      (l) => RegExp(r'^  assets:\s*$').hasMatch(l),
    );
    expect(
      start,
      greaterThanOrEqualTo(0),
      reason: 'pubspec.yaml 缺少 flutter.assets',
    );
    final declared = <String>{};
    for (final l in lines.skip(start + 1)) {
      final m = RegExp(r'^    - (.+?)\s*$').firstMatch(l);
      if (m == null) {
        if (l.trim().isEmpty || l.trim().startsWith('#')) continue;
        break;
      }
      declared.add(m.group(1)!);
    }
    final files = Directory('assets')
        .listSync(recursive: true)
        .whereType<File>()
        .toList();
    expect(files, isNotEmpty);
    final missing = <String>[];
    for (final f in files) {
      final rel = p.relative(f.path).replaceAll('\\', '/');
      final dir = '${p.posix.dirname(rel)}/';
      if (!declared.contains(dir) && !declared.contains(rel)) missing.add(rel);
    }
    expect(missing, isEmpty, reason: '未声明的资源：${missing.join(', ')}');
    expect(declared, contains('assets/prompts/'));
    for (final d in Directory(
      'assets/skills',
    ).listSync().whereType<Directory>()) {
      final name = p.basename(d.path);
      expect(declared, contains('assets/skills/$name/'));
    }
  });
}
