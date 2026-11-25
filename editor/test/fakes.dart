import 'dart:async';
import 'dart:io';

import 'package:android_watch_editor/services/process_runner.dart';
import 'package:android_watch_editor/services/skill_registry.dart';

/// 真实 OPPO OWW251（圆屏，Android 11）adb 输出样例。
const oww251 = {
  'getprop ro.product.model': 'OWW251\r\n',
  'getprop ro.product.brand': 'OPPO\r\n',
  'getprop ro.build.version.sdk': '30\r\n',
  'getprop ro.build.version.release': '11\r\n',
  'getprop ro.product.cpu.abi': 'armeabi-v7a\r\n',
  'wm size': 'Physical size: 466x466\r\n',
  'wm density': 'Physical density: 320\r\n',
  'dumpsys display': '''Display Devices: size=1
  DisplayDeviceInfo{"内置屏幕": uniqueId="local:19260786536790913", 466 x 466, modeId 1, defaultModeId 1, supportedModes [{id=1, width=466, height=466, fps=60.000004}], density 320, 319.902 x 319.902 dpi, touch INTERNAL, rotation 0, type INTERNAL}
    mBaseDisplayInfo=DisplayInfo{"内置屏幕", displayId 0, FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS, FLAG_ROUND, FLAG_TRUSTED, real 466 x 466, largest app 466 x 466, smallest app 466 x 466, rotation 0, state ON, type INTERNAL, app 466 x 466, density 320 (319.902 x 319.902)}
''',
  'pm list features': '''feature:reqGlEsVersion=0x30002
feature:android.hardware.type.watch
feature:android.hardware.touchscreen
feature:oplus.wear.screen.round
feature:oplus.wear.screen.round.big
''',
};

/// OPPO Watch 2 OW20W2（方屏，Android 8.1）样例。
const ow20w2 = {
  'getprop ro.product.model': 'OW20W2\r\n',
  'getprop ro.product.brand': 'OPPO\r\n',
  'getprop ro.build.version.sdk': '27\r\n',
  'getprop ro.build.version.release': '8.1.0\r\n',
  'getprop ro.product.cpu.abi': 'armeabi-v7a\r\n',
  'wm size': 'Physical size: 372x430\r\n',
  'wm density': 'Physical density: 320\r\n',
  'dumpsys display': '''  mBaseDisplayInfo=DisplayInfo{"Built-in Screen", uniqueId "local:0", app 372 x 430, real 372 x 430, largest app 430 x 430, smallest app 372 x 372, mode 1, defaultMode 1, rotation 0, type BUILT_IN, state ON, FLAG_SECURE, FLAG_SUPPORTS_PROTECTED_BUFFERS}
''',
  'pm list features': '''feature:android.hardware.type.watch
feature:android.hardware.touchscreen
''',
};

/// 按“adb shell <命令>”回放固定输出的假进程执行器。
class FakeRunner implements ProcessRunner {
  final Map<String, String> shellOutputs;
  String devicesOutput;
  final List<List<String>> calls = [];
  RunResult Function(String exe, List<String> args)? handler;
  bool hang = false;

  FakeRunner({
    this.shellOutputs = const {},
    this.devicesOutput = '',
    this.handler,
  });

  @override
  Future<RunResult> run(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    calls.add([executable, ...args]);
    if (hang) return const RunResult(exitCode: -1, timedOut: true);
    final h = handler;
    if (h != null) return h(executable, args);
    var a = args;
    if (a.length >= 2 && a[0] == '-s') a = a.sublist(2);
    if (a.length >= 2 && a[0] == 'devices')
      return RunResult.text(0, devicesOutput);
    if (a.length >= 2 && a[0] == 'shell') {
      final out = shellOutputs[a[1]];
      if (out == null) return RunResult.text(1, '', stderr: 'unknown');
      return RunResult.text(0, out);
    }
    return RunResult.text(1, '', stderr: 'unsupported');
  }
}

/// 内存资源。
class MapAssetReader implements AssetReader {
  final Map<String, String> files;
  MapAssetReader(this.files);

  @override
  Future<List<String>> listAssets() async => files.keys.toList();

  @override
  Future<String> loadString(String key) async {
    final v = files[key];
    if (v == null) throw StateError('missing $key');
    return v;
  }

  @override
  Future<List<int>> loadBytes(String key) async =>
      (await loadString(key)).codeUnits;
}

/// 从磁盘 assets/ 目录构造的资源读取器（模拟打包后的 AssetManifest）。
class DiskAssetReader implements AssetReader {
  @override
  Future<List<String>> listAssets() async =>
      Directory('assets')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.replaceAll('\\', '/'))
          .toList();

  @override
  Future<String> loadString(String key) => File(key).readAsString();

  @override
  Future<List<int>> loadBytes(String key) => File(key).readAsBytes();
}

Directory tempDir(String prefix) => Directory.systemTemp.createTempSync(prefix);
