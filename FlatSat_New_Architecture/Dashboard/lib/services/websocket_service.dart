import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/telemetry_data.dart';
// Desktop builds get the real launcher (dart:io); web gets a no-op stub.
import 'bridge_launcher_stub.dart'
    if (dart.library.io) 'bridge_launcher.dart';

/// Central WebSocket service that manages the connection to gs_bridge.py
/// and exposes reactive state to the UI via ChangeNotifier.
class WebSocketService extends ChangeNotifier {
  WebSocketChannel? _channel;
  bool _isConnected = false;
  Timer? _reconnectTimer;
  Timer? _epsTimeout;
  Timer? _downloadTimeout;

  // ---- Reactive State ----
  TelemetryData telemetry = TelemetryData();
  GpsData? lastGps;
  EpsData? lastEps;

  // Rolling EPS history for live charts.
  static const int epsHistoryCap = 60;
  final List<EpsData> epsHistory = [];
  int epsPacketCount = 0;
  DateTime? lastEpsTime; // when the most recent EPS packet arrived

  // EPS chunked-transfer progress.
  bool epsReceiving = false;
  int epsProgress = 0; // 0..100
  int epsChunksReceived = 0;
  int epsChunksTotal = 0;
  int epsBytes = 0; // bytes reassembled so far
  double epsSpeedBps = 0; // receive speed, bytes/second
  DateTime? _epsProgressAt;
  int _epsLastBytes = 0;

  // Device health (STATUS scan).
  List<DeviceHealth> deviceHealth = [];
  DateTime? lastHealthTime;

  // Generic transfer progress (drives the % loaders) for health + image list.
  final TransferState healthXfer = TransferState();
  final TransferState imageXfer = TransferState();

  // GPS is a single-frame request; just a spinner while we wait for the reply.
  bool gpsRequesting = false;

  // Camera payload power (production build only, ADM-independent PD4 line).
  // Not carried in the beacon, so this is tracked from the toggle ACK echo.
  // Defaults to false (off); in a prototype build the camera is always powered
  // and this field is simply unused.
  bool cameraPwr = false;

  // Ping round-trip time.
  int? pingRttMs;
  DateTime? _pingSentAt;
  bool _pingPending = false;
  List<ImageEntry> imageList = [];
  DownloadProgress? downloadProgress;
  bool isDownloading = false;
  String? downloadCompleteFile;
  List<String> eventLog = [];

  /// Raw serial traffic mirrored from the bridge (TX/RX frames + link errors).
  List<String> bridgeLog = [];

  // ---- Ephemeral command feedback (drives SnackBar toasts) ----
  int feedbackSeq = 0;
  String feedbackMessage = '';
  bool feedbackIsError = false;

  void _flash(String msg, {bool error = false}) {
    feedbackMessage = msg;
    feedbackIsError = error;
    feedbackSeq++;
    notifyListeners();
  }

  /// Client-side download watchdog: if the bridge itself dies mid-download
  /// (so not even a download_failed arrives), resolve the spinner after 40s.
  /// Refreshed on every progress message.
  void _armDownloadWatchdog() {
    _downloadTimeout?.cancel();
    _downloadTimeout = Timer(const Duration(seconds: 40), () {
      if (isDownloading) {
        isDownloading = false;
        _flash('Download stalled — no data from the bridge', error: true);
        notifyListeners();
      }
    });
  }

  // ---- Serial / bridge status (drives the in-app connection helper) ----
  bool serialConnected = false;
  String? currentPort;
  String? serialError;
  List<SerialPort> availablePorts = [];

  String _wsUrl = 'ws://localhost:8080';

  bool get isConnected => _isConnected;
  String get wsUrl => _wsUrl;

  WebSocketService() {
    // Connect first: if a bridge is already running (launcher script, previous
    // session) we just use it. Only when the connection FAILS does connect()
    // spawn our own bridge process — so two bridges never fight for port 8080.
    connect();
  }

