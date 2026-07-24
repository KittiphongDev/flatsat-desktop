import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../platform.dart';
import '../services/websocket_service.dart';
import '../services/settings_service.dart';
import '../widgets/telemetry_card.dart';
import '../widgets/connection_banner.dart';
import '../widgets/eps_dashboard.dart';
import '../widgets/settings_dialog.dart';
import '../widgets/setup_guide_dialog.dart';
import '../widgets/take_pic_dialog.dart';
import '../utils/os_open.dart';
import '../theme/app_theme.dart';

/// Breakpoint above which the dashboard uses a multi-column desktop layout.
const double kWideBreakpoint = 1100;
const double kMaxContentWidth = 1500;

/// Horizontal breathing room from the window edges. Used by both the header
/// and the body so the brand, the status cluster, and the content all align.
const double kEdgePadding = 28;

/// Header bar height — a little taller than the Material default so the
/// two-line brand block isn't cramped against the window chrome.
const double kHeaderHeight = 76;

/// OBC board temperature (°C) above which the reading is flagged as a fault.
/// Adjust to match the actual board's rating.
const double kObcTempLimitC = 60;

/// Height of the minimize/maximize/close hit area. Kept well below
/// [kHeaderHeight] so the hover highlight reads as a button, not a full-height
/// column of color.
const double kWindowButtonHeight = 40;

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
          const _FirstRunGate(),
          const _DownloadDirSync(),
          const _AutoTimeSync(),
          const _EpsLogSync(),
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
                automaticallyImplyLeading: false,
                toolbarHeight: kHeaderHeight,
                backgroundColor: c.header,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                foregroundColor: c.onHeader,
                // titleSpacing: 0 hands padding control to us, so the brand and
                // the status cluster get matching breathing room from both
                // window edges instead of sitting flush against them.
                titleSpacing: 0,
                // With the OS title bar hidden, this header IS the title bar:
                // drag it to move the window, double-click to maximize.
                title: _draggableHeader(
                  Container(
                    height: kHeaderHeight,
                    alignment: Alignment.centerLeft,
                    padding: EdgeInsets.only(left: headerLeadingInset),
                    child: const _AppBarBrand(),
                  ),
                ),
                actions: [
                  _AppBarStatus(ws: ws),
                  if (usesCustomWindowButtons) ...[
                    const SizedBox(width: 10),
                    // AppBar lays actions out with CrossAxisAlignment.stretch,
                    // so without this the caption buttons fill the full 76px
                    // header and their hover highlight becomes a tall slab.
                    const Center(
                      child: SizedBox(
                        height: kWindowButtonHeight,
                        child: _WindowButtons(),
                      ),
                    ),
                  ] else
                    const SizedBox(width: kEdgePadding),
                ],
              ),

              // ---- Body ----
              SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: kMaxContentWidth),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: kEdgePadding,
                        vertical: 20,
                      ),
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

  /// Makes the header behave like a native title bar: drag anywhere to move
  /// the window, double-click to toggle maximize. A no-op off desktop, where
  /// window_manager isn't available.
  Widget _draggableHeader(Widget child) {
    if (!isDesktopPlatform) return child;
    return GestureDetector(
      onDoubleTap: () async {
        if (await windowManager.isMaximized()) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      child: DragToMoveArea(child: child),
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
            style: monoStyle(
                color: c.success, fontSize: 11, fontWeight: FontWeight.w700)),
      _cmdBtn(context, Icons.wifi_tethering, 'PING', ws.sendPing),
      _cmdBtn(context, Icons.cell_tower, 'BEACON', ws.sendBeacon),
    ]);
  }

  Widget _gpsAction(BuildContext context, WebSocketService ws) =>
      _cmdBtn(context, Icons.gps_fixed, 'GET GPS', ws.sendGetGps);

  Widget _epsAction(BuildContext context, WebSocketService ws) {
    final mode = context.watch<SettingsService>().epsLogMode;
    // In satellite-log mode, GET EPS pulls the whole log; otherwise it's a
    // single live snapshot.
    return _cmdBtn(context, Icons.bolt, 'GET EPS', () {
      if (mode == EpsLogMode.satellite) {
        ws.getEpsLog();
      } else {
        ws.sendGetEps();
      }
    });
  }

  Widget _healthAction(BuildContext context, WebSocketService ws) =>
      _cmdBtn(context, Icons.radar, 'SCAN', ws.sendStatus);

  Widget _imageAction(BuildContext context, WebSocketService ws) => _cmdRow([
        // Opens a popup to pick the resolution (remembered), then captures —
        // the popup handles auto-power via capturePhoto().
        _cmdBtn(context, Icons.camera, 'TAKE PIC',
            () => showTakePicDialog(context)),
        _cmdBtn(context, Icons.photo_library, 'LIST', ws.sendListImage),
      ]);

  /// Single-column layout for phones / narrow windows.
  Widget _narrowLayout(BuildContext context, WebSocketService ws) {
    final settings = context.watch<SettingsService>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(context, 'TELEMETRY', _telemetryGrid(context, ws),
            action: _pingAction(context, ws)),
        _section(context, 'SUBSYSTEM POWER', _subsystemPower(context, ws)),
        _section(context, 'DEVICE HEALTH', _withXfer(context, ws.healthXfer, 'Scanning devices…', _healthPanel(context, ws)),
            action: _healthAction(context, ws)),
        _section(context, 'IMAGE MANAGER', _withXfer(context, ws.imageXfer, 'Loading image list…', _imageManager(context, ws)),
            action: _imageAction(context, ws)),
        _section(context, 'GPS DATA', _gpsCard(context, ws),
            action: _gpsAction(context, ws)),
        _section(context, 'EPS SUBSYSTEM', _withXfer(context, ws.epsLogXfer, 'Pulling EPS log…', const EpsDashboard()),
            action: _epsAction(context, ws)),
        if (ws.isDownloading && ws.downloadProgress != null)
          _section(context, 'DOWNLOAD PROGRESS', _downloadCard(context, ws)),
        if (settings.showEventLog)
          _section(context, 'EVENT LOG', _eventLog(context, ws)),
        if (settings.showBridgeLog)
          _section(context, 'BRIDGE TRAFFIC', _bridgeLog(context, ws)),
        const SizedBox(height: 20),
      ],
    );
  }

  /// Two-column masonry layout for desktop / web.
  Widget _wideLayout(BuildContext context, WebSocketService ws) {
    final settings = context.watch<SettingsService>();
    final primary = <Widget>[
      _section(context, 'TELEMETRY', _telemetryGrid(context, ws),
          action: _pingAction(context, ws)),
      _section(context, 'EPS SUBSYSTEM', const EpsDashboard(),
          action: _epsAction(context, ws)),
      _section(context, 'IMAGE MANAGER', _withXfer(context, ws.imageXfer, 'Loading image list…', _imageManager(context, ws)),
          action: _imageAction(context, ws)),
      if (settings.showEventLog)
        _section(context, 'EVENT LOG', _eventLog(context, ws)),
    ];

    final side = <Widget>[
      _section(context, 'SUBSYSTEM POWER', _subsystemPower(context, ws)),
      _section(context, 'DEVICE HEALTH', _withXfer(context, ws.healthXfer, 'Scanning devices…', _healthPanel(context, ws)),
          action: _healthAction(context, ws)),
      _section(context, 'GPS DATA', _gpsCard(context, ws),
          action: _gpsAction(context, ws)),
      if (ws.isDownloading && ws.downloadProgress != null)
        _section(context, 'DOWNLOAD PROGRESS', _downloadCard(context, ws)),
      if (settings.showBridgeLog)
        _section(context, 'BRIDGE TRAFFIC', _bridgeLog(context, ws)),
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
    return _CollapsibleSection(title: title, action: action, child: child);
  }

  /// Compact command button used in panel headers.
  ///
  /// All command buttons share the theme accent so the header row reads as one
  /// consistent control set instead of a rainbow of per-command colors.
  Widget _cmdBtn(BuildContext context, IconData icon, String label,
          VoidCallback onTap) =>
      _CmdButton(icon: icon, label: label, onTap: onTap);

  /// Row of small command buttons (for headers that need more than one).
  Widget _cmdRow(List<Widget> buttons) {
    final children = <Widget>[];
    for (var i = 0; i < buttons.length; i++) {
      if (i > 0) children.add(const SizedBox(width: 6));
      children.add(buttons[i]);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// Percentage loader shown at the top of a panel while a transfer runs.
  Widget _xferBar(BuildContext context, TransferState x, String label) {
    final c = context.colors;
    final pct = x.percent.clamp(0, 100);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.accent.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.accent.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(c.accent),
                ),
              ),
              const SizedBox(width: 10),
              Text(label,
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                x.total > 0 ? '$pct%  (${x.received}/${x.total})' : '$pct%',
                style: TextStyle(
                    color: c.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: x.total > 0 ? pct / 100.0 : null,
              minHeight: 5,
              backgroundColor: c.border,
              valueColor: AlwaysStoppedAnimation(c.accent),
            ),
          ),
        ],
      ),
    );
  }

  /// Prepend a transfer loader above a panel's content while it's collecting.
  Widget _withXfer(BuildContext context, TransferState x, String label,
      Widget child) {
    if (!x.active) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_xferBar(context, x, label), child],
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
              // Neutral while in range; only goes red when it actually needs
              // attention, instead of being permanently orange.
              accentColor:
                  ws.telemetry.temperature > kObcTempLimitC ? c.error : null,
              subtitle: 'OBC Board',
            ),
            TelemetryCard(
              icon: Icons.signal_cellular_alt,
              title: 'SIGNAL RSSI',
              value: '${ws.telemetry.rssi.toStringAsFixed(1)} dBm',
              // SNR is meaningless in FSK, so show it only if the GS reports a
              // real value (it sends an N/A sentinel otherwise).
              subtitle: ws.telemetry.snrValid
                  ? 'SNR: ${ws.telemetry.snr.toStringAsFixed(1)} dB'
                  : 'FSK · 433 MHz',
            ),
            TelemetryCard(
              icon: Icons.link,
              title: 'LINK STATUS',
              // Connection health only — one of No signal / Stable / Not stable.
              value: ws.telemetry.linkQuality,
              accentColor: !ws.telemetry.isLinkActive
                  ? c.error
                  : (ws.telemetry.isLinkStable ? c.success : c.warning),
              // Satellite subsystem faults are unrelated to the link, so only
              // surface them here when present, clearly labelled.
              subtitle: ws.telemetry.systemErrors == 0
                  ? ''
                  : 'Sat fault: ${ws.telemetry.errorString}',
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
    final commsLocked = context.watch<SettingsService>().commsLockEnabled;
    return Column(
      children: [
        SubsystemCard(
          name: 'Communication',
          icon: Icons.cell_tower,
          isOn: ws.telemetry.payloadPwr, // channel 0 = COMMS (PD1)
          locked: commsLocked, // lock is user-controllable in Settings
          onToggle: () => _toggleComms(context, ws),
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
        // Camera payload (Arducam on PD4) — only switchable in a production
        // build. Hidden in prototype, where the camera is always powered.
        if (context.watch<SettingsService>().isProduction) ...[
          const SizedBox(height: 8),
          SubsystemCard(
            name: 'Camera (Arducam)',
            icon: Icons.photo_camera,
            isOn: ws.cameraPwr,
            onToggle: ws.toggleCameraPower,
          ),
        ],
      ],
    );
  }

  /// Toggle the Communication channel. If the lock is disabled and the user is
  /// turning it OFF, confirm first (it cuts the radio link).
  void _toggleComms(BuildContext context, WebSocketService ws) {
    final turningOff = ws.telemetry.payloadPwr;
    if (!turningOff) {
      ws.sendTogglePwr(0);
      return;
    }
    final c = context.colors;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: const Text('Turn off Communication?'),
        content: const Text(
          'This powers down the radio. You will not be able to command the '
          'satellite until it is power-cycled on the board. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ws.sendTogglePwr(0);
              Navigator.pop(ctx);
            },
            child: Text('Turn off', style: TextStyle(color: c.error)),
          ),
        ],
      ),
    );
  }

  // ---- Image Manager ----
  Widget _imageManager(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    final noSd = ws.telemetry.systemErrors & 0x02 != 0; // ERR_SD bit

    final Widget list;
    if (noSd) {
      list = _noSdCard(context);
    } else if (ws.imageList.isEmpty) {
      list = Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(kRadiusCard),
          border: Border.all(color: c.border),
        ),
        child: Center(
          child: Text(
            'No images. Press LIST IMAGES to scan the SD card.',
            style: TextStyle(color: c.textMuted, fontSize: 13),
          ),
        ),
      );
    } else {
      list = _imageListCard(context, ws);
    }

    // Stack any status banners above the list.
    final banners = <Widget>[];
    if (ws.downloadCompleteFile != null) banners.add(_savedBanner(context, ws));
    if (ws.lastCapturedFile != null) banners.add(_capturedBanner(context, ws));
    if (banners.isEmpty) return list;

    final children = <Widget>[];
    for (final b in banners) {
      children..add(b)..add(const SizedBox(height: 10));
    }
    children.add(list);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  /// Clear "no SD card" state shown when the satellite reports ERR_SD.
  Widget _noSdCard(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.error.withOpacity(0.06),
        borderRadius: BorderRadius.circular(kRadiusCard),
        border: Border.all(color: c.error.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.sd_card_alert_outlined, color: c.error, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('No SD card detected',
                    style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  'Photo capture, listing and download are unavailable until '
                  'an SD card is inserted on the satellite.',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Banner announcing the filename of the most recently captured photo.
  Widget _capturedBanner(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.accent.withOpacity(0.07),
        borderRadius: BorderRadius.circular(kRadiusControl),
        border: Border.all(color: c.accent.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.photo_camera_outlined, color: c.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(color: c.textPrimary, fontSize: 12),
                children: [
                  const TextSpan(
                      text: 'Photo saved on SD:  ',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(
                    text: ws.lastCapturedFile,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: c.textMuted, size: 16),
            tooltip: 'Dismiss',
            onPressed: ws.clearCapturedFile,
          ),
        ],
      ),
    );
  }

  Widget _savedBanner(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    final path = ws.downloadCompleteFile!;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.success.withOpacity(0.08),
        borderRadius: BorderRadius.circular(kRadiusControl),
        border: Border.all(color: c.success.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, color: c.success, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Saved',
                    style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                Text(path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: c.textMuted,
                        fontSize: 10.5,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: c.success),
            icon: const Icon(Icons.folder_open, size: 15),
            label: const Text('Show in folder'),
            onPressed: () => revealInFileManager(path),
          ),
          IconButton(
            icon: Icon(Icons.close, color: c.textMuted, size: 16),
            tooltip: 'Dismiss',
            onPressed: ws.clearDownloadResult,
          ),
        ],
      ),
    );
  }

  Widget _imageListCard(BuildContext context, WebSocketService ws) {
    final c = context.colors;
    final unit = context.watch<SettingsService>().imageSizeUnit;
    final n = ws.imageList.length;
    // Cap the visible height so a long list scrolls instead of pushing the
    // rest of the dashboard off-screen.
    const rowHeight = 57.0;
    final listHeight =
        (n * rowHeight).clamp(rowHeight, 6 * rowHeight).toDouble();
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(kRadiusCard),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Count header — confirms the full list arrived.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: Row(
              children: [
                Icon(Icons.collections_outlined, size: 14, color: c.textMuted),
                const SizedBox(width: 8),
                Text(
                  '$n image${n == 1 ? '' : 's'} on SD card',
                  style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          _ImageScroll(
            height: listHeight,
            count: n,
            itemBuilder: (ctx, i) =>
                _imageRow(context, ws, ws.imageList[i], unit),
          ),
        ],
      ),
    );
  }

  Widget _imageRow(
      BuildContext context, WebSocketService ws, dynamic img, dynamic unit) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(Icons.image, color: c.textSecondary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  img.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  formatImageSize(img.size, unit),
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
                      child: Text('Delete', style: TextStyle(color: c.error)),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
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
          borderRadius: BorderRadius.circular(kRadiusCard),
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
        borderRadius: BorderRadius.circular(kRadiusCard),
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
                    style: monoStyle(color: c.textMuted, fontSize: 11),
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
    if (ws.gpsRequesting) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.accent.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation(c.accent),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                'Requesting GPS position…',
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }
    final gps = ws.lastGps;
    if (gps == null) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(kRadiusCard),
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
          borderRadius: BorderRadius.circular(kRadiusCard),
          border: Border.all(color: c.warning.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.warning.withOpacity(0.12),
                borderRadius: BorderRadius.circular(kRadiusControl),
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
        borderRadius: BorderRadius.circular(kRadiusCard),
        border: Border.all(color: c.success.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: c.success.withOpacity(0.12),
              borderRadius: BorderRadius.circular(kRadiusControl),
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
                  style: monoStyle(
                    color: c.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Alt: ${gps.altitude.toStringAsFixed(1)}m  •  '
                  'Satellites: ${gps.satellites}',
                  style: monoStyle(
                    color: c.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
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
        borderRadius: BorderRadius.circular(kRadiusCard),
        border: Border.all(color: c.accent.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(ws.downloadPaused ? Icons.pause_circle_outline : Icons.downloading,
                  color: c.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${ws.downloadPaused ? 'Paused' : 'Downloading'}: ${dl.filename}',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // Pause / resume control.
              _cmdBtn(
                context,
                ws.downloadPaused ? Icons.play_arrow : Icons.pause,
                ws.downloadPaused ? 'RESUME' : 'PAUSE',
                ws.downloadPaused ? ws.resumeDownload : ws.pauseDownload,
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              // Determinate when the size is known, else indeterminate.
              value: ws.downloadPaused
                  ? (dl.hasTotal ? dl.percent / 100.0 : 0)
                  : (dl.hasTotal ? dl.percent / 100.0 : null),
              backgroundColor: c.border,
              valueColor: AlwaysStoppedAnimation(
                  ws.downloadPaused ? c.textMuted : c.accent),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            dl.hasTotal
                ? '${dl.percent}%  •  ${_fmtBytes(dl.bytesReceived)} / ${_fmtBytes(dl.totalSize)}  •  '
                    '${_fmtBps(dl.speedBps)}  •  ETA ${_fmtEta(dl.etaSeconds)}'
                : '${_fmtBytes(dl.bytesReceived)} received  •  ${_fmtBps(dl.speedBps)}',
            style: monoStyle(
                color: c.textMuted, fontSize: 11, fontWeight: FontWeight.w400),
          ),
        ],
      ),
    );
  }

  static String _fmtBytes(int b) {
    if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '$b B';
  }

  static String _fmtBps(double bps) {
    if (bps <= 0) return '— B/s';
    if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${bps.toStringAsFixed(0)} B/s';
  }

  static String _fmtEta(int s) {
    if (s <= 0) return '—';
    if (s < 60) return '${s}s';
    return '${s ~/ 60}m ${s % 60}s';
  }

  // ---- Terminals ----
  Widget _eventLog(BuildContext context, WebSocketService ws) => _terminal(
      context,
      title: 'Terminal',
      lines: ws.eventLog,
      onClear: ws.clearLog);

  Widget _bridgeLog(BuildContext context, WebSocketService ws) => _terminal(
      context,
      title: 'Bridge serial TX/RX',
      lines: ws.bridgeLog,
      onClear: ws.clearBridgeLog);

  Widget _terminal(BuildContext context,
      {required String title,
      required List<String> lines,
      required VoidCallback onClear}) {
    final c = context.colors;
    // Terminal keeps a dark surface in both themes for readability;
    // derive muted text tints from white for consistent contrast.
    const onDarkMuted = Color(0x4DFFFFFF);
    const onDarkFaint = Color(0x33FFFFFF);
    return Container(
      height: 250,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(kRadiusCard),
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
                Text(
                  title,
                  style: const TextStyle(
                    color: onDarkMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: onClear,
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
              itemCount: lines.length,
              itemBuilder: (context, index) {
                final line = lines[index];
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
                    style: monoStyle(
                      color: lineColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
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

/// Left side of the header: logo + wordmark.
class _AppBarBrand extends StatelessWidget {
  const _AppBarBrand();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isNarrow = MediaQuery.of(context).size.width < 520;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.network(
          'https://flatsat.kidorbit.space/assets/nb_logo_w.png',
          height: 30,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: c.accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(kRadiusControl),
            ),
            child: Icon(Icons.satellite_alt, color: c.accent, size: 22),
          ),
        ),
        const SizedBox(width: 14),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                isNarrow ? 'FlatSat' : 'FlatSat Mission Control',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.onHeader,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 2),
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
      ],
    );
  }
}

/// Right side of the header: bridge + satellite link status, then the theme
/// toggle. Lives in the AppBar's `actions`, so it stays pinned to the top-right
/// corner at any window width. On narrow windows the pills collapse to just
/// their status dot (with a tooltip) rather than disappearing — the link state
/// is the one thing that should always be visible.
class _AppBarStatus extends StatelessWidget {
  final WebSocketService ws;
  const _AppBarStatus({required this.ws});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final themeProvider = context.watch<ThemeProvider>();
    final compact = MediaQuery.of(context).size.width < 760;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeaderStatus(
          isActive: ws.isConnected,
          label: ws.isConnected ? 'BRIDGE' : 'OFFLINE',
          compact: compact,
        ),
        // Wider gap now that there are no pill outlines separating them.
        const SizedBox(width: 18),
        _HeaderStatus(
          isActive: ws.telemetry.isLinkActive,
          label: ws.telemetry.isLinkActive ? 'SAT LINK' : 'NO LINK',
          compact: compact,
        ),
        const SizedBox(width: 10),
        IconButton(
          tooltip: 'Settings',
          icon: Icon(
            Icons.settings_outlined,
            color: c.onHeader.withOpacity(0.8),
            size: 20,
          ),
          onPressed: () => showSettingsDialog(context),
        ),
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

/// A status readout (dot + label) in the header's status cluster.
///
/// Deliberately borderless — the glowing dot already carries the state, so a
/// pill outline just adds visual weight next to the window controls.
class _HeaderStatus extends StatelessWidget {
  final bool isActive;
  final String label;
  final bool compact;

  const _HeaderStatus({
    required this.isActive,
    required this.label,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = isActive ? c.success : c.error;

    return Tooltip(
      message: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Minimize / maximize / close buttons for the frameless window.
///
/// Only used on Windows and Linux — macOS keeps its native traffic lights
/// floating over the content even with the title bar hidden, so drawing these
/// there would duplicate them.
class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted && maximized != _isMaximized) {
      setState(() => _isMaximized = maximized);
    }
  }

  @override
  void onWindowMaximize() => _syncMaximized();

  @override
  void onWindowUnmaximize() => _syncMaximized();

  @override
  Widget build(BuildContext context) {
    // The header bar is black in both light and dark themes, so the caption
    // glyphs always want the light-on-dark variant.
    const brightness = Brightness.dark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        WindowCaptionButton.minimize(
          brightness: brightness,
          onPressed: () => windowManager.minimize(),
        ),
        if (_isMaximized)
          WindowCaptionButton.unmaximize(
            brightness: brightness,
            onPressed: () => windowManager.unmaximize(),
          )
        else
          WindowCaptionButton.maximize(
            brightness: brightness,
            onPressed: () => windowManager.maximize(),
          ),
        WindowCaptionButton.close(
          brightness: brightness,
          onPressed: () => windowManager.close(),
        ),
      ],
    );
  }
}

/// Fixed-height, scrollable image list with a draggable scrollbar. Owns its
/// own ScrollController so the Scrollbar and ListView share it — required for
/// click-and-drag on the thumb (not just mouse-wheel).
class _ImageScroll extends StatefulWidget {
  final double height;
  final int count;
  final IndexedWidgetBuilder itemBuilder;

  const _ImageScroll(
      {required this.height, required this.count, required this.itemBuilder});

  @override
  State<_ImageScroll> createState() => _ImageScrollState();
}

class _ImageScrollState extends State<_ImageScroll> {
  final ScrollController _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Scrollbar(
        controller: _ctrl,
        thumbVisibility: true,
        interactive: true,
        child: ListView.builder(
          controller: _ctrl,
          padding: EdgeInsets.zero,
          itemCount: widget.count,
          itemBuilder: widget.itemBuilder,
        ),
      ),
    );
  }
}

