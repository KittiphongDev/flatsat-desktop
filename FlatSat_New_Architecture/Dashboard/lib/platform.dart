import 'package:flutter/foundation.dart';

/// Platform helpers for the custom (frameless) window chrome.
///
/// These deliberately use [defaultTargetPlatform] rather than `dart:io`
/// so this file still compiles for web builds, where `dart:io` is unavailable.

/// window_manager only supports the three desktop platforms.
bool get isDesktopPlatform {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;
}

bool get isMacOSPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Windows and Linux lose their window buttons when the title bar is hidden,
/// so we draw our own. macOS keeps its native traffic lights floating over the
/// content, so drawing buttons there would duplicate them.
bool get usesCustomWindowButtons => isDesktopPlatform && !isMacOSPlatform;

/// Left inset for the header brand. On macOS the native traffic lights sit at
/// the top-left, so the brand has to start clear of them.
double get headerLeadingInset => isMacOSPlatform ? 78 : 28;