  /// Connect to the Python bridge WebSocket.
  void connect({String? url}) async {
    if (url != null) _wsUrl = url;
    _disconnect();

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      
      // Wait for connection to establish, throws if server is down
      await _channel!.ready;

      _isConnected = true;
      _addLog('Connected to $_wsUrl');
      notifyListeners();

      _channel!.stream.listen(
        _onMessage,
        onError: (error) {
          _addLog('WebSocket error: $error');
          _isConnected = false;
          notifyListeners();
          _scheduleReconnect();
        },
        onDone: () {
          _addLog('WebSocket disconnected');
          _isConnected = false;
          notifyListeners();
          _scheduleReconnect();
        },
      );
    } catch (e) {
      _isConnected = false;
      // No bridge answered — start one ourselves (desktop only; throttled;
      // no-op if our child process is already running or on the web build).
      if (!BridgeLauncher.running) {
        _addLog('Bridge not reachable — starting it…');
        await BridgeLauncher.start(_addLog);
      }
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _disconnect() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      _addLog('Reconnecting...');
      connect();
    });
  }

  // ---- Incoming Message Handler ----

  void _onMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String);
      final type = data['type'] as String?;

      switch (type) {
        case 'telemetry':
          telemetry = TelemetryData.fromJson(data['data']);
          break;

        case 'ack':
          _addLog('ACK: ${data['data'] ?? 'OK'}');
          _applyPowerAck(data['data']);
          // If a ping is outstanding, this ACK is its pong — record RTT.
          if (_pingPending && _pingSentAt != null) {
            pingRttMs = DateTime.now().difference(_pingSentAt!).inMilliseconds;
            _pingPending = false;
            _flash('Pong · ${pingRttMs}ms round-trip');
          } else {
            _flash('Satellite acknowledged ✓');
          }
          break;

        case 'health':
          deviceHealth = ((data['data'] as List?) ?? [])
              .map((e) => DeviceHealth.fromJson(e))
              .toList();
          lastHealthTime = DateTime.now();
          healthXfer.markDone();
          final online = deviceHealth.where((d) => d.online).length;
          _addLog('HEALTH: $online/${deviceHealth.length} devices online');
          _flash('Health scan: $online/${deviceHealth.length} online');
          break;

        case 'health_progress':
          healthXfer.applyProgress(data['data'] as Map<String, dynamic>);
          break;

        case 'health_failed':
          healthXfer.markFailed();
          _addLog('Health scan failed: ${data['data']}');
          _flash('Health scan failed — try again', error: true);
          break;

        case 'image_progress':
          imageXfer.applyProgress(data['data'] as Map<String, dynamic>);
          break;

        case 'image_failed':
          imageXfer.markFailed();
          _addLog('Image list failed: ${data['data']}');
          _flash('Image list failed — try again', error: true);
          break;

        case 'gps_failed':
          gpsRequesting = false;
          _addLog('GPS failed: ${data['data']}');
          _flash('No GPS reply — try again', error: true);
          break;

        case 'nack':
          _addLog('NACK: ${data['data'] ?? 'Failed'}');
          _flash('Command failed on satellite', error: true);
          break;

        case 'gps':
          gpsRequesting = false;
          lastGps = GpsData.fromJson(data['data']);
          _addLog(
            'GPS: ${lastGps!.latitude.toStringAsFixed(6)}, '
            '${lastGps!.longitude.toStringAsFixed(6)} '
            'Alt=${lastGps!.altitude.toStringAsFixed(1)}m '
            'Sats=${lastGps!.satellites}',
          );
          _flash('GPS position received');
          break;

        case 'eps':
          lastEps = EpsData.fromJson(data['data']);
          epsPacketCount++;
          lastEpsTime = DateTime.now();
          epsHistory.add(lastEps!);
          if (epsHistory.length > epsHistoryCap) {
            epsHistory.removeRange(0, epsHistory.length - epsHistoryCap);
          }
          epsReceiving = false;
          epsProgress = 100;
          _epsTimeout?.cancel();
          _addLog('EPS: ${lastEps!.ina226.length} INA226, '
              '${lastEps!.tmp102.length} TMP102, '
              '${lastEps!.adm1177.length} ADM1177');
          _flash('EPS telemetry received');
          break;

        case 'eps_progress':
          final d = data['data'] as Map<String, dynamic>;
          epsChunksReceived = d['received'] ?? 0;
          epsChunksTotal = d['total'] ?? 0;
          epsProgress = d['percent'] ?? 0;
          // Note: epsReceiving is driven explicitly (sendGetEps -> true,
          // eps / eps_failed -> false), NOT derived from percent, so a stray
          // progress message can't revive a finished bar.
          // Compute receive speed (bytes/second) from chunk arrivals.
          final now = DateTime.now();
          final newBytes = d['bytes'] ?? epsBytes;
          if (_epsProgressAt != null) {
            final dt = now.difference(_epsProgressAt!).inMicroseconds / 1e6;
            if (dt > 0 && newBytes >= _epsLastBytes) {
              epsSpeedBps = (newBytes - _epsLastBytes) / dt;
            }
          }
          _epsProgressAt = now;
          _epsLastBytes = newBytes;
          epsBytes = newBytes;
          // Extend the safety window while chunks keep arriving.
          if (epsReceiving) {
            _epsTimeout?.cancel();
            _epsTimeout = Timer(const Duration(seconds: 16), () {
              if (epsReceiving && epsProgress < 100) {
                epsReceiving = false;
                _flash('EPS transfer stalled — try GET EPS again', error: true);
                notifyListeners();
              }
            });
          }
          break;

        case 'eps_failed':
          epsReceiving = false;
          _epsTimeout?.cancel();
          _addLog('EPS failed: ${data['data']}');
          _flash('${data['data']}', error: true);
          break;

        case 'busy':
          _addLog('BUSY: ${data['data']}');
          _flash('Satellite busy — finish the current transfer first',
              error: true);
          break;

        case 'image_list':
          imageList = (data['data'] as List)
              .map((e) => ImageEntry.fromJson(e))
              .toList();
          imageXfer.markDone();
          _addLog('Image list: ${imageList.length} files');
          _flash('Images: ${imageList.length} file(s)');
          break;

        case 'download_started':
          isDownloading = true;
          downloadCompleteFile = null;
          downloadProgress = DownloadProgress(
            filename: data['data']['filename'] ?? '',
          );
          _addLog('Download started: ${data['data']['filename']}');
          _armDownloadWatchdog();
          break;

        case 'download_progress':
          downloadProgress = DownloadProgress.fromJson(data['data']);
          _armDownloadWatchdog();
          break;

        case 'download_complete':
          isDownloading = false;
          _downloadTimeout?.cancel();
          downloadCompleteFile = data['data']['path'];
          final size = data['data']['size'] ?? 0;
          final elapsed = data['data']['elapsed'] ?? 0;
          _addLog('Download complete: $downloadCompleteFile '
              '(${size}B in ${elapsed}s)');
          _flash('Download complete');
          break;

        case 'download_failed':
          isDownloading = false;
          _downloadTimeout?.cancel();
          final reason = data['data']?['reason'] ?? 'unknown error';
          _addLog('Download failed: $reason');
          _flash('Download failed — $reason', error: true);
          break;

        case 'bridge_status':
          final d = data['data'] as Map<String, dynamic>;
          final wasConnected = serialConnected;
          serialConnected = d['serial_connected'] == true;
          currentPort = d['port'] as String?;
          serialError = d['error'] as String?;
          availablePorts = ((d['available_ports'] as List?) ?? [])
              .map((e) => SerialPort.fromJson(e))
              .toList();
          if (serialConnected && !wasConnected) {
            _addLog('Serial connected: ${currentPort ?? ''}');
          } else if (!serialConnected && wasConnected) {
            _addLog('Serial disconnected');
          }
          break;

        case 'bridge_log':
          _addBridgeLog('${data['data']}');
          break;

        case 'error':
          _addLog('Error: ${data['data']}');
          break;
      }

      notifyListeners();
    } catch (e) {
      _addLog('Parse error: $e');
    }
  }

  // ---- Outgoing Commands ----

  void _send(Map<String, dynamic> data) {
    if (_channel != null && _isConnected) {
      _channel!.sink.add(jsonEncode(data));
    }
  }

  void sendPing() {
    _pingSentAt = DateTime.now();
    _pingPending = true;
    _send({'cmd': 'ping'});
    _addLog('>> PING');
    // Give up waiting for the pong after 5s.
    Timer(const Duration(seconds: 5), () {
      if (_pingPending) {
        _pingPending = false;
        pingRttMs = null;
        _flash('Ping timed out — no response', error: true);
        notifyListeners();
      }
    });
  }

  void sendStatus() {
    _send({'cmd': 'status'});
    _addLog('>> STATUS');
    healthXfer.begin();
    notifyListeners();
  }

  void sendBeacon() {
    _send({'cmd': 'beacon'});
    _addLog('>> BEACON');
  }

  void sendTakePic() {
    _send({'cmd': 'take_pic'});
    _addLog('>> TAKE_PIC');
  }

  /// Toggle the Arducam power line (PD4, subsystem 3). Production build only;
  /// the firmware NACKs this in a prototype build. Optimistically flips the UI;
  /// the OBC's ACK confirms the real state.
  void toggleCameraPower() {
    _send({'cmd': 'toggle_pwr', 'subsystem': 3});
    _addLog('>> TOGGLE_PWR Camera');
    cameraPwr = !cameraPwr;
    notifyListeners();
  }

  /// Take a picture, optionally powering the camera first.
  ///
  /// When [autoPower] is set (production + the auto-power setting) and the
  /// camera is currently off, this powers it on and waits for the sensor to
  /// boot before capturing — the dashboard-side implementation of "auto-power
  /// on capture", so no new firmware command is needed. In a prototype build
  /// the camera is always on, so [autoPower] should be false and this is a
  /// plain capture.
  Future<void> capturePhoto({bool autoPower = false}) async {
    if (autoPower && !cameraPwr) {
      toggleCameraPower();
      _flash('Powering camera…');
      // Cover the firmware's PD4 boot delay (~2 s) plus a little slack.
      await Future.delayed(const Duration(milliseconds: 2600));
    }
    sendTakePic();
  }

  void sendGetGps() {
    _send({'cmd': 'get_gps'});
    _addLog('>> GET_GPS');
    gpsRequesting = true;
    notifyListeners();
  }

  void sendGetEps() {
    _send({'cmd': 'get_eps'});
    _addLog('>> GET_EPS');
    // Begin a fresh transfer indicator; chunks will drive the percentage.
    epsReceiving = true;
    epsProgress = 0;
    epsChunksReceived = 0;
    epsChunksTotal = 0;
    epsBytes = 0;
    epsSpeedBps = 0;
    _epsLastBytes = 0;
    _epsProgressAt = DateTime.now();
    notifyListeners();
    // Safety: clear the indicator if the transfer never completes.
    _epsTimeout?.cancel();
    _epsTimeout = Timer(const Duration(seconds: 16), () {
      if (epsReceiving && epsProgress < 100) {
        epsReceiving = false;
        _flash('EPS transfer timed out — try GET EPS again', error: true);
        notifyListeners();
      }
    });
  }

  void sendTogglePwr(int subsystem) {
    _send({'cmd': 'toggle_pwr', 'subsystem': subsystem});
    final names = ['Payload', 'GPS', 'Camera'];
    _addLog('>> TOGGLE_PWR ${names[subsystem]}');
    // Optimistically flip the switch immediately for responsive UI.
    // The OBC's ACK (and the next beacon) will confirm the real state.
    switch (subsystem) {
      case 0:
        telemetry = telemetry.copyWith(payloadPwr: !telemetry.payloadPwr);
        break;
      case 1:
        telemetry = telemetry.copyWith(gpsPwr: !telemetry.gpsPwr);
        break;
      case 2:
        telemetry = telemetry.copyWith(camPwr: !telemetry.camPwr);
        break;
    }
    notifyListeners();
  }

  /// Apply the authoritative power state from an OBC ACK payload.
  /// The ACK data is a hex string: [subsystem_byte][state_byte], e.g. "0001".
  void _applyPowerAck(dynamic ackData) {
    if (ackData is! String || ackData.length < 4) return;
    try {
      final subsystem = int.parse(ackData.substring(0, 2), radix: 16);
      final isOn = int.parse(ackData.substring(2, 4), radix: 16) != 0;
      switch (subsystem) {
        case 0:
          telemetry = telemetry.copyWith(payloadPwr: isOn);
          break;
        case 1:
          telemetry = telemetry.copyWith(gpsPwr: isOn);
          break;
        case 2:
          telemetry = telemetry.copyWith(camPwr: isOn);
          break;
        case 3:
          cameraPwr = isOn; // Arducam PD4 line
          break;
      }
    } catch (_) {
      // Not a power ACK (e.g. ping ack) — ignore.
    }
  }

  void sendListImage() {
    _send({'cmd': 'list_image'});
    _addLog('>> LIST_IMAGE');
    imageXfer.begin();
    notifyListeners();
  }

  void sendRemoveImage(String filename) {
    _send({'cmd': 'remove_image', 'filename': filename});
    _addLog('>> REMOVE_IMAGE $filename');
  }

  void sendDownload(String filename) {
    _send({'cmd': 'download', 'filename': filename});
    _addLog('>> DOWNLOAD $filename');
  }

  // ---- Connection helper commands ----

  /// Ask the bridge for the list of available serial ports.
  void requestPorts() {
    _send({'cmd': 'list_ports'});
  }

  /// Tell the bridge to switch to a specific serial port ('' = auto-detect).
  void selectPort(String device) {
    _send({'cmd': 'set_port', 'port': device});
    _addLog('>> SET PORT ${device.isEmpty ? 'AUTO' : device}');
  }

  /// Force the whole connection to re-establish: reconnect the WebSocket if the
  /// bridge is down, otherwise tell the bridge to re-open the serial port.
  void reconnect() {
    if (_isConnected) {
      _send({'cmd': 'reconnect'});
      _addLog('>> RECONNECT');
    } else {
      _addLog('>> RECONNECT (bridge)');
      connect();
    }
  }

  /// Overall connection stage used by the in-app banner.
  ConnectionStage get stage {
    if (!_isConnected) return ConnectionStage.bridgeOffline;
    if (!serialConnected) return ConnectionStage.noGroundStation;
    if (!telemetry.isLinkActive) return ConnectionStage.waitingForSatellite;
    return ConnectionStage.live;
  }

  // ---- Event Log ----

  void _addLog(String msg) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    eventLog.insert(0, '[$timestamp] $msg');
    if (eventLog.length > 200) {
      eventLog.removeRange(200, eventLog.length);
    }
    // Any '>>' line is an outgoing command — surface a toast confirming it.
    if (msg.startsWith('>>')) {
      final label = msg.substring(2).trim();
      if (_isConnected) {
        _flash('$label sent');
      } else {
        _flash('Offline — "$label" not sent', error: true);
      }
    }
  }

  void clearLog() {
    eventLog.clear();
    notifyListeners();
  }

  void _addBridgeLog(String msg) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    bridgeLog.insert(0, '[$timestamp] $msg');
    if (bridgeLog.length > 300) {
      bridgeLog.removeRange(300, bridgeLog.length);
    }
  }

  void clearBridgeLog() {
    bridgeLog.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _epsTimeout?.cancel();
    _downloadTimeout?.cancel();
    _disconnect();
    BridgeLauncher.stop(); // stop the bridge we spawned (no-op otherwise)
    super.dispose();
  }
}

