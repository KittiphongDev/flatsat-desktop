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
  Process? _bridgeProcess;

  // ---- Reactive State ----
  TelemetryData telemetry = TelemetryData();
  GpsData? lastGps;
  EpsData? lastEps;
  List<ImageEntry> imageList = [];
  DownloadProgress? downloadProgress;
  bool isDownloading = false;
  String? downloadCompleteFile;
  List<String> eventLog = [];

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
          break;

        case 'nack':
          _addLog('NACK: ${data['data'] ?? 'Failed'}');
          break;

        case 'gps':
          lastGps = GpsData.fromJson(data['data']);
          _addLog(
            'GPS: ${lastGps!.latitude.toStringAsFixed(6)}, '
            '${lastGps!.longitude.toStringAsFixed(6)} '
            'Alt=${lastGps!.altitude.toStringAsFixed(1)}m '
            'Sats=${lastGps!.satellites}',
          );
          break;

        case 'eps':
          lastEps = EpsData.fromJson(data['data']);
          _addLog('EPS: ${lastEps!.ina226.length} INA226, '
              '${lastEps!.tmp102.length} TMP102, '
              '${lastEps!.adm1177.length} ADM1177');
          break;

        case 'image_list':
          imageList = (data['data'] as List)
              .map((e) => ImageEntry.fromJson(e))
              .toList();
          _addLog('Image list: ${imageList.length} files');
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
  }

  void sendTogglePwr(int subsystem) {
    _send({'cmd': 'toggle_pwr', 'subsystem': subsystem});
    final names = ['Payload', 'GPS', 'Camera'];
    _addLog('>> TOGGLE_PWR ${names[subsystem]}');
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

  // ---- Event Log ----

  void _addLog(String msg) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    eventLog.insert(0, '[$timestamp] $msg');
    if (eventLog.length > 200) {
      eventLog.removeRange(200, eventLog.length);
    }
  }

  void clearLog() {
    eventLog.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _bridgeProcess?.kill();
    _disconnect();
    super.dispose();
  }
}
