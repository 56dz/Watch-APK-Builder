import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/app_config.dart';

/// 配置存储：便携版放在软件根目录 config/ 下（config.json、devices.json）。
class ConfigStore {
  final Directory dir;

  ConfigStore(this.dir);

  File get configFile => File(p.join(dir.path, 'config.json'));
  File get devicesFile => File(p.join(dir.path, 'devices.json'));

  Future<AppConfig> load(AppConfig defaults) async {
    try {
      if (!await configFile.exists()) return defaults;
      final j = jsonDecode(await configFile.readAsString());
      if (j is! Map) return defaults;
      return AppConfig.fromJson(j.cast<String, dynamic>(), defaults);
    } on FormatException {
      return defaults;
    } on FileSystemException {
      return defaults;
    }
  }

  Future<void> save(AppConfig config) async {
    await dir.create(recursive: true);
    final tmp = File('${configFile.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
    );
    await tmp.rename(configFile.path);
  }
}
