import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'platform.dart';
import 'services/websocket_service.dart';
import 'services/settings_service.dart';
import 'screens/dashboard_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hide the OS title bar and let the app's own header act as it, the way
  // Claude Desktop / VS Code do. TitleBarStyle.hidden removes the caption but
  // keeps a real window frame, so resizing, snapping and drop shadows all
  // still work. Guarded because window_manager is desktop-only.
  if (isDesktopPlatform) {
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1400, 900),
      minimumSize: Size(880, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      title: 'FlatSat Mission Control',
      titleBarStyle: TitleBarStyle.hidden,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Load persisted settings before the first frame so the UI starts in the
  // right camera mode instead of flickering from the default.
  final settings = SettingsService();
  await settings.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WebSocketService()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider.value(value: settings),
      ],
      child: const FlatSatApp(),
    ),
  );
}

class FlatSatApp extends StatelessWidget {
  const FlatSatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    return MaterialApp(
      title: 'FlatSat Mission Control',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeProvider.mode,
      home: const DashboardScreen(),
    );
  }
}
