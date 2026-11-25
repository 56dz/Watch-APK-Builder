import 'dart:io';

import 'package:android_watch_editor/services/bundled_tools.dart';
import 'package:android_watch_editor/services/config_store.dart';
import 'package:android_watch_editor/ui/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

const _header = 'List of devices attached\r\n';

void main() {
  late FakeRunner runner;
  late AppController c;

  setUp(() async {
    final dir = tempDir('awe_auto');
    addTearDown(() => dir.deleteSync(recursive: true));
    runner = FakeRunner(shellOutputs: ow20w2, devicesOutput: _header);
    c = AppController(
      runner: runner,
      httpClient: MockClient((r) async => http.Response('', 500)),
      configStore: ConfigStore(Directory('${dir.path}/data')),
      assets: MapAssetReader({'assets/prompts/system_prompt.md': '# t'}),
      paths: AppPaths(dir.path),
      pollInterval: const Duration(hours: 1),
    );
    await c.init();
    await c.refreshDevices(); // 等 init 里那次异步刷新落定
    addTearDown(c.dispose);
  });

  test('启动时无设备，插上手表后轮询自动识别并采样', () async {
    expect(c.profile, isNull);
    expect(c.deviceError, contains('自动识别'));

    runner.devicesOutput =
        '${_header}c1ab7fb4 device product:OW20W2 model:OW20W2 transport_id:2\r\n';
    await c.pollDevices();
    expect(c.selectedSerial, 'c1ab7fb4');
    expect(c.profile?.model, 'OW20W2');
    expect(c.profile?.widthPx, 372);
    expect(c.deviceError, isNull);
    expect(c.logs.any((l) => l.contains('检测到设备：OW20W2')), isTrue);
  });

  test('设备列表没变化时不重复采样', () async {
    runner.devicesOutput =
        '${_header}c1ab7fb4 device product:OW20W2 model:OW20W2\r\n';
    await c.pollDevices();
    final n = runner.calls.length;
    await c.pollDevices();
    expect(runner.calls.length, n + 1); // 只多了一次 adb devices
  });

  test('拔掉后清空选择，未授权给出提示', () async {
    runner.devicesOutput =
        '${_header}c1ab7fb4 device product:OW20W2 model:OW20W2\r\n';
    await c.pollDevices();
    runner.devicesOutput = _header;
    await c.pollDevices();
    expect(c.selectedSerial, isNull);
    expect(c.profile, isNull);
    expect(c.logs.any((l) => l.contains('设备已断开：c1ab7fb4')), isTrue);

    runner.devicesOutput = '${_header}c1ab7fb4 unauthorized\r\n';
    await c.pollDevices();
    expect(c.deviceError, contains('允许 USB 调试'));
  });

  test('关闭自动检测后不再启动定时器', () {
    c.setAutoDetect(false);
    expect(c.autoDetect, isFalse);
  });
}