/// A dashboard section with a tappable header that collapses/expands its body.
/// Collapsed state is keyed by title and kept in a static map so it survives
/// widget rebuilds and layout (mobile/desktop) switches within a session.
class _CollapsibleSection extends StatefulWidget {
  final String title;
  final Widget child;
  final Widget? action;

  const _CollapsibleSection(
      {required this.title, required this.child, this.action});

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  static final Map<String, bool> _collapsed = {};

  bool get _isCollapsed => _collapsed[widget.title] ?? false;

  void _toggle() =>
      setState(() => _collapsed[widget.title] = !_isCollapsed);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: _toggle,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: _isCollapsed ? -0.25 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(Icons.keyboard_arrow_down,
                              size: 18, color: c.textSecondary),
                        ),
                        const SizedBox(width: 4),
                        Container(
                          width: 3,
                          height: 16,
                          decoration: BoxDecoration(
                            color: c.accent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            widget.title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.action != null && !_isCollapsed) widget.action!,
            ],
          ),
          AnimatedCrossFade(
            firstChild: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: widget.child,
            ),
            secondChild: const SizedBox(width: double.infinity),
            crossFadeState: _isCollapsed
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 150),
          ),
        ],
      ),
    );
  }
}

/// Compact panel-header command button. Uses the theme accent for every
/// command, with a subtle hover fill so the whole set feels like one control
/// family.
class _CmdButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _CmdButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_CmdButton> createState() => _CmdButtonState();
}

