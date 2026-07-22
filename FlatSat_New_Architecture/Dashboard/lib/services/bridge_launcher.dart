// Desktop implementation: starts/stops the Python bridge as a child process.
// Only compiled on platforms with dart:io (Windows/Linux/macOS); the web build
// uses bridge_launcher_stub.dart instead (see the conditional import in
// websocket_service.dart), so dart:io never breaks the web target.
import 'dart:convert';
import 'dart:io';

class BridgeLauncher {
  static Process? _process;
  static DateTime? _lastAttempt;

  static bool get running => _process != null;

  /// Start the bridge if it isn't already running. Returns true if a process
  /// is running when we return. Throttled so reconnect loops can call this
  /// freely without spawning storms. A duplicate bridge is harmless anyway:
  /// it exits immediately because port 8080 is already bound.
  static Future<bool> start(void Function(String) log) async {
    if (_process != null) return true;
    final now = DateTime.now();
    if (_lastAttempt != null && now.difference(_lastAttempt!).inSeconds < 5) {
      return false;
    }
    _lastAttempt = now;

    final script = _findScript();
    if (script == null) {
      log('Bridge script not found — expected PC_Bridge/gs_bridge.py '
          'near the app folder');
      return false;
    }

    final candidates =
        Platform.isWindows ? ['python', 'py', 'python3'] : ['python3', 'python'];
    for (final py in candidates) {
      try {
        // First-run convenience: make sure pyserial + websockets are present.
        await _ensureDeps(py, log);
        final p = await Process.start(
          py,
          [script],
          workingDirectory: File(script).parent.path,
        );
        _process = p;
        log('Bridge started ($py)');
        // Surface bridge output in the event log; also keeps pipes drained.
        p.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((_) {});
        p.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
          if (line.contains('Error') || line.contains('Traceback')) {
            log('bridge: $line');
          }
        });
        p.exitCode.then((code) {
          _process = null;
          // Normal when another bridge already owns port 8080.
          log('Bridge process exited (code $code)');
        });
        return true;
      } catch (_) {
        // This python binary doesn't exist — try the next one.
      }
    }
    log('Could not start the bridge — is Python installed and on PATH?');
    return false;
  }

  static void stop() {
    _process?.kill();
    _process = null;
  }

  static bool _depsChecked = false;

  /// Install the bridge's Python dependencies if they're missing.
  /// Checked once per app run; a quick import test avoids running pip when
  /// everything is already installed.
  static Future<void> _ensureDeps(String py, void Function(String) log) async {
    if (_depsChecked) return;
    final probe =
        await Process.run(py, ['-c', 'import serial, websockets']);
    if (probe.exitCode == 0) {
      _depsChecked = true;
      return;
    }
    log('Installing Python packages (pyserial, websockets)…');
    var r = await Process.run(
        py, ['-m', 'pip', 'install', '--user', 'pyserial', 'websockets']);
    if (r.exitCode != 0) {
      // Debian/Raspberry Pi OS (PEP 668) refuses without this flag.
      r = await Process.run(py, [
        '-m', 'pip', 'install', '--user', '--break-system-packages',
        'pyserial', 'websockets'
      ]);
    }
    if (r.exitCode == 0) {
      log('Python packages installed');
    } else {
      final err = (r.stderr ?? '').toString().trim();
      log('pip install failed: '
          '${err.isEmpty ? 'unknown error' : err.split('\n').last}');
    }
    _depsChecked = true; // don't retry every reconnect cycle
  }

  /// Locate PC_Bridge/gs_bridge.py by walking up from both the executable's
  /// folder (installed/built app) and the current working directory
  /// (`flutter run` from Dashboard/).
  static String? _findScript() {
    final roots = <Directory>[
      File(Platform.resolvedExecutable).parent,
      Directory.current,
    ];
    for (var dir in roots) {
      for (var i = 0; i < 6; i++) {
        final cand = File(
            '${dir.path}${Platform.pathSeparator}PC_Bridge${Platform.pathSeparator}gs_bridge.py');
        if (cand.existsSync()) return cand.path;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return null;
  }
}
