/// 屏幕类型。
enum ScreenShape {
  round('圆屏'),
  square('方屏'),
  suspectedRound('疑似圆屏');

  final String label;
  const ScreenShape(this.label);

  static ScreenShape fromName(String? n) => ScreenShape.values.firstWhere(
    (e) => e.name == n,
    orElse: () => ScreenShape.square,
  );
}

/// adb devices -l 中的一行。
class AdbDevice {
  final String serial;
  final String state;
  final Map<String, String> attributes;

  const AdbDevice(this.serial, this.state, [this.attributes = const {}]);

  bool get isOnline => state == 'device';
  String get model => attributes['model'] ?? '';

  String get stateLabel => switch (state) {
    'device' => '已连接',
    'offline' => '离线',
    'unauthorized' => '未授权（请在手表上允许 USB 调试）',
    _ => state,
  };
}

/// 设备档案，按型号存入 devices.json。
class DeviceProfile {
  final String model;
  final String brand;
  final int? sdk;
  final String release;
  final String abi;
  final int widthPx;
  final int heightPx;
  final int density;
  final bool flagRound;
  final List<String> roundFeatures;
  final ScreenShape shape;
  final bool userConfirmed;
  final String sampledAt;

  const DeviceProfile({
    required this.model,
    this.brand = '',
    this.sdk,
    this.release = '',
    this.abi = '',
    required this.widthPx,
    required this.heightPx,
    required this.density,
    this.flagRound = false,
    this.roundFeatures = const [],
    required this.shape,
    this.userConfirmed = false,
    this.sampledAt = '',
  });

  double get widthDp => density > 0 ? widthPx * 160 / density : 0;
  double get heightDp => density > 0 ? heightPx * 160 / density : 0;

  static String fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  String get dpLabel => '${fmt(widthDp)}x${fmt(heightDp)} dp';

  /// 写入系统提示的设备摘要。
  String toPromptText() {
    final b = StringBuffer()
      ..writeln('- 型号：$model（品牌 ${brand.isEmpty ? '未知' : brand}）')
      ..writeln(
        '- 屏幕：${shape.label}${userConfirmed ? '（用户已确认）' : ''}，$widthPx x $heightPx px，density $density，逻辑 $dpLabel',
      )
      ..writeln(
        '- 系统：Android $release / API ${sdk ?? '未知'}，ABI ${abi.isEmpty ? '未知' : abi}',
      );
    if (flagRound || roundFeatures.isNotEmpty) {
      b.writeln(
        '- 圆屏依据：${[if (flagRound) 'dumpsys display 含 FLAG_ROUND', ...roundFeatures].join('、')}',
      );
    }
    return b.toString().trimRight();
  }

  DeviceProfile copyWith({ScreenShape? shape, bool? userConfirmed}) =>
      DeviceProfile(
        model: model,
        brand: brand,
        sdk: sdk,
        release: release,
        abi: abi,
        widthPx: widthPx,
        heightPx: heightPx,
        density: density,
        flagRound: flagRound,
        roundFeatures: roundFeatures,
        shape: shape ?? this.shape,
        userConfirmed: userConfirmed ?? this.userConfirmed,
        sampledAt: sampledAt,
      );

  Map<String, dynamic> toJson() => {
    'model': model,
    'brand': brand,
    'sdk': sdk,
    'release': release,
    'abi': abi,
    'widthPx': widthPx,
    'heightPx': heightPx,
    'density': density,
    'widthDp': widthDp,
    'heightDp': heightDp,
    'flagRound': flagRound,
    'roundFeatures': roundFeatures,
    'shape': shape.name,
    'userConfirmed': userConfirmed,
    'sampledAt': sampledAt,
  };

  factory DeviceProfile.fromJson(Map<String, dynamic> j) => DeviceProfile(
    model: j['model'] as String? ?? '',
    brand: j['brand'] as String? ?? '',
    sdk: (j['sdk'] as num?)?.toInt(),
    release: j['release'] as String? ?? '',
    abi: j['abi'] as String? ?? '',
    widthPx: (j['widthPx'] as num?)?.toInt() ?? 0,
    heightPx: (j['heightPx'] as num?)?.toInt() ?? 0,
    density: (j['density'] as num?)?.toInt() ?? 0,
    flagRound: j['flagRound'] == true,
    roundFeatures:
        (j['roundFeatures'] as List?)?.whereType<String>().toList() ?? const [],
    shape: ScreenShape.fromName(j['shape'] as String?),
    userConfirmed: j['userConfirmed'] == true,
    sampledAt: j['sampledAt'] as String? ?? '',
  );
}