class _CmdButtonState extends State<_CmdButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: c.accent.withOpacity(_hover ? 0.75 : 0.45),
              ),
              color: c.accent.withOpacity(_hover ? 0.16 : 0.08),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 13, color: c.accent),
                const SizedBox(width: 5),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: c.accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
      final isSuccess = ws.feedbackIsSuccess;
      final c = context.colors;
      // Green = confirmed success, red = error, neutral grey = informational
      // ("… sent"), so a glance at the colour tells you the outcome.
      final Color bg = isErr
          ? c.error
          : isSuccess
              ? c.success
              : c.textSecondary;
      final IconData icon = isErr
          ? Icons.error_outline
          : isSuccess
              ? Icons.check_circle_outline
              : Icons.info_outline;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            content: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 10),
                Flexible(child: Text(msg)),
              ],
            ),
            duration: const Duration(milliseconds: 1500),
            behavior: SnackBarBehavior.floating,
            width: 320,
            backgroundColor: bg,
          ),
        );
      });
    }
    return const SizedBox.shrink();
  }
}

/// Shows the setup guide once on the very first launch.
class _FirstRunGate extends StatefulWidget {
  const _FirstRunGate();

  @override
  State<_FirstRunGate> createState() => _FirstRunGateState();
}

class _FirstRunGateState extends State<_FirstRunGate> {
  bool _triggered = false;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    if (settings.loaded && !settings.firstRunDone && !_triggered) {
      _triggered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showSetupGuide(context, firstRun: true);
      });
    }
    return const SizedBox.shrink();
  }
}

