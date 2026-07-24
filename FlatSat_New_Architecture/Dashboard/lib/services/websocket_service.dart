import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/telemetry_data.dart';
import '../utils/eps_history.dart';
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
  static const int epsHistoryCap = 300;
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
  final TransferState epsLogXfer = TransferState(); // satellite log pull

  // When true (PC-history mode), each live EPS snapshot is persisted to CSV.
  bool persistLiveEps = false;
  String? epsHistoryFile; // path of the last-written history CSV

  // GPS is a single-frame request; just a spinner while we wait for the reply.
  bool gpsRequesting = false;

  // Folder where the bridge saves downloaded images (re-sent on each connect).
  String? _pendingDownloadDir;

  /// Tell the bridge where to save downloaded images.
  void setDownloadDir(String path) {
    _pendingDownloadDir = path;
    _send({'cmd': 'set_download_dir', 'path': path});
  }

  /// Dismiss the "saved" banner after a completed download.
  void clearDownloadResult() {
    downloadCompleteFile = null;
    notifyListeners();
  }

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
  bool downloadPaused = false;
  String? downloadCompleteFile;
  // Filename of the most recent photo the satellite reported saving (from the
  // TAKE_PIC ACK). Shown in the Image Manager until dismissed.
  String? lastCapturedFile;
  List<String> eventLog = [];

  void clearCapturedFile() {
    lastCapturedFile = null;
    notifyListeners();
  }

  /// Decode an ACK hex payload to a .jpg filename, or null if it isn't one.
  /// The TAKE_PIC ACK carries the saved filename as printable ASCII; power
  /// ACKs and ping pongs are short binary blobs that won't match.
  String? _decodePhotoName(dynamic hex) {
    if (hex is! String || hex.length < 8 || hex.length.isOdd) return null;
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (b == null || b < 0x20 || b > 0x7e) return null; // not printable ASCII
      bytes.add(b);
    }
    final s = String.fromCharCodes(bytes);
    final low = s.toLowerCase();
    return (low.endsWith('.jpg') || low.endsWith('.jpeg')) ? s : null;
  }

  /// Raw serial traffic mirrored from the bridge (TX/RX frames + link errors).
  List<String> bridgeLog = [];

  // ---- Ephemeral command feedback (drives SnackBar toasts) ----
  int feedbackSeq = 0;
  String feedbackMessage = '';
  bool feedbackIsError = false;
  bool feedbackIsSuccess = false; // green = confirmed success; red = error

  void _flash(String msg, {bool error = false, bool success = false}) {
    feedbackMessage = msg;
    feedbackIsError = error;
    feedbackIsSuccess = success;
    feedbackSeq++;
    notifyListeners();
  }

  Map<String, dynamic> _epsToRecord(EpsData e) => {
        't': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'ina226':
            e.ina226.map((r) => {'voltage': r.voltage, 'current': r.current}).toList(),
        'tmp102': e.tmp102.map((r) => {'temperature': r.temperature}).toList(),
        'adm1177': e.adm1177
            .map((r) => {'voltage_mv': r.voltageMv, 'current_ma': r.currentMa})
            .toList(),
      };

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

  String _wsUrl = 'ws://127.0.0.1:8080';

  // Try IPv4 loopback first, then names, then IPv6. On Linux "localhost" can
  // resolve to ::1 while the bridge listens on 127.0.0.1 (or vice-versa), so a
  // single host string can silently fail to connect even though the bridge is
  // up. Using the literal 127.0.0.1 first avoids that resolution mismatch.
  static const List<String> _wsCandidates = [
    'ws://127.0.0.1:8080',
    'ws://localhost:8080',
    'ws://[::1]:8080',
  ];

  bool get isConnected => _isConnected;
  String get wsUrl => _wsUrl;

  WebSocketService() {
    // Connect first: if a bridge is already running (launcher script, previous
    // session) we just use it. Only when the connection FAILS does connect()
    // spawn our own bridge process — so two bridges never fight for port 8080.
    connect();
  }

  /// Connect to the Python bridge WebSocket, trying each candidate host until
  /// one answers (handles the Linux IPv4/IPv6 "localhost" mismatch).
  void connect({String? url}) async {
    _disconnect();
    final candidates = url != null ? [url] : _wsCandidates;

    for (final cand in candidates) {
      try {
        final ch = WebSocketChannel.connect(Uri.parse(cand));
        await ch.ready; // throws if nothing is listening on this host

        _channel = ch;
        _wsUrl = cand;
        _isConnected = true;
        _addLog('Connected to $cand');
        // Re-assert the chosen save folder for this bridge session.
        if (_pendingDownloadDir != null) {
          _send({'cmd': 'set_download_dir', 'path': _pendingDownloadDir});
        }
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
        return; // connected — stop trying candidates
      } catch (_) {
        // Try the next candidate host.
      }
    }

    // No candidate answered.
    _isConnected = false;
    if (!BridgeLauncher.running) {
      _addLog('Bridge not reachable — starting it…');
      await BridgeLauncher.start(_addLog);
    }
    notifyListeners();
    _scheduleReconnect();
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
          final photoName = _decodePhotoName(data['data']);
          if (photoName != null) {
            // TAKE_PIC succeeded — surface the saved filename and refresh list.
            lastCapturedFile = photoName;
            _addLog('PHOTO: saved $photoName');
            _flash('Photo saved: $photoName', success: true);
            Future.delayed(const Duration(milliseconds: 800), sendListImage);
          } else if (_pingPending && _pingSentAt != null) {
            // If a ping is outstanding, this ACK is its pong — record RTT.
            pingRttMs = DateTime.now().difference(_pingSentAt!).inMilliseconds;
            _pingPending = false;
            _flash('Pong · ${pingRttMs}ms round-trip', success: true);
          } else {
            _flash('Satellite acknowledged ✓', success: true);
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
          _flash('Health scan: $online/${deviceHealth.length} online',
              success: true);
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
          _flash('GPS position received', success: true);
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
          _flash('EPS telemetry received', success: true);
          // PC-history mode: persist this live snapshot to the CSV.
          if (persistLiveEps && lastEps != null) {
            appendEpsHistory([_epsToRecord(lastEps!)]).then((p) {
              if (p != null) {
                epsHistoryFile = p;
                notifyListeners();
              }
            });
          }
          break;

        case 'eps_log':
          final records = (data['data'] as List?) ?? [];
          epsLogXfer.markDone();
          for (final r in records) {
            final e = EpsData.fromJson(r as Map<String, dynamic>);
            epsHistory.add(e);
            lastEps = e;
          }
          if (epsHistory.length > epsHistoryCap) {
            epsHistory.removeRange(0, epsHistory.length - epsHistoryCap);
          }
          if (records.isNotEmpty) {
            lastEpsTime = DateTime.now();
            epsPacketCount++;
          }
          _addLog('EPS log: ${records.length} records pulled');
          _flash('EPS log: ${records.length} records', success: true);
          appendEpsHistory(records).then((p) {
            if (p != null) {
              epsHistoryFile = p;
              notifyListeners();
            }
          });
          break;

        case 'eps_log_progress':
          epsLogXfer.applyProgress(data['data'] as Map<String, dynamic>);
          break;

        case 'eps_log_failed':
          epsLogXfer.markFailed();
          _addLog('EPS log failed: ${data['data']}');
          _flash('EPS log pull failed — try again', error: true);
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
          _flash('Images: ${imageList.length} file(s)', success: true);
          break;

        case 'download_started':
          isDownloading = true;
          downloadPaused = false;
          downloadCompleteFile = null;
          downloadProgress = DownloadProgress(
            filename: data['data']['filename'] ?? '',
          );
          _addLog('Download started: ${data['data']['filename']}');
          _armDownloadWatchdog();
          break;

        case 'download_paused':
          downloadPaused = true;
          _downloadTimeout?.cancel(); // don't time out while paused
          _addLog('Download paused');
          break;

        case 'download_resumed':
          downloadPaused = false;
          _addLog('Download resumed');
          _armDownloadWatchdog();
          break;

        case 'download_progress':
          downloadProgress = DownloadProgress.fromJson(data['data']);
          _armDownloadWatchdog();
          break;

        case 'download_complete':
          isDownloading = false;
          downloadPaused = false;
          _downloadTimeout?.cancel();
          downloadCompleteFile = data['data']['path'];
          final size = data['data']['size'] ?? 0;
          final elapsed = data['data']['elapsed'] ?? 0;
          _addLog('Download complete: $downloadCompleteFile '
              '(${size}B in ${elapsed}s)');
          _flash('Download complete', success: true);
          break;

        case 'download_failed':
          isDownloading = false;
          downloadPaused = false;
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

  void sendTakePic({int resolution = 0}) {
    _send({'cmd': 'take_pic', 'resolution': resolution});
    _addLog('>> TAKE_PIC (res $resolution)');
  }

  DateTime? lastTimeSync;

  /// Set the satellite's software clock to this PC's current time.
  void syncTime() {
    _send({'cmd': 'sync_time'});
    _addLog('>> SYNC_TIME');
    lastTimeSync = DateTime.now();
    notifyListeners();
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
  Future<void> capturePhoto({bool autoPower = false, int resolution = 0}) async {
    if (autoPower && !cameraPwr) {
      toggleCameraPower();
      _flash('Powering camera…');
      // Cover the firmware's PD4 boot delay (~2 s) plus a little slack.
      await Future.delayed(const Duration(milliseconds: 2600));
    }
    sendTakePic(resolution: resolution);
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

  /// Configure on-satellite EPS logging (enable + interval seconds).
  void sendEpsLogConfig(bool enable, int interval) {
    _send({'cmd': 'eps_log_config', 'enable': enable, 'interval': interval});
    _addLog('>> EPS_LOG_CFG ${enable ? "on ${interval}s" : "off"}');
  }

  /// Pull the whole saved EPS log from the satellite (then it self-clears).
  void getEpsLog() {
    _send({'cmd': 'get_eps_log'});
    _addLog('>> GET_EPS_LOG');
    epsLogXfer.begin();
    notifyListeners();
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

  void pauseDownload() {
    _send({'cmd': 'pause_download'});
    _addLog('>> PAUSE DOWNLOAD');
  }

  void resumeDownload() {
    _send({'cmd': 'resume_download'});
    _addLog('>> RESUME DOWNLOAD');
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
