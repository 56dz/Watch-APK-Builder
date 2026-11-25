import 'dart:io';

import 'package:android_watch_editor/models/device_profile.dart';
import 'package:android_watch_editor/services/adb_service.dart';
import 'package:android_watch_editor/services/device_profiler.dart';
import 'package:android_watch_editor/services/process_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

DeviceProfile fromSample(Map<String, String> s) => buildProfile(
  model: s['getprop ro.product.model']!,
  brand: s['getprop ro.product.brand']!,
  sdk: s['getprop ro.build.version.sdk']!,
  release: s['getprop ro.build.version.release']!,
  abi: s['getprop ro.product.cpu.abi']!,
  wmSize: s['wm size']!,
  wmDensity: s['wm density']!,
  dumpsysDisplay: s['dumpsys display']!,
  pmFeatures: s['pm list features']!,
);

void main() {
  group('解析', () {
    test('OWW251 圆屏真实输出', () {
      final pr = fromSample(oww251);
      expect(pr.model, 'OWW251');
      expect(pr.brand, 'OPPO');
      expect(pr.sdk, 30);
      expect(pr.release, '11');
      expect(pr.abi, 'armeabi-v7a');
      expect(pr.widthPx, 466);
      expect(pr.heightPx, 466);
      expect(pr.density, 320);
      expect(pr.widthDp, 233);
      expect(pr.heightDp, 233);
      expect(pr.flagRound, isTrue);
      expect(pr.roundFeatures, [
        'oplus.wear.screen.round',
        'oplus.wear.screen.round.big',
      ]);
      expect(pr.shape, ScreenShape.round);
      expect(pr.dpLabel, '233x233 dp');
    });

    test('OW20W2 方屏', () {
      final pr = fromSample(ow20w2);
      expect(pr.widthPx, 372);
      expect(pr.heightPx, 430);
      expect(pr.density, 320);
      expect(pr.widthDp, 186);
      expect(pr.heightDp, 215);
      expect(pr.flagRound, isFalse);
      expect(pr.roundFeatures, isEmpty);
      expect(pr.shape, ScreenShape.square);
      expect(pr.sdk, 27);
    });

    test('Override size / density 优先', () {
      expect(parseWmSize('Physical size: 466x466\nOverride size: 400x400\n'), (
        400,
        400,
      ));
      expect(parseWmSize('Physical size: 372x430'), (372, 430));
      expect(parseWmSize('error'), isNull);
      expect(
        parseWmDensity('Physical density: 320\nOverride density: 280'),
        280,
      );
      expect(parseWmDensity('Physical density: 320'), 320);
    });

    test('宽高相等但无标志 → 疑似圆屏', () {
      expect(
        inferShape(
          width: 454,
          height: 454,
          flagRound: false,
          roundFeatures: const [],
        ),
        ScreenShape.suspectedRound,
      );
      expect(
        inferShape(
          width: 454,
          height: 454,
          flagRound: true,
          roundFeatures: const [],
        ),
        ScreenShape.round,
      );
      expect(
        inferShape(
          width: 372,
          height: 430,
          flagRound: false,
          roundFeatures: const ['x.screen.round'],
        ),
        ScreenShape.round,
      );
      expect(
        inferShape(
          width: 372,
          height: 430,
          flagRound: false,
          roundFeatures: const [],
        ),
        ScreenShape.square,
      );
    });

    test('无法解析的尺寸给中文错误', () {
      expect(
        () => buildProfile(
          model: 'X',
          wmSize: 'oops',
          wmDensity: 'Physical density: 320',
          dumpsysDisplay: '',
          pmFeatures: '',
        ),
        throwsA(
          isA<AdbException>().having(
            (e) => e.message,
            'message',
            contains('无法解析屏幕尺寸'),
          ),
        ),
      );
    });

    test('adb devices -l', () {
      final list = parseAdbDevices(
        'List of devices attached\r\n'
        '8b47f1c1               device product:OWW251 model:OWW251 device:OWW251 transport_id:1\r\n'
        '10.0.2.15:5555  offline\r\n'
        'abc unauthorized usb:1-1 transport_id:3\r\n\r\n',
      );
      expect(list.length, 3);
      expect(list[0].serial, '8b47f1c1');
      expect(list[0].isOnline, isTrue);
      expect(list[0].model, 'OWW251');
      expect(list[1].state, 'offline');
      expect(list[2].stateLabel, contains('未授权'));
    });

    test('设备档案 JSON 往返', () {
      final pr = fromSample(oww251);
      final back = DeviceProfile.fromJson(pr.toJson());
      expect(back.shape, ScreenShape.round);
      expect(back.widthPx, 466);
      expect(back.roundFeatures.length, 2);
      expect(pr.toPromptText(), contains('圆屏'));
      expect(pr.toPromptText(), contains('API 30'));
    });
  });

  group('DeviceProfiler', () {
    late Directory dir;
    setUp(() => dir = tempDir('awe_dev'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('首次采样写档案，再次连接读档案，重新采样会再跑 adb', () async {
      final runner = FakeRunner(shellOutputs: oww251);
      final adb = AdbService(runner, () => 'adb');
      final store = DeviceStore(File(p.join(dir.path, 'devices.json')));
      final profiler = DeviceProfiler(adb, store);

      final r1 = await profiler.profileFor('8b47f1c1', model: 'OWW251');
      expect(r1.fromStore, isFalse);
      expect(r1.profile.shape, ScreenShape.round);
      expect(
        File(p.join(dir.path, 'devices.json')).readAsStringSync(),
        contains('"OWW251"'),
      );
      final n = runner.calls.length;

      final store2 = DeviceStore(File(p.join(dir.path, 'devices.json')));
      final r2 = await DeviceProfiler(
        adb,
        store2,
      ).profileFor('8b47f1c1', model: 'OWW251');
      expect(r2.fromStore, isTrue);
      expect(r2.profile.widthPx, 466);
      expect(runner.calls.length, n);

      final r3 = await profiler.profileFor(
        '8b47f1c1',
        model: 'OWW251',
        resample: true,
      );
      expect(r3.fromStore, isFalse);
      expect(runner.calls.length, greaterThan(n));
      expect(
        runner.calls.every((c) => c[1] == '-s' && c[2] == '8b47f1c1'),
        isTrue,
      );
    });

    test('adb 超时给中文提示', () async {
      final runner = FakeRunner()..hang = true;
      final adb = AdbService(runner, () => 'adb');
      expect(
        () => adb.devices(),
        throwsA(
          isA<AdbException>().having((e) => e.message, 'm', contains('超时')),
        ),
      );
    });

    test('adb 无法启动给中文提示', () async {
      final runner = FakeRunner(
        handler: (e, a) =>
            throw const ProcessException('adb', [], '系统找不到指定的文件'),
      );
      final adb = AdbService(runner, () => 'C:/nope/adb.exe');
      expect(
        () => adb.devices(),
        throwsA(
          isA<AdbException>().having(
            (e) => e.message,
            'm',
            contains('无法启动 adb'),
          ),
        ),
      );
    });

    test('shell 失败带授权提示', () async {
      final runner = FakeRunner(
        handler: (e, a) =>
            RunResult.text(1, '', stderr: 'error: device unauthorized.'),
      );
      final adb = AdbService(runner, () => 'adb');
      expect(
        () => adb.shell('x', 'wm size'),
        throwsA(
          isA<AdbException>().having(
            (e) => e.message,
            'm',
            contains('允许 USB 调试'),
          ),
        ),
      );
    });
  });
}