/// Progress of a chunked transfer (EPS / health / image list), used to drive
/// the in-panel percentage loaders.
class TransferState {
  bool active = false;
  int percent = 0;
  int received = 0;
  int total = 0;
  int bytes = 0;

  void begin() {
    active = true;
    percent = 0;
    received = 0;
    total = 0;
    bytes = 0;
  }

  void applyProgress(Map<String, dynamic> d) {
    received = d['received'] ?? 0;
    total = d['total'] ?? 0;
    percent = d['percent'] ?? 0;
    bytes = d['bytes'] ?? bytes;
    active = percent < 100;
  }

  void markDone() {
    active = false;
    percent = 100;
  }

  void markFailed() {
    active = false;
  }
}

/// Stages of the end-to-end connection, from the app to the satellite.
enum ConnectionStage {
  bridgeOffline, // WebSocket to the Python bridge is down
  noGroundStation, // Bridge up, but the GS serial port isn't open
  waitingForSatellite, // GS connected, but no beacon received yet
  live, // Receiving telemetry from the satellite
}

/// A serial port reported by the bridge.
class SerialPort {
  final String device;
  final String description;

  SerialPort({required this.device, required this.description});

  factory SerialPort.fromJson(Map<String, dynamic> json) {
    return SerialPort(
      device: json['device'] as String? ?? '',
      description: json['description'] as String? ?? '',
    );
  }

  String get label =>
      description.isEmpty ? device : '$device  —  $description';
}
