import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/websocket_service.dart';
import '../widgets/telemetry_card.dart';
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
      body: Consumer<WebSocketService>(
        builder: (context, ws, _) {
          return CustomScrollView(
            slivers: [
              // ---- App Bar ----
              SliverAppBar(
                pinned: true,
                expandedHeight: 70,
                backgroundColor: c.scaffold,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0.5,
                foregroundColor: c.textPrimary,
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
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final isWide =
                              constraints.maxWidth >= kWideBreakpoint;
                          return isWide
                              ? _wideLayout(context, ws)
                              : _narrowLayout(context, ws);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ============================================================
  // Layouts
  // ============================================================

  /// Single-column layout for phones / narrow windows.
  Widget _narrowLayout(BuildContext context, WebSocketService ws) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(context, 'TELEMETRY', _telemetryGrid(context, ws)),
        _section(context, 'SUBSYSTEM POWER', _subsystemPower(context, ws)),
        _section(context, 'COMMAND CONSOLE', _commandGrid(context, ws)),
        _section(context, 'IMAGE MANAGER', _imageManager(context, ws)),
        if (ws.lastGps != null)
          _section(context, 'GPS DATA', _gpsCard(context, ws)),
        if (ws.lastEps != null)
          _section(context, 'EPS SUBSYSTEM', _epsCard(context, ws)),
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
      _section(context, 'TELEMETRY', _telemetryGrid(context, ws)),
      _section(context, 'COMMAND CONSOLE', _commandGrid(context, ws)),
      _section(context, 'IMAGE MANAGER', _imageManager(context, ws)),
      _section(context, 'EVENT LOG', _eventLog(context, ws)),
    ];

    final side = <Widget>[
      _section(context, 'SUBSYSTEM POWER', _subsystemPower(context, ws)),
      if (ws.lastGps != null)
        _section(context, 'GPS DATA', _gpsCard(context, ws)),
      if (ws.lastEps != null)
        _section(context, 'EPS SUBSYSTEM', _epsCard(context, ws)),
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

  /// Wraps a titled section with consistent spacing.
  Widget _section(BuildContext context, String title, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(context, title),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
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
        return GridView.count(
          crossAxisCount: crossAxisCount,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.6,
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
  Widget _subsystemPower(BuildContext context, WebSocketService ws) {
    return Column(
      children: [
        SubsystemCard(
          name: 'Payload',
          icon: Icons.science,
          isOn: ws.telemetry.payloadPwr,
          onToggle: () => ws.sendTogglePwr(0),
        ),
        const SizedBox(height: 8),
        SubsystemCard(
          name: 'GPS Module',
          icon: Icons.gps_fixed,
          isOn: ws.telemetry.gpsPwr,
          onToggle: () => ws.sendTogglePwr(1),
        ),
        const SizedBox(height: 8),
        SubsystemCard(
          name: 'Camera',
          icon: Icons.camera_alt,
          isOn: ws.telemetry.camPwr,
          onToggle: () => ws.sendTogglePwr(2),
        ),
      ],
    );
  }

  // ---- Command Grid ----
  Widget _commandGrid(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        CommandButton(
          icon: Icons.wifi_tethering,
          label: 'PING',
          onPressed: ws.sendPing,
        ),
        CommandButton(
          icon: Icons.monitor_heart,
          label: 'STATUS',
          onPressed: ws.sendStatus,
        ),
        CommandButton(
          icon: Icons.cell_tower,
          label: 'BEACON',
          onPressed: ws.sendBeacon,
          color: c.warning,
        ),
        CommandButton(
          icon: Icons.camera,
          label: 'TAKE PIC',
          onPressed: ws.sendTakePic,
          color: c.secondary,
        ),
        CommandButton(
          icon: Icons.gps_fixed,
          label: 'GET GPS',
          onPressed: ws.sendGetGps,
          color: c.success,
        ),
        CommandButton(
          icon: Icons.bolt,
          label: 'GET EPS',
          onPressed: ws.sendGetEps,
          color: c.yellow,
        ),
        CommandButton(
          icon: Icons.photo_library,
          label: 'LIST IMAGES',
          onPressed: ws.sendListImage,
          color: c.pink,
        ),
      ],
    );
  }

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

  // ---- GPS Card ----
  Widget _gpsCard(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    final gps = ws.lastGps!;
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

  // ---- EPS Card ----
  Widget _epsCard(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    final eps = ws.lastEps!;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.yellow.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _epsGroupLabel(context, 'INA226 POWER MONITORS'),
          _epsTable(
            context,
            headers: const ['CH', 'Voltage', 'Current', 'Power'],
            rows: eps.ina226
                .map((r) => [
                      '#${r.index}',
                      '${r.voltage.toStringAsFixed(3)} V',
                      '${r.current.toStringAsFixed(3)} A',
                      '${r.power.toStringAsFixed(2)} W',
                    ])
                .toList(),
          ),
          const SizedBox(height: 16),
          _epsGroupLabel(context, 'TMP102 TEMPERATURES'),
          _epsTable(
            context,
            headers: const ['CH', 'Temperature'],
            rows: eps.tmp102
                .map((r) => [
                      '#${r.index}',
                      '${r.temperature.toStringAsFixed(2)} °C',
                    ])
                .toList(),
          ),
          const SizedBox(height: 16),
          _epsGroupLabel(context, 'ADM1177 HOT-SWAP MONITORS'),
          _epsTable(
            context,
            headers: const ['CH', 'Voltage', 'Current'],
            rows: eps.adm1177
                .map((r) => [
                      '#${r.index}',
                      '${r.voltageMv} mV',
                      '${r.currentMa} mA',
                    ])
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _epsGroupLabel(BuildContext context, String label) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: TextStyle(
          color: c.yellow,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _epsTable(
    BuildContext context, {
    required List<String> headers,
    required List<List<String>> rows,
  }) {
    final c = context.colors;
    TableRow buildRow(List<String> cells, {required bool isHeader}) {
      return TableRow(
        children: cells.map((cell) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Text(
              cell,
              style: TextStyle(
                color: isHeader ? c.textMuted : c.textPrimary,
                fontSize: isHeader ? 10 : 13,
                fontWeight: isHeader ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: isHeader ? 1 : 0,
                fontFamily: isHeader ? null : 'monospace',
              ),
            ),
          );
        }).toList(),
      );
    }

    return Table(
      columnWidths: const {0: FixedColumnWidth(48)},
      border: TableBorder(
        horizontalInside: BorderSide(color: c.border),
      ),
      children: [
        buildRow(headers, isHeader: true),
        ...rows.map((r) => buildRow(r, isHeader: false)),
      ],
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
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: c.accent.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.satellite_alt, color: c.accent, size: 22),
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
                  color: c.textPrimary,
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
            color: c.textSecondary,
            size: 20,
          ),
          onPressed: () => context.read<ThemeProvider>().toggle(),
        ),
      ],
    );
  }
}
