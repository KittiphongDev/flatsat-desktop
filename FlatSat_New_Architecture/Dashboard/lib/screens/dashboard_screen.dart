import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/websocket_service.dart';
import '../widgets/telemetry_card.dart';
import '../widgets/connection_banner.dart';
import '../widgets/eps_dashboard.dart';
import '../theme/app_theme.dart';

/// Breakpoint above which the dashboard uses a multi-column desktop layout.
const double kWideBreakpoint = 1100;
const double kMaxContentWidth = 1500;

/// Main dashboard screen — responsive mission control interface.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      body: Stack(
        children: [
          _buildScroll(context, c),
          const _CommandFeedback(),
        ],
      ),
    );
  }

  Widget _buildScroll(BuildContext context, AppColors c) {
    return Consumer<WebSocketService>(
        builder: (context, ws, _) {
          return CustomScrollView(
            slivers: [
              // ---- App Bar ----
              SliverAppBar(
                pinned: true,
                expandedHeight: 70,
                backgroundColor: c.header,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                foregroundColor: c.onHeader,
                title: _AppBarTitle(ws: ws),
              ),

              // ---- Body ----
              SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: kMaxContentWidth),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const ConnectionBanner(),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final isWide =
                                  constraints.maxWidth >= kWideBreakpoint;
                              return isWide
                                  ? _wideLayout(context, ws)
                                  : _narrowLayout(context, ws);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
  }

  // ============================================================
  // Layouts
  // ============================================================

  // ---- Per-panel command actions ----
  Widget _pingAction(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    return _cmdRow([
      if (ws.pingRttMs != null)
        Text('${ws.pingRttMs}ms',
            style: TextStyle(
                color: c.success,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace')),
      _cmdBtn(context, Icons.wifi_tethering, 'PING', ws.sendPing),
      _cmdBtn(context, Icons.cell_tower, 'BEACON', ws.sendBeacon,
          color: c.warning),
    ]);
  }

  Widget _gpsAction(BuildContext context, WebSocketService ws) =>
      _cmdBtn(context, Icons.gps_fixed, 'GET GPS', ws.sendGetGps,
          color: context.colors.success);

  Widget _epsAction(BuildContext context, WebSocketService ws) =>
      _cmdBtn(context, Icons.bolt, 'GET EPS', ws.sendGetEps);

  Widget _healthAction(BuildContext context, WebSocketService ws) =>
      _cmdBtn(context, Icons.radar, 'SCAN', ws.sendStatus,
          color: context.colors.info);

  Widget _imageAction(BuildContext context, WebSocketService ws) => _cmdRow([
        _cmdBtn(context, Icons.camera, 'TAKE PIC', ws.sendTakePic,
            color: context.colors.secondary),
        _cmdBtn(context, Icons.photo_library, 'LIST', ws.sendListImage),
      ]);

  /// Single-column layout for phones / narrow windows.
  Widget _narrowLayout(BuildContext context, WebSocketService ws) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(context, 'TELEMETRY', _telemetryGrid(context, ws),
            action: _pingAction(context, ws)),
        _section(context, 'SUBSYSTEM POWER', _subsystemPower(context, ws)),
        _section(context, 'DEVICE HEALTH', _healthPanel(context, ws),
            action: _healthAction(context, ws)),
        _section(context, 'IMAGE MANAGER', _imageManager(context, ws),
            action: _imageAction(context, ws)),
        _section(context, 'GPS DATA', _gpsCard(context, ws),
            action: _gpsAction(context, ws)),
        _section(context, 'EPS SUBSYSTEM', const EpsDashboard(),
            action: _epsAction(context, ws)),
        if (ws.isDownloading && ws.downloadProgress != null)
          _section(context, 'DOWNLOAD PROGRESS', _downloadCard(context, ws)),
        _section(context, 'EVENT LOG', _eventLog(context, ws)),
        const SizedBox(height: 20),
      ],
    );
  }

  /// Two-column masonry layout for desktop / web.
  Widget _wideLayout(BuildContext context, WebSocketService ws) {
    final primary = <Widget>[
      _section(context, 'TELEMETRY', _telemetryGrid(context, ws),
          action: _pingAction(context, ws)),
      _section(context, 'EPS SUBSYSTEM', const EpsDashboard(),
          action: _epsAction(context, ws)),
      _section(context, 'IMAGE MANAGER', _imageManager(context, ws),
          action: _imageAction(context, ws)),
      _section(context, 'EVENT LOG', _eventLog(context, ws)),
    ];

    final side = <Widget>[
      _section(context, 'SUBSYSTEM POWER', _subsystemPower(context, ws)),
      _section(context, 'DEVICE HEALTH', _healthPanel(context, ws),
          action: _healthAction(context, ws)),
      _section(context, 'GPS DATA', _gpsCard(context, ws),
          action: _gpsAction(context, ws)),
      if (ws.isDownloading && ws.downloadProgress != null)
        _section(context, 'DOWNLOAD PROGRESS', _downloadCard(context, ws)),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: primary,
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: side,
          ),
        ),
      ],
    );
  }

  /// Wraps a titled section with consistent spacing and an optional action
  /// (e.g. the command button that drives this panel).
  Widget _section(BuildContext context, String title, Widget child,
      {Widget? action}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _sectionTitle(context, title)),
              if (action != null) action,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  /// Compact command button used in panel headers.
  Widget _cmdBtn(BuildContext context, IconData icon, String label,
      VoidCallback onTap,
      {Color? color}) {
    final c = context.colors;
    final col = color ?? c.accent;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: col.withOpacity(0.5)),
            color: col.withOpacity(0.08),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: col),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: col,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Row of small command buttons (for headers that need more than one).
  Widget _cmdRow(List<Widget> buttons) {
    final children = <Widget>[];
    for (var i = 0; i < buttons.length; i++) {
      if (i > 0) children.add(const SizedBox(width: 6));
      children.add(buttons[i]);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  // ---- Section Title ----
  Widget _sectionTitle(BuildContext context, String title) {
    final c = context.colors;
    return Row(
      children: [
        Container(
          width: 3,
          height: 16,
          decoration: BoxDecoration(
            color: c.accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: TextStyle(
            color: c.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }

  // ---- Telemetry Grid ----
  Widget _telemetryGrid(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 640 ? 4 : 2;
        return GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            // Fixed row height (in px) so cards never overflow regardless of
            // how wide each column gets on desktop.
            mainAxisExtent: 148,
          ),
          children: [
            TelemetryCard(
              icon: Icons.battery_charging_full,
              title: 'BATTERY',
              value: '${ws.telemetry.batteryPct}%',
              accentColor:
                  ws.telemetry.batteryPct > 20 ? c.success : c.error,
              subtitle: '${ws.telemetry.voltage}V',
            ),
            TelemetryCard(
              icon: Icons.thermostat,
              title: 'TEMPERATURE',
              value: '${ws.telemetry.temperature}°C',
              accentColor: c.warning,
              subtitle: 'OBC Board',
            ),
            TelemetryCard(
              icon: Icons.signal_cellular_alt,
              title: 'SIGNAL RSSI',
              value: '${ws.telemetry.rssi.toStringAsFixed(1)} dBm',
              accentColor: c.secondary,
              subtitle: 'SNR: ${ws.telemetry.snr.toStringAsFixed(1)} dB',
            ),
            TelemetryCard(
              icon: Icons.link,
              title: 'LINK STATUS',
              value: ws.telemetry.linkStatus,
              accentColor:
                  ws.telemetry.isLinkActive ? c.success : c.error,
              subtitle: ws.telemetry.errorString,
              trailing: StatusIndicator(
                isActive: ws.telemetry.isLinkActive,
                label: '',
              ),
            ),
          ],
        );
      },
    );
  }

  // ---- Subsystem Power ----
  // Maps to the three controllable ADM1177 EPS outputs (PD1/PD2/PD3).
  Widget _subsystemPower(BuildContext context, WebSocketService ws) {
    return Column(
      children: [
        SubsystemCard(
          name: 'Communication',
          icon: Icons.cell_tower,
          isOn: ws.telemetry.payloadPwr, // channel 0 = COMMS (PD1)
          locked: true, // never switch COMMS off from the ground — cuts the link
          onToggle: () {},
        ),
        const SizedBox(height: 8),
        SubsystemCard(
          name: 'Payload 1 / GPS',
          icon: Icons.gps_fixed,
          isOn: ws.telemetry.gpsPwr, // channel 1 = Payload 1 / GPS (PD2)
          onToggle: () => ws.sendTogglePwr(1),
        ),
        const SizedBox(height: 8),
        SubsystemCard(
          name: 'Payload 2 / PC104',
          icon: Icons.developer_board,
          isOn: ws.telemetry.camPwr, // channel 2 = Payload 2 / PC104 (PD3)
          onToggle: () => ws.sendTogglePwr(2),
        ),
      ],
    );
  }


  // ---- Command Grid ----
  // ---- Image Manager ----
  Widget _imageManager(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    if (ws.imageList.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Center(
          child: Text(
            'No images. Press LIST IMAGES to scan the SD card.',
            style: TextStyle(color: c.textMuted, fontSize: 13),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: ws.imageList.map((img) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                Icon(Icons.image, color: c.secondary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        img.name,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        img.sizeFormatted,
                        style: TextStyle(color: c.textMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.download, color: c.accent, size: 20),
                  tooltip: 'Download',
                  onPressed: () => ws.sendDownload(img.name),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, color: c.error, size: 20),
                  tooltip: 'Delete',
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: c.surface,
                        title: const Text('Delete Image'),
                        content: Text('Delete ${img.name} from SD card?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () {
                              ws.sendRemoveImage(img.name);
                              Navigator.pop(ctx);
                              Future.delayed(
                                const Duration(milliseconds: 500),
                                ws.sendListImage,
                              );
                            },
                            child: Text(
                              'Delete',
                              style: TextStyle(color: c.error),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ---- Device Health Panel ----
  Widget _healthPanel(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    if (ws.deviceHealth.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(Icons.radar, color: c.textMuted, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Press SCAN to check every EPS device on the I2C bus.',
                style: TextStyle(color: c.textMuted, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }
    final online = ws.deviceHealth.where((d) => d.online).length;
    final allOk = online == ws.deviceHealth.length;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                Text(
                  '$online / ${ws.deviceHealth.length} ONLINE',
                  style: TextStyle(
                    color: allOk ? c.success : c.warning,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          Divider(color: c.border, height: 1),
          ...ws.deviceHealth.map((d) {
            final dot = d.online ? c.success : c.error;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dot,
                      boxShadow: [
                        BoxShadow(color: dot.withOpacity(0.5), blurRadius: 5),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      d.label,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Text(
                    d.addr,
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    d.online ? 'ONLINE' : 'OFFLINE',
                    style: TextStyle(
                      color: dot,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ---- GPS Card ----
  Widget _gpsCard(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    final gps = ws.lastGps;
    if (gps == null) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(Icons.location_searching, color: c.textMuted, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'No GPS fix yet. Press GET GPS to request a position.',
                style: TextStyle(color: c.textMuted, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }
    // GPS replied but has no fix yet — link is fine, just no signal.
    if (gps.noSignal) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.warning.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.warning.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.gps_off, color: c.warning, size: 28),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'NO SIGNAL',
                    style: TextStyle(
                      color: c.warning,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'GPS replied over the link, but has no fix yet '
                    '(${gps.satellites} satellites). Make sure the GPS is '
                    'powered with a clear sky view.',
                    style: TextStyle(color: c.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.success.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.success.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.gps_fixed, color: c.success, size: 28),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${gps.latitude.toStringAsFixed(6)}°N, '
                  '${gps.longitude.toStringAsFixed(6)}°E',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Alt: ${gps.altitude.toStringAsFixed(1)}m  •  '
                  'Satellites: ${gps.satellites}',
                  style: TextStyle(color: c.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Download Progress ----
  Widget _downloadCard(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    final dl = ws.downloadProgress!;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.accent.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.downloading, color: c.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Downloading: ${dl.filename}',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: null,
              backgroundColor: c.border,
              valueColor: AlwaysStoppedAnimation(c.accent),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Chunk #${dl.chunk}  •  ${dl.bytesReceived} bytes received',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ---- Event Log ----
  Widget _eventLog(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    // Terminal keeps a dark surface in both themes for readability;
    // derive muted text tints from white for consistent contrast.
    const onDarkMuted = Color(0x4DFFFFFF);
    const onDarkFaint = Color(0x33FFFFFF);
    return Container(
      height: 250,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.terminal, color: onDarkMuted, size: 16),
                const SizedBox(width: 8),
                const Text(
                  'Terminal',
                  style: TextStyle(
                    color: onDarkMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: ws.clearLog,
                  child: const Text(
                    'CLEAR',
                    style: TextStyle(
                      color: onDarkFaint,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: onDarkFaint, height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: ws.eventLog.length,
              itemBuilder: (context, index) {
                final line = ws.eventLog[index];
                Color lineColor = const Color(0x99FFFFFF);
                if (line.contains('ERROR') || line.contains('NACK')) {
                  lineColor = c.error;
                } else if (line.contains('>>')) {
                  lineColor = c.accent;
                } else if (line.contains('ACK') || line.contains('complete')) {
                  lineColor = c.success;
                } else if (line.contains('WARNING')) {
                  lineColor = c.warning;
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: SelectableText(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: lineColor,
                      height: 1.5,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// App bar title with brand, live status indicators, and theme toggle.
class _AppBarTitle extends StatelessWidget {
  final WebSocketService ws;
  const _AppBarTitle({required this.ws});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final themeProvider = context.watch<ThemeProvider>();
    final isNarrow = MediaQuery.of(context).size.width < 640;

    return Row(
      children: [
        Image.network(
          'https://flatsat.kidorbit.space/assets/nb_logo_w.png',
          height: 30,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: c.accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.satellite_alt, color: c.accent, size: 22),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'FlatSat Mission Control',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.onHeader,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                'GROUND STATION DASHBOARD',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: c.accent,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        if (!isNarrow) ...[
          StatusIndicator(
            isActive: ws.isConnected,
            label: ws.isConnected ? 'BRIDGE' : 'OFFLINE',
          ),
          const SizedBox(width: 16),
          StatusIndicator(
            isActive: ws.telemetry.isLinkActive,
            label: ws.telemetry.isLinkActive ? 'SAT LINK' : 'NO LINK',
          ),
          const SizedBox(width: 8),
        ],
        IconButton(
          tooltip: themeProvider.isDark
              ? 'Switch to light theme'
              : 'Switch to dark theme',
          icon: Icon(
            themeProvider.isDark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined,
            color: c.onHeader.withOpacity(0.8),
            size: 20,
          ),
          onPressed: () => context.read<ThemeProvider>().toggle(),
        ),
      ],
    );
  }
}

/// Invisible listener that turns the service's command-feedback signal into
/// floating SnackBar toasts, so every command visibly confirms.
class _CommandFeedback extends StatefulWidget {
  const _CommandFeedback();

  @override
  State<_CommandFeedback> createState() => _CommandFeedbackState();
}

class _CommandFeedbackState extends State<_CommandFeedback> {
  int _lastSeq = 0;

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WebSocketService>();
    if (ws.feedbackSeq != _lastSeq) {
      _lastSeq = ws.feedbackSeq;
      final msg = ws.feedbackMessage;
      final isErr = ws.feedbackIsError;
      final c = context.colors;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            content: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isErr ? Icons.error_outline : Icons.check_circle_outline,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Flexible(child: Text(msg)),
              ],
            ),
            duration: const Duration(milliseconds: 1500),
            behavior: SnackBarBehavior.floating,
            width: 320,
            backgroundColor: isErr ? c.error : c.accent,
          ),
        );
      });
    }
    return const SizedBox.shrink();
  }
}