/// Pushes the chosen image save folder to the bridge whenever it changes.
class _DownloadDirSync extends StatefulWidget {
  const _DownloadDirSync();

  @override
  State<_DownloadDirSync> createState() => _DownloadDirSyncState();
}

class _DownloadDirSyncState extends State<_DownloadDirSync> {
  String? _last;

  @override
  Widget build(BuildContext context) {
    final dir = context.watch<SettingsService>().downloadDir;
    if (dir != null && dir.isNotEmpty && dir != _last) {
      _last = dir;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<WebSocketService>().setDownloadDir(dir);
      });
    }
    return const SizedBox.shrink();
  }
}

/// Auto-syncs the satellite clock once each time the link connects (if enabled).
class _AutoTimeSync extends StatefulWidget {
  const _AutoTimeSync();

  @override
  State<_AutoTimeSync> createState() => _AutoTimeSyncState();
}

class _AutoTimeSyncState extends State<_AutoTimeSync> {
  bool _wasConnected = false;

  @override
  Widget build(BuildContext context) {
    final connected = context.watch<WebSocketService>().isConnected;
    final autoSync = context.watch<SettingsService>().timeAutoSync;
    if (connected && !_wasConnected && autoSync) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<WebSocketService>().syncTime();
      });
    }
    _wasConnected = connected;
    return const SizedBox.shrink();
  }
}

/// Pushes the EPS-logging config to the satellite and keeps the PC-history flag
/// in sync with the chosen mode.
class _EpsLogSync extends StatefulWidget {
  const _EpsLogSync();

  @override
  State<_EpsLogSync> createState() => _EpsLogSyncState();
}

class _EpsLogSyncState extends State<_EpsLogSync> {
  EpsLogMode? _lastMode;
  int? _lastInterval;
  bool _wasConnected = false;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsService>();
    final connected = context.watch<WebSocketService>().isConnected;
    final ws = context.read<WebSocketService>();
    ws.persistLiveEps = s.epsLogMode == EpsLogMode.pcHistory;

    final changed = s.epsLogMode != _lastMode || s.epsLogInterval != _lastInterval;
    final justConnected = connected && !_wasConnected;
    if (connected && (changed || justConnected)) {
      _lastMode = s.epsLogMode;
      _lastInterval = s.epsLogInterval;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ws.sendEpsLogConfig(
              s.epsLogMode == EpsLogMode.satellite, s.epsLogInterval);
        }
      });
    }
    _wasConnected = connected;
    return const SizedBox.shrink();
  }
}
