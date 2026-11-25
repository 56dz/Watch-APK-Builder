import 'dart:convert';
import 'dart:io';

import '../models/device_profile.dart';
import 'adb_service.dart';

/// 解析 `wm size`：有 Override size 时优先。
(int, int)? parseWmSize(String output) {
  final over = RegExp(r'Override size:\s*(\d+)\s*x\s*(\d+)').firstMatch(output);
  final phys = RegExp(r'Physical size:\s*(\d+)\s*x\s*(\d+)').firstMatch(output);
  final m = over ?? phys;
  if (m == null) return null;
  return (int.parse(m.group(1)!), int.parse(m.group(2)!));
}

/// 解析 `wm density`：有 Override density 时优先。
int? parseWmDensity(String output) {
  final over = RegExp(r'Override density:\s*(\d+)').firstMatch(output);
  final phys = RegExp(r'Physical density:\s*(\d+)').firstMatch(output);
  final m = over ?? phys;
  return m == null ? null : int.parse(m.group(1)!);
}

/// `dumpsys display` 是否含 FLAG_ROUND。
bool hasFlagRound(String dumpsysDisplay) =>
    dumpsysDisplay.contains('FLAG_ROUND');

/// `pm list features` 中的圆屏类特性（如 oplus.wear.screen.round）。
List<String> parseRoundFeatures(String pmFeatures) {
  final found = <String>{};
  for (final m in RegExp(r'feature:(\S+)').allMatches(pmFeatures)) {
    final f = m.group(1)!.split('=').first;
    final l = f.toLowerCase();
    if (l.contains('screen.round') ||
        l.contains('screen_round') ||
        l.contains('round_screen') ||
        l.contains('roundscreen') ||
        l.contains('display.round')) {
      found.add(f);
    }
  }
  return found.toList()..sort();
}

/// 推断屏幕类型：FLAG_ROUND 或圆屏特性 → 圆屏；宽高相等但无标志 → 疑似圆屏；否则方屏。
ScreenShape inferShape({
  required int width,
  required int height,
  required bool flagRound,
  required List<String> roundFeatures,
}) {
  if (flagRound || roundFeatures.isNotEmpty) return ScreenShape.round;
  if (width > 0 && width == height) return ScreenShape.suspectedRound;
  return ScreenShape.square;
}

/// 把各命令的原始输出组装成设备档案（纯函数）。
DeviceProfile buildProfile({
  required String model,
  String brand = '',
  String sdk = '',
  String release = '',
  String abi = '',
  required String wmSize,
  required String wmDensity,
  required String dumpsysDisplay,
  required String pmFeatures,
  String sampledAt = '',
}) {
  final size = parseWmSize(wmSize);
  if (size == null) {
    throw AdbException('无法解析屏幕尺寸（wm size 输出：${wmSize.trim()}）');
  }
  final density = parseWmDensity(wmDensity);
  if (density == null) {
    throw AdbException('无法解析屏幕密度（wm density 输出：${wmDensity.trim()}）');
  }
  final flag = hasFlagRound(dumpsysDisplay);
  final features = parseRoundFeatures(pmFeatures);
  return DeviceProfile(
    model: model.trim(),
    brand: brand.trim(),
    sdk: int.tryParse(sdk.trim()),
    release: release.trim(),
    abi: abi.trim(),
    widthPx: size.$1,
    heightPx: size.$2,
    density: density,
    flagRound: flag,
    roundFeatures: features,
    shape: inferShape(
      width: size.$1,
      height: size.$2,
      flagRound: flag,
      roundFeatures: features,
    ),
    sampledAt: sampledAt,
  );
}

/// 设备档案库 devices.json（以型号为 key）。
class DeviceStore {
  final File file;
  Map<String, DeviceProfile>? _cache;

  DeviceStore(this.file);

  Future<Map<String, DeviceProfile>> loadAll() async {
    if (_cache != null) return _cache!;
    final map = <String, DeviceProfile>{};
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString());
        if (j is Map) {
          j.forEach((k, v) {
            if (k is String && v is Map)
              map[k] = DeviceProfile.fromJson(v.cast<String, dynamic>());
          });
        }
      }
    } on FormatException {
      // 文件损坏时当作空库，下一次保存会覆盖。
    }
    return _cache = map;
  }

  Future<DeviceProfile?> get(String model) async => (await loadAll())[model];

  Future<void> put(DeviceProfile profile) async {
    final all = await loadAll();
    all[profile.model] = profile;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(all.map((k, v) => MapEntry(k, v.toJson()))),
    );
    await tmp.rename(file.path);
  }
}

/// 设备采样：首次见到某型号时读取屏幕参数，之后直接读档案。
class DeviceProfiler {
  final AdbService adb;
  final DeviceStore store;

  DeviceProfiler(this.adb, this.store);

  Future<DeviceProfile> sample(String serial) async {
    final model = await adb.getProp(serial, 'ro.product.model');
    final brand = await adb.getProp(serial, 'ro.product.brand');
    final sdk = await adb.getProp(serial, 'ro.build.version.sdk');
    final release = await adb.getProp(serial, 'ro.build.version.release');
    final abi = await adb.getProp(serial, 'ro.product.cpu.abi');
    final size = await adb.shell(serial, 'wm size');
    final density = await adb.shell(serial, 'wm density');
    final display = await adb.shell(serial, 'dumpsys display');
    final features = await adb.shell(serial, 'pm list features');
    return buildProfile(
      model: model.isEmpty ? serial : model,
      brand: brand,
      sdk: sdk,
      release: release,
      abi: abi,
      wmSize: size,
      wmDensity: density,
      dumpsysDisplay: display,
      pmFeatures: features,
      sampledAt: DateTime.now().toIso8601String(),
    );
  }

  /// 有档案就用档案；[resample] 为 true 时强制重新采样并覆盖。
  /// 重新采样时保留用户对“疑似圆屏”的确认结果（屏幕参数未变时）。
  Future<({DeviceProfile profile, bool fromStore})> profileFor(
    String serial, {
    required String model,
    bool resample = false,
  }) async {
    final old = model.isEmpty ? null : await store.get(model);
    if (old != null && !resample) return (profile: old, fromStore: true);
    var fresh = await sample(serial);
    if (old != null &&
        old.userConfirmed &&
        fresh.shape == ScreenShape.suspectedRound &&
        old.widthPx == fresh.widthPx &&
        old.heightPx == fresh.heightPx) {
      fresh = fresh.copyWith(shape: old.shape, userConfirmed: true);
    }
    await store.put(fresh);
    return (profile: fresh, fromStore: false);
  }
}
