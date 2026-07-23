import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which FlatSat build the ground station is talking to.
///
/// This is a *dashboard-side* UI setting. It does not change the firmware —
/// the OBC's camera behaviour is fixed by its own `CAMERA_MODE` compile-time
/// `#define`. Keep this in sync with the flashed firmware:
///  - [prototype]  → camera is always powered; no power switch is shown.
///  - [production] → camera is switched via PD4; a Camera power card + the
///                   auto-power-on-capture option become available.
enum CameraMode { prototype, production }

/// How image file sizes are displayed.
enum ImageSizeUnit { kbOnly, both }

extension ImageSizeUnitLabel on ImageSizeUnit {
  String get label => this == ImageSizeUnit.both ? 'KB and MB' : 'KB only';
}

/// A selectable camera capture resolution (all 4:3 for the 5 MP sensor).
class PicResolution {
  final int id;
  final String label;
  final String detail;
  const PicResolution(this.id, this.label, this.detail);
}

const List<PicResolution> kPicResolutions = [
  PicResolution(0, 'VGA', '640×480 · smallest, fastest'),
  PicResolution(1, 'SVGA', '800×600'),
  PicResolution(2, 'UXGA', '1600×1200'),
  PicResolution(3, '3 MP', '2048×1536'),
  PicResolution(4, '5 MP', '2592×1944 · full, slowest'),
];

/// Format a byte count per the user's [ImageSizeUnit] preference.
String formatImageSize(int bytes, ImageSizeUnit unit) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (unit == ImageSizeUnit.kbOnly) return '${kb.toStringAsFixed(1)} KB';
  final mb = bytes / (1024 * 1024);
  return '${kb.toStringAsFixed(1)} KB (${mb.toStringAsFixed(2)} MB)';
}

extension CameraModeLabel on CameraMode {
  String get label =>
      this == CameraMode.production ? 'Production' : 'Prototype';
  String get blurb => this == CameraMode.production
      ? 'Camera is powered through PD4 and can be switched on/off.'
      : 'Camera is always powered. You can take pictures but not switch it.';
}

/// Holds persisted user settings and notifies listeners on change.
///
/// Backed by shared_preferences so choices survive an app restart. Values are
/// loaded asynchronously in [load]; until that completes the defaults apply.
class SettingsService extends ChangeNotifier {
  static const _kCameraMode = 'camera_mode';
  static const _kAutoPower = 'camera_auto_power_on_capture';
  static const _kShowEventLog = 'show_event_log';
  static const _kShowBridgeLog = 'show_bridge_log';
  static const _kImageSizeUnit = 'image_size_unit';
  static const _kCommsLock = 'comms_lock_enabled';
  static const _kFirstRunDone = 'first_run_done';
  static const _kDownloadDir = 'download_dir';
  static const _kTimeAutoSync = 'time_auto_sync';
  static const _kPicResolution = 'pic_resolution';

  CameraMode _cameraMode = CameraMode.prototype;
  bool _autoPowerOnCapture = false;
  bool _showEventLog = true;
  bool _showBridgeLog = true;
  ImageSizeUnit _imageSizeUnit = ImageSizeUnit.both;
  bool _commsLockEnabled = true;
  bool _firstRunDone = false;
  String? _downloadDir;
  bool _timeAutoSync = true;
  int _picResolution = 0;
  bool _loaded = false;

  CameraMode get cameraMode => _cameraMode;
  bool get isProduction => _cameraMode == CameraMode.production;

  /// How image sizes are shown (KB only, or KB and MB).
  ImageSizeUnit get imageSizeUnit => _imageSizeUnit;

  /// When true (default), the Communication power channel can't be switched off
  /// from the ground (it would cut the radio link). Users can disable the lock.
  bool get commsLockEnabled => _commsLockEnabled;

  /// Whether the first-run setup guide has already been shown.
  bool get firstRunDone => _firstRunDone;

  /// Folder where downloaded images are saved (null until first resolved).
  String? get downloadDir => _downloadDir;

  /// Automatically sync the satellite clock whenever the link connects.
  bool get timeAutoSync => _timeAutoSync;

