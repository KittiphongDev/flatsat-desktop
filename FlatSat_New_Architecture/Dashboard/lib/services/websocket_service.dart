import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/telemetry_data.dart';

/// Central WebSocket service that manages the connection to gs_bridge.py
/// and exposes reactive state to the UI via ChangeNotifier.
class WebSocketService extends ChangeNotifier {
  WebSocketChannel? _channel;
  bool _isConnected = false;
  Timer? _reconnectTimer;
  Timer? _epsTimeout;
  Process? _bridgeProcess;

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
  List<ImageEntry> imageList = [];
  DownloadProgress? downloadProgress;
  bool isDownloading = false;
  String? downloadCompleteFile;
  List<String> eventLog = [];

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

  // ---- Serial / bridge status (drives the in-app connection helper) ----
  bool serialConnected = false;
  String? currentPort;
  String? serialError;
  List<SerialPort> availablePorts = [];

  String _wsUrl = 'ws://localhost:8080';

  bool get isConnected => _isConnected;
  String get wsUrl => _wsUrl;

  WebSocketService() {
    _startPythonBridge().then((_) {
      connect();
    });
  }

  /// Automatically spawn the Python bridge when the app opens
  Future<void> _startPythonBridge() async {
    // Try to locate the PC_Bridge directory
    String? bridgeDir;
    final possibleDirs = [
      '../PC_Bridge', // flutter run from Dashboard folder
      '../../../../../../PC_Bridge', // from built linux bundle
      './PC_Bridge', // if user copied PC_Bridge next to the bundle
    ];

    for (String dir in possibleDirs) {
      if (File('$dir/gs_bridge.py').existsSync()) {
        bridgeDir = dir;
        break;
      }
    }

    if (bridgeDir != null) {
      try {
        _addLog('Auto-starting Python Bridge from $bridgeDir');
        _bridgeProcess = await Process.start(
          'python3',
          ['gs_bridge.py'],
          workingDirectory: bridgeDir,
        );
        // Wait a moment for the Python web socket server to bind to port 8080
        await Future.delayed(const Duration(seconds: 1));
      } catch (e) {
        _addLog('Failed to auto-start bridge: $e');
      }
    } else {
      _addLog('Warning: Could not locate gs_bridge.py for auto-start.');
    }
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
      _addLog('Connection failed (is the Python bridge running?)');
      _isConnected = false;
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
          _flash('Satellite acknowledged ✓');
          break;

        case 'nack':
          _addLog('NACK: ${data['data'] ?? 'Failed'}');
          _flash('Command failed on satellite', error: true);
          break;

        case 'gps':
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
          epsReceiving = epsProgress < 100;
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
            _epsTimeout = Timer(const Duration(seconds: 8), () {
              if (epsReceiving && epsProgress < 100) {
                epsReceiving = false;
                _flash('EPS transfer stalled — try GET EPS again', error: true);
                notifyListeners();
              }
            });
          }
          break;

        case 'image_list':
          imageList = (data['data'] as List)
              .map((e) => ImageEntry.fromJson(e))
              .toList();
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
          break;

        case 'download_progress':
          downloadProgress = DownloadProgress.fromJson(data['data']);
          break;

        case 'download_complete':
          isDownloading = false;
          downloadCompleteFile = data['data']['path'];
          final size = data['data']['size'] ?? 0;
          final elapsed = data['data']['elapsed'] ?? 0;
          _addLog('Download complete: $downloadCompleteFile '
              '(${size}B in ${elapsed}s)');
          _flash('Download complete');
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
    _send({'cmd': 'ping'});
    _addLog('>> PING');
  }

  void sendStatus() {
    _send({'cmd': 'status'});
    _addLog('>> STATUS');
  }

  void sendBeacon() {
    _send({'cmd': 'beacon'});
    _addLog('>> BEACON');
  }

  void sendTakePic() {
    _send({'cmd': 'take_pic'});
    _addLog('>> TAKE_PIC');
  }

  void sendGetGps() {
    _send({'cmd': 'get_gps'});
    _addLog('>> GET_GPS');
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
    _epsTimeout = Timer(const Duration(seconds: 8), () {
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
      }
    } catch (_) {
      // Not a power ACK (e.g. ping ack) — ignore.
    }
  }

  void sendListImage() {
    _send({'cmd': 'list_image'});
    _addLog('>> LIST_IMAGE');
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

  @override
  void dispose() {
    _epsTimeout?.cancel();
    _bridgeProcess?.kill();
    _disconnect();
    super.dispose();
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
