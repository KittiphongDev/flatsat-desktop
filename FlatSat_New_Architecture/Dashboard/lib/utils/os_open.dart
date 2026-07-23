import 'dart:io';

/// Reveal a file (or open a folder) in the OS file manager. Desktop-only;
/// safely does nothing on unsupported platforms.
Future<void> revealInFileManager(String path) async {
  try {
    if (Platform.isWindows) {
      // Select the file inside Explorer (or open the folder if it's a dir).
      if (await FileSystemEntity.isDirectory(path)) {
        await Process.run('explorer', [path]);
      } else {
        await Process.run('explorer', ['/select,', path]);
      }
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isLinux) {
      final dir =
          await FileSystemEntity.isDirectory(path) ? path : File(path).parent.path;
      await Process.run('xdg-open', [dir]);
    }
  } catch (_) {
    // Best-effort; ignore if the file manager can't be launched.
  }
}
