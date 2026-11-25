import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/chat_message.dart';

/// 会话持久化：<项目>/.editor/session.json。
class SessionStore {
  static File fileFor(String projectDir) =>
      File(p.join(projectDir, '.editor', 'session.json'));

  static Future<Session> load(String projectDir) async {
    final f = fileFor(projectDir);
    try {
      if (!await f.exists()) return Session();
      final j = jsonDecode(await f.readAsString());
      if (j is Map) return Session.fromJson(j.cast<String, dynamic>());
    } on FormatException {
      // 损坏的文件先备份，避免覆盖丢失。
      try {
        await f.copy('${f.path}.broken');
      } catch (_) {}
    } on FileSystemException {
      // 忽略，返回空会话
    }
    return Session();
  }

  /// 删除会话记录（<项目>/.editor/session.json），不动项目文件。
  static Future<void> delete(String projectDir) async {
    final f = fileFor(projectDir);
    for (final x in [f, File('${f.path}.tmp')]) {
      try {
        if (await x.exists()) await x.delete();
      } on FileSystemException {
        // 忽略
      }
    }
  }

  static Future<void> save(String projectDir, Session session) async {
    final f = fileFor(projectDir);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent(' ').convert(session.toJson()),
    );
    await tmp.rename(f.path);
  }
}

/// 工作区：每个手表 App 一个子目录。
class Workspace {
  final String root;
  Workspace(this.root);

  static final RegExp validName = RegExp(
    r'^[A-Za-z0-9_\-\u4e00-\u9fa5]{1,64}$',
  );

  List<String> listProjects() {
    final d = Directory(root);
    if (root.trim().isEmpty || !d.existsSync()) return [];
    return d
        .listSync()
        .whereType<Directory>()
        .map((e) => p.basename(e.path))
        .where((n) => !n.startsWith('.'))
        .toList()
      ..sort();
  }

  String pathOf(String name) => p.join(root, name);

  Future<String> create(String name) async {
    final n = name.trim();
    if (!validName.hasMatch(n)) {
      throw const FormatException('项目名只能包含字母、数字、下划线、短横线或中文，最长 64 字');
    }
    final dir = Directory(pathOf(n));
    if (await dir.exists()) throw FormatException('项目“$n”已存在');
    await dir.create(recursive: true);
    return dir.path;
  }
}