  /// Remembered capture resolution id (index into [kPicResolutions]).
  int get picResolution => _picResolution;

  /// Show the EVENT LOG terminal panel (app-level commands & responses).
  bool get showEventLog => _showEventLog;

  /// Show the BRIDGE TRAFFIC terminal panel (raw serial TX/RX frames).
  bool get showBridgeLog => _showBridgeLog;

  /// Only meaningful in production; in prototype the camera is always on.
  bool get autoPowerOnCapture => isProduction && _autoPowerOnCapture;

  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeStr = prefs.getString(_kCameraMode);
      _cameraMode = modeStr == 'production'
          ? CameraMode.production
          : CameraMode.prototype;
      _autoPowerOnCapture = prefs.getBool(_kAutoPower) ?? false;
      _showEventLog = prefs.getBool(_kShowEventLog) ?? true;
      _showBridgeLog = prefs.getBool(_kShowBridgeLog) ?? true;
      _imageSizeUnit = prefs.getString(_kImageSizeUnit) == 'kbOnly'
          ? ImageSizeUnit.kbOnly
          : ImageSizeUnit.both;
      _commsLockEnabled = prefs.getBool(_kCommsLock) ?? true;
      _firstRunDone = prefs.getBool(_kFirstRunDone) ?? false;
      _downloadDir = prefs.getString(_kDownloadDir);
      _timeAutoSync = prefs.getBool(_kTimeAutoSync) ?? true;
      _picResolution = prefs.getInt(_kPicResolution) ?? 0;
    } catch (_) {
      // First run / no store yet — keep defaults.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setCameraMode(CameraMode mode) async {
    if (_cameraMode == mode) return;
    _cameraMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kCameraMode, mode == CameraMode.production ? 'production' : 'prototype');
    } catch (_) {}
  }

  Future<void> setShowEventLog(bool value) async {
    if (_showEventLog == value) return;
    _showEventLog = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShowEventLog, value);
    } catch (_) {}
  }

  Future<void> setShowBridgeLog(bool value) async {
    if (_showBridgeLog == value) return;
    _showBridgeLog = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kShowBridgeLog, value);
    } catch (_) {}
  }

  Future<void> setAutoPowerOnCapture(bool value) async {
    if (_autoPowerOnCapture == value) return;
    _autoPowerOnCapture = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoPower, value);
    } catch (_) {}
  }

  Future<void> setImageSizeUnit(ImageSizeUnit value) async {
    if (_imageSizeUnit == value) return;
    _imageSizeUnit = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kImageSizeUnit, value == ImageSizeUnit.kbOnly ? 'kbOnly' : 'both');
    } catch (_) {}
  }

  Future<void> setCommsLockEnabled(bool value) async {
    if (_commsLockEnabled == value) return;
    _commsLockEnabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kCommsLock, value);
    } catch (_) {}
  }

  Future<void> setFirstRunDone(bool value) async {
    if (_firstRunDone == value) return;
    _firstRunDone = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kFirstRunDone, value);
    } catch (_) {}
  }

  Future<void> setDownloadDir(String path) async {
    if (_downloadDir == path) return;
    _downloadDir = path;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDownloadDir, path);
    } catch (_) {}
  }

  Future<void> setTimeAutoSync(bool value) async {
    if (_timeAutoSync == value) return;
    _timeAutoSync = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kTimeAutoSync, value);
    } catch (_) {}
  }

  Future<void> setPicResolution(int id) async {
    if (_picResolution == id) return;
    _picResolution = id;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPicResolution, id);
    } catch (_) {}
  }

  /// Resolve the save folder, defaulting to <Documents>/FlatSat Images on first
  /// use. Returns the folder (created lazily by the bridge when it saves).
  Future<String> ensureDownloadDir() async {
    if (_downloadDir != null && _downloadDir!.isNotEmpty) return _downloadDir!;
    String base = '.';
    try {
      final docs = await getApplicationDocumentsDirectory();
      base = docs.path;
    } catch (_) {}
    final dir = '$base/FlatSat Images';
    await setDownloadDir(dir);
    return dir;
  }
}
