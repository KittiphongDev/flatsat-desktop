import 'package:flutter/foundation.dart';
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

  CameraMode _cameraMode = CameraMode.prototype;
  bool _autoPowerOnCapture = false;
  bool _showEventLog = true;
  bool _showBridgeLog = true;
  bool _loaded = false;

  CameraMode get cameraMode => _cameraMode;
  bool get isProduction => _cameraMode == CameraMode.production;

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
}
