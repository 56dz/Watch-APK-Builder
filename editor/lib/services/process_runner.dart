import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 一次进程执行的结果。
class RunResult {
  final int exitCode;
  final List<int> stdoutBytes;
  final String stderr;
  final bool timedOut;

  const RunResult({
    required this.exitCode,
    this.stdoutBytes = const [],
    this.stderr = '',
    this.timedOut = false,
  });

  factory RunResult.text(int exitCode, String stdout, {String stderr = ''}) =>
      RunResult(
        exitCode: exitCode,
        stdoutBytes: utf8.encode(stdout),
        stderr: stderr,
      );

  String get stdout => utf8.decode(stdoutBytes, allowMalformed: true);
  bool get ok => exitCode == 0 && !timedOut;
}

/// 进程执行器抽象，测试时注入假实现。
abstract class ProcessRunner {
  /// 启动失败时抛 [ProcessException]；超时会结束进程并返回 timedOut=true。
  Future<RunResult> run(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 20),
  });
}

class IoProcessRunner implements ProcessRunner {
  /// stdout/stderr 各自最多保留的字节数，防止失控输出撑爆内存。
  final int maxBytes;

  const IoProcessRunner({this.maxBytes = 8 * 1024 * 1024});

  @override
  Future<RunResult> run(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final proc = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    void add(BytesBuilder b, List<int> d) {
      if (b.length < maxBytes) b.add(d);
    }

    final outDone = proc.stdout.listen((d) => add(out, d)).asFuture<void>();
    final errDone = proc.stderr.listen((d) => add(err, d)).asFuture<void>();
    var timedOut = false;
    int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      code = -1;
      await _kill(proc);
    }
    await Future.wait([outDone, errDone])
        .timeout(const Duration(seconds: 3), onTimeout: () => const []);
    return RunResult(
      exitCode: code,
      stdoutBytes: out.takeBytes(),
      stderr: utf8.decode(err.takeBytes(), allowMalformed: true),
      timedOut: timedOut,
    );
  }

  static Future<void> _kill(Process proc) async {
    if (Platform.isWindows) {
      // 连同子进程一起结束（bash 启动的 javac/adb 等）。
      try {
        await Process.run('taskkill', [
          '/T',
          '/F',
          '/PID',
          '${proc.pid}',
        ]).timeout(const Duration(seconds: 5));
      } catch (_) {
        proc.kill();
      }
    } else {
      proc.kill(ProcessSignal.sigkill);
    }
  }
}
