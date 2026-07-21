import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/websocket_service.dart';
import '../theme/app_theme.dart';

/// A friendly, self-explanatory connection banner so users never need the
/// terminal: it shows exactly where the link stands (software → USB → satellite)
/// and offers a serial-port picker and a Reconnect button.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ws = context.watch<WebSocketService>();
    final stage = ws.stage;

    // Per-stage presentation.
    late final Color color;
    late final IconData icon;
    late final String title;
    late final String subtitle;
    switch (stage) {
      case ConnectionStage.bridgeOffline:
        color = c.error;
        icon = Icons.cloud_off;
        title = 'Starting ground station software…';
        subtitle =
            'Connecting to the local bridge. If this persists, launch the app '
            'with the provided start script.';
        break;
      case ConnectionStage.noGroundStation:
        color = c.warning;
        icon = Icons.usb_off;
        title = 'No ground station detected on USB';
        subtitle = ws.serialError != null
            ? 'Port error: ${ws.serialError}. Close the Arduino Serial Monitor, '
                'then pick the port below or press Reconnect.'
            : 'Plug in the ground station over USB and pick its port below. '
                'Close the Arduino Serial Monitor if it is open.';
        break;
      case ConnectionStage.waitingForSatellite:
        color = c.info;
        icon = Icons.satellite_alt;
        title = 'Connected to ground station — waiting for satellite…';
        subtitle =
            'Listening on ${ws.currentPort ?? 'the selected port'}. Make sure '
            'the OBC and COMMS boards are powered and antennas are attached.';
        break;
      case ConnectionStage.live:
        color = c.success;
        icon = Icons.check_circle;
        title = 'Live — receiving telemetry from FlatSat';
        subtitle = 'Connected on ${ws.currentPort ?? ''}.';
        break;
    }

    // Compact single-line bar when everything is healthy.
    if (stage == ConnectionStage.live) {
      return _LiveBar(color: color, icon: icon, title: title);
    }

    final showPortPicker =
        ws.isConnected && stage != ConnectionStage.bridgeOffline;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (stage == ConnectionStage.waitingForSatellite)
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                )
              else
                Icon(icon, color: color, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (showPortPicker || stage == ConnectionStage.bridgeOffline) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (showPortPicker) _PortPicker(ws: ws, color: color),
                _ReconnectButton(ws: ws, color: color),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LiveBar extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String title;
  const _LiveBar({required this.color, required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            'Change port',
            style: TextStyle(color: c.textMuted, fontSize: 11),
          ),
          const SizedBox(width: 6),
          _PortMenuButton(
            ws: context.read<WebSocketService>(),
            color: color,
            iconOnly: true,
          ),
        ],
      ),
    );
  }
}

/// A dropdown of available serial ports (plus an Auto-detect option).
class _PortPicker extends StatelessWidget {
  final WebSocketService ws;
  final Color color;
  const _PortPicker({required this.ws, required this.color});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.usb, color: c.textMuted, size: 16),
          const SizedBox(width: 8),
          _PortMenuButton(ws: ws, color: color),
        ],
      ),
    );
  }
}

class _PortMenuButton extends StatelessWidget {
  final WebSocketService ws;
  final Color color;
  final bool iconOnly;
  const _PortMenuButton({
    required this.ws,
    required this.color,
    this.iconOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ports = ws.availablePorts;
    final label = ws.currentPort ?? 'Auto-detect';

    return PopupMenuButton<String>(
      tooltip: 'Select serial port',
      onOpened: ws.requestPorts, // refresh the list when opened
      onSelected: (device) => ws.selectPort(device),
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          value: '',
          child: Text('Auto-detect'),
        ),
        if (ports.isNotEmpty) const PopupMenuDivider(),
        ...ports.map(
          (p) => PopupMenuItem<String>(
            value: p.device,
            child: Text(p.label),
          ),
        ),
        if (ports.isEmpty)
          const PopupMenuItem<String>(
            enabled: false,
            child: Text('No ports found'),
          ),
      ],
      child: iconOnly
          ? Icon(Icons.tune, color: color, size: 18)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Icon(Icons.arrow_drop_down, color: c.textMuted, size: 20),
              ],
            ),
    );
  }
}

class _ReconnectButton extends StatelessWidget {
  final WebSocketService ws;
  final Color color;
  const _ReconnectButton({required this.ws, required this.color});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: ws.reconnect,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: color.withOpacity(0.15),
            border: Border.all(color: color.withOpacity(0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.refresh, color: color, size: 16),
              const SizedBox(width: 6),
              Text(
                'Reconnect',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
