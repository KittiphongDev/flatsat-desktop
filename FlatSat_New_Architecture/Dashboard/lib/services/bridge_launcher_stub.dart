// Web build stub: the browser can't spawn processes, so the bridge must be
// started manually (or by the launcher script) when running the web target.
class BridgeLauncher {
  static bool get running => false;
  static Future<bool> start(void Function(String) log) async {
    log('Web build cannot start the bridge — run gs_bridge.py manually');
    return false;
  }

  static void stop() {}
}
