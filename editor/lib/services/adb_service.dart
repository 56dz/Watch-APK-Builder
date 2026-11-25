import 'dart:io';

import '../models/device_profile.dart';
import 'process_runner.dart';

class AdbException implements Exception {
  final String message;
  const AdbException(this.message);

  @override
  String toString() => message;
}

/// 解析 `adb devices -l` 输出。
List<AdbDevice> parseAdbDevices(String output) {
  final result = <AdbDevice>[];
  for (final raw in output.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty ||
        line.startsWith('List of devices') ||
        line.startsWith('*'))
      continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final attrs = <String, String>{};
    for (final t in parts.skip(2)) {
      final i = t.indexOf(':');
      if (i > 0) attrs[t.substring(0, i)] = t.substring(i + 1);
    }
    result.add(AdbDevice(parts[0], parts[1], attrs));
  }
  return result;
}

/// adb 调用封装：所有命令都有超时，失败抛带中文说明的 [AdbException]。
class AdbService {
  final ProcessRunner runner;
  final String Function() adbPath;
  final Duration timeout;

  AdbService(
    this.runner,
    this.adbPath, {
    this.timeout = const Duration(seconds: 20),
  });

  Future<RunResult> raw(
    List<String> args, {
    String? serial,
    Duration? timeout,
  }) async {
    final t = timeout ?? this.timeout;
    final full = [
      if (serial != null && serial.isNotEmpty) ...['-s', serial],
      ...args,
    ];
    final exe = adbPath().trim().isEmpty ? 'adb' : adbPath().trim();
    RunResult r;
    try {
      r = await runner.run(exe, full, timeout: t);
    } on ProcessException catch (e) {
      throw AdbException('无法启动 adb（$exe）：${e.message}。请在“设置”中检查 adb.exe 路径。');
    }
    if (r.timedOut) {
      throw AdbException(
        'adb 命令超时（${t.inSeconds} 秒）：adb ${full.join(' ')}。'
        '手表可能已息屏或连接中断，请唤醒手表、检查 USB 后重试。',
      );
    }
    return r;
  }

  static String errorText(RunResult r) {
    final e = r.stderr.trim();
    if (e.isNotEmpty) return e;
    final o = r.stdout.trim();
    return o.isNotEmpty ? o : '退出码 ${r.exitCode}';
  }

  static String _hint(String err) {
    if (err.contains('unauthorized')) return '（设备未授权：请在手表上点“允许 USB 调试”）';
    if (err.contains('offline')) return '（设备离线：请重新插拔 USB）';
    if (err.contains('not found')) return '（找不到设备：请确认已连接并在设备列表中选择）';
    return '';
  }

  Future<List<AdbDevice>> devices() async {
    final r = await raw(['devices', '-l']);
    if (r.exitCode != 0) throw AdbException('adb devices 执行失败：${errorText(r)}');
    return parseAdbDevices(r.stdout);
  }

  /// 执行 shell 命令并返回 stdout（换行统一为 \n）。命令失败且无输出时抛异常。
  Future<String> shell(
    String serial,
    String command, {
    Duration? timeout,
  }) async {
    final r = await raw(['shell', command], serial: serial, timeout: timeout);
    if (r.exitCode != 0 && r.stdout.trim().isEmpty) {
      final e = errorText(r);
      throw AdbException('adb shell "$command" 失败：$e${_hint(e)}');
    }
    return r.stdout.replaceAll('\r\n', '\n');
  }

  Future<String> getProp(String serial, String name) async =>
      (await shell(serial, 'getprop $name')).trim();

  /// 截图，返回 PNG 字节。
  Future<List<int>> screencap(String serial) async {
    final r = await raw(['exec-out', 'screencap', '-p'], serial: serial);
    if (r.exitCode != 0 || r.stdoutBytes.isEmpty) {
      throw AdbException('截图失败：${errorText(r)}');
    }
    return r.stdoutBytes;
  }

  Future<RunResult> install(
    String serial,
    String apkPath, {
    Duration? timeout,
  }) => raw(['install', '-r', apkPath], serial: serial, timeout: timeout);

  Future<RunResult> logcat(
    String serial, {
    int lines = 300,
    String filter = '',
  }) => raw([
    'logcat',
    '-d',
    '-t',
    '$lines',
    ...filter.trim().isEmpty
        ? const <String>[]
        : filter.trim().split(RegExp(r'\s+')),
  ], serial: serial);
}
