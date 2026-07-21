/// Data model for telemetry received from the OBC via the Python bridge.
class TelemetryData {
  final int systemErrors;
  final bool payloadPwr;
  final bool gpsPwr;
  final bool camPwr;
  final int batteryPct;
  final int temperature;
  final int voltage;
  final String linkStatus;
  final double rssi;
  final double snr;
  final double lastPacketTime;

  TelemetryData({
    this.systemErrors = 0,
    this.payloadPwr = false,
    this.gpsPwr = false,
    this.camPwr = false,
    this.batteryPct = 0,
    this.temperature = 0,
    this.voltage = 0,
    this.linkStatus = 'LOST',
    this.rssi = 0.0,
    this.snr = 0.0,
    this.lastPacketTime = 0,
  });

  factory TelemetryData.fromJson(Map<String, dynamic> json) {
    return TelemetryData(
      systemErrors: json['system_errors'] ?? 0,
      payloadPwr: json['payload_pwr'] ?? false,
      gpsPwr: json['gps_pwr'] ?? false,
      camPwr: json['cam_pwr'] ?? false,
      batteryPct: json['battery_pct'] ?? 0,
      temperature: json['temperature'] ?? 0,
      voltage: json['voltage'] ?? 0,
      linkStatus: json['link_status'] ?? 'LOST',
      rssi: (json['rssi'] ?? 0).toDouble(),
      snr: (json['snr'] ?? 0).toDouble(),
      lastPacketTime: (json['last_packet_time'] ?? 0).toDouble(),
    );
  }

  TelemetryData copyWith({
    int? systemErrors,
    bool? payloadPwr,
    bool? gpsPwr,
    bool? camPwr,
    int? batteryPct,
    int? temperature,
    int? voltage,
    String? linkStatus,
    double? rssi,
    double? snr,
    double? lastPacketTime,
  }) {
    return TelemetryData(
      systemErrors: systemErrors ?? this.systemErrors,
      payloadPwr: payloadPwr ?? this.payloadPwr,
      gpsPwr: gpsPwr ?? this.gpsPwr,
      camPwr: camPwr ?? this.camPwr,
      batteryPct: batteryPct ?? this.batteryPct,
      temperature: temperature ?? this.temperature,
      voltage: voltage ?? this.voltage,
      linkStatus: linkStatus ?? this.linkStatus,
      rssi: rssi ?? this.rssi,
      snr: snr ?? this.snr,
      lastPacketTime: lastPacketTime ?? this.lastPacketTime,
    );
  }

  bool get isLinkActive => linkStatus == 'ACTIVE';

  String get errorString {
    if (systemErrors == 0) return 'No Errors';
    List<String> errors = [];
    if (systemErrors & 0x01 != 0) errors.add('I2C');
    if (systemErrors & 0x02 != 0) errors.add('SD');
    if (systemErrors & 0x04 != 0) errors.add('EPS');
    if (systemErrors & 0x08 != 0) errors.add('CAM');
    if (systemErrors & 0x10 != 0) errors.add('GPS');
    return errors.join(', ');
  }
}

/// GPS position data from the OBC.
class GpsData {
  final double latitude;
  final double longitude;
  final double altitude;
  final int satellites;

  GpsData({
    this.latitude = 0,
    this.longitude = 0,
    this.altitude = 0,
    this.satellites = 0,
  });

  factory GpsData.fromJson(Map<String, dynamic> json) {
    return GpsData(
      latitude: (json['latitude'] ?? 0).toDouble(),
      longitude: (json['longitude'] ?? 0).toDouble(),
      altitude: (json['altitude'] ?? 0).toDouble(),
      satellites: json['satellites'] ?? 0,
    );
  }
}

/// Full EPS telemetry dump from the OBC (INA226 / TMP102 / ADM1177).
class EpsData {
  final List<InaReading> ina226;
  final List<TmpReading> tmp102;
  final List<AdmReading> adm1177;

  EpsData({
    this.ina226 = const [],
    this.tmp102 = const [],
    this.adm1177 = const [],
  });

  factory EpsData.fromJson(Map<String, dynamic> json) {
    return EpsData(
      ina226: (json['ina226'] as List? ?? [])
          .map((e) => InaReading.fromJson(e))
          .toList(),
      tmp102: (json['tmp102'] as List? ?? [])
          .map((e) => TmpReading.fromJson(e))
          .toList(),
      adm1177: (json['adm1177'] as List? ?? [])
          .map((e) => AdmReading.fromJson(e))
          .toList(),
    );
  }
}

/// One INA226 channel: bus voltage (V) and current (A).
class InaReading {
  final int index;
  final double voltage;
  final double current;

  InaReading({this.index = 0, this.voltage = 0, this.current = 0});

  factory InaReading.fromJson(Map<String, dynamic> json) {
    return InaReading(
      index: json['index'] ?? 0,
      voltage: (json['voltage'] ?? 0).toDouble(),
      current: (json['current'] ?? 0).toDouble(),
    );
  }

  double get power => voltage * current;
}

/// One TMP102 channel: temperature in Celsius.
class TmpReading {
  final int index;
  final double temperature;

  TmpReading({this.index = 0, this.temperature = 0});

  factory TmpReading.fromJson(Map<String, dynamic> json) {
    return TmpReading(
      index: json['index'] ?? 0,
      temperature: (json['temperature'] ?? 0).toDouble(),
    );
  }
}

/// One ADM1177 channel: voltage (mV) and current (mA).
class AdmReading {
  final int index;
  final int voltageMv;
  final int currentMa;

  AdmReading({this.index = 0, this.voltageMv = 0, this.currentMa = 0});

  factory AdmReading.fromJson(Map<String, dynamic> json) {
    return AdmReading(
      index: json['index'] ?? 0,
      voltageMv: json['voltage_mv'] ?? 0,
      currentMa: json['current_ma'] ?? 0,
    );
  }
}

/// Image file entry from the OBC's SD card.
class ImageEntry {
  final String name;
  final int size;

  ImageEntry({required this.name, required this.size});

  factory ImageEntry.fromJson(Map<String, dynamic> json) {
    return ImageEntry(
      name: json['name'] ?? '',
      size: json['size'] ?? 0,
    );
  }

  String get sizeFormatted {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Download progress state.
class DownloadProgress {
  final String filename;
  final int bytesReceived;
  final int chunk;

  DownloadProgress({
    this.filename = '',
    this.bytesReceived = 0,
    this.chunk = 0,
  });

  factory DownloadProgress.fromJson(Map<String, dynamic> json) {
    return DownloadProgress(
      filename: json['filename'] ?? '',
      bytesReceived: json['bytes_received'] ?? 0,
      chunk: json['chunk'] ?? 0,
    );
  }
}
