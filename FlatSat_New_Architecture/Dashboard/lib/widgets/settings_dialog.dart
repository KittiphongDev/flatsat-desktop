import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/websocket_service.dart';
import '../theme/app_theme.dart';
import 'setup_guide_dialog.dart';

/// Opens the settings dialog.
Future<void> showSettingsDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (_) => const SettingsDialog(),
  );
}

/// Settings for the ground station. Currently: camera build mode and the
/// auto-power-on-capture behaviour.
class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final settings = context.watch<SettingsService>();
    final media = MediaQuery.of(context).size;

    return Dialog(
      backgroundColor: c.surface,
      // Small side margins so the dialog can grow near full width on tiny
      // windows instead of staying pinned to a narrow fixed size.
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusCard),
      ),
      child: ConstrainedBox(
        // Responsive: wider on big screens, capped so it never overflows the
        // window; scrolls vertically when the content is taller than 86% of it.
        constraints: BoxConstraints(
          maxWidth: 1000,
          maxHeight: media.height * 0.86,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Row(
                children: [
                  Icon(Icons.settings_outlined, color: c.textSecondary, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    'SETTINGS',
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, color: c.textMuted, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // ---- Camera mode ----
              _sectionLabel(context, 'CAMERA MODE'),
              const SizedBox(height: 10),
              _ModeChoice(
                selected: settings.cameraMode == CameraMode.prototype,
                title: 'Prototype',
                subtitle: CameraMode.prototype.blurb,
                onTap: () => settings.setCameraMode(CameraMode.prototype),
              ),
              const SizedBox(height: 8),
              _ModeChoice(
                selected: settings.cameraMode == CameraMode.production,
                title: 'Production',
                subtitle: CameraMode.production.blurb,
                onTap: () => settings.setCameraMode(CameraMode.production),
              ),

              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: c.warning.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(kRadiusControl),
                  border: Border.all(color: c.warning.withOpacity(0.30)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: c.warning, size: 16),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'This must match the firmware flashed on the OBC '
                        '(its CAMERA_MODE #define). They are not synced '
                        'automatically.',
                        style: TextStyle(
                            color: c.textSecondary, fontSize: 11.5, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),

              // ---- Terminal panels ----
              const SizedBox(height: 20),
              _sectionLabel(context, 'PANELS'),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: c.accent,
                value: settings.showEventLog,
                onChanged: (v) => settings.setShowEventLog(v),
                title: Text(
                  'Event log terminal',
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Commands you send and high-level responses.',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: c.accent,
                value: settings.showBridgeLog,
                onChanged: (v) => settings.setShowBridgeLog(v),
                title: Text(
                  'Bridge traffic terminal',
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Raw serial frames the bridge sends/receives (hex + RSSI).',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              ),

              // ---- Auto power (production only) ----
              const SizedBox(height: 20),
              _sectionLabel(context, 'CAPTURE'),
              const SizedBox(height: 6),
              Opacity(
                opacity: settings.isProduction ? 1 : 0.45,
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: c.accent,
                  value: settings.autoPowerOnCapture,
                  onChanged: settings.isProduction
                      ? (v) => settings.setAutoPowerOnCapture(v)
                      : null,
                  title: Text(
                    'Auto-power camera on capture',
                    style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    settings.isProduction
                        ? 'TAKE PIC powers the camera on, waits, then captures.'
                        : 'Only available in Production mode.',
                    style: TextStyle(color: c.textMuted, fontSize: 11.5),
                  ),
                ),
              ),

              // ---- Display ----
              const SizedBox(height: 20),
              _sectionLabel(context, 'DISPLAY'),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: c.accent,
                value: settings.imageSizeUnit == ImageSizeUnit.both,
                onChanged: (v) => settings.setImageSizeUnit(
                    v ? ImageSizeUnit.both : ImageSizeUnit.kbOnly),
                title: Text(
                  'Show image size in MB too',
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  settings.imageSizeUnit == ImageSizeUnit.both
                      ? 'e.g. "48.2 KB (0.05 MB)"'
                      : 'e.g. "48.2 KB"',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              ),

              // ---- Image save folder ----
              const SizedBox(height: 20),
              _sectionLabel(context, 'IMAGE SAVE FOLDER'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: c.scaffold,
                  borderRadius: BorderRadius.circular(kRadiusControl),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, color: c.textMuted, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        settings.downloadDir ?? 'Default folder',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 11.5,
                            fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: c.accent),
                      onPressed: () async {
                        final dir = await FilePicker.platform.getDirectoryPath(
                            dialogTitle: 'Choose image save folder');
                        if (dir != null && dir.isNotEmpty) {
                          await settings.setDownloadDir(dir);
                        }
                      },
                      child: const Text('Change…'),
                    ),
                  ],
                ),
              ),

              // ---- Safety ----
              const SizedBox(height: 20),
              _sectionLabel(context, 'SAFETY'),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: c.accent,
                value: settings.commsLockEnabled,
                onChanged: (v) async {
                  if (!v) {
                    // Disabling the lock is the risky action — confirm first.
                    final ok = await _confirmUnlockComms(context);
                    if (!ok) return;
                  }
                  settings.setCommsLockEnabled(v);
                },
                title: Text(
                  'Lock Communication power OFF',
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  'Prevents switching the COMMS channel off from the ground '
                  '(it would cut the radio link). Turn off to allow it.',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              ),

              // ---- Satellite clock ----
              const SizedBox(height: 20),
              _sectionLabel(context, 'SATELLITE CLOCK'),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: c.accent,
                value: settings.timeAutoSync,
                onChanged: (v) => settings.setTimeAutoSync(v),
                title: Text(
                  'Auto-sync clock on connect',
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  "Sets the satellite's clock to this PC's time whenever the "
                  'link connects (used for EPS log timestamps).',
                  style: TextStyle(color: c.textMuted, fontSize: 11.5),
                ),
              ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.accent,
                  side: BorderSide(color: c.accent.withOpacity(0.5)),
                ),
                icon: const Icon(Icons.schedule, size: 16),
                label: const Text('Sync time now'),
                onPressed: () {
                  context.read<WebSocketService>().syncTime();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Time sync sent'),
                      duration: Duration(milliseconds: 1200),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
              ),

              // ---- Help ----
              const SizedBox(height: 20),
              _sectionLabel(context, 'HELP'),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.accent,
                  side: BorderSide(color: c.accent.withOpacity(0.5)),
                ),
                icon: const Icon(Icons.rocket_launch_outlined, size: 16),
                label: const Text('Open setup guide'),
                onPressed: () {
                  Navigator.of(context).pop(); // close settings first
                  showSetupGuide(context);
                },
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmUnlockComms(BuildContext context) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: const Text('Allow switching Communication off?'),
        content: const Text(
          'With the lock off, you can power down the Communication channel from '
          'the dashboard. Doing so CUTS the radio link — you will not be able to '
          'command the satellite until it is power-cycled on the board. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Unlock', style: TextStyle(color: c.error)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final c = context.colors;
    return Text(
      text,
      style: TextStyle(
        color: c.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
      ),
    );
  }
}

class _ModeChoice extends StatelessWidget {
  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ModeChoice({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadiusControl),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? c.accent.withOpacity(0.08) : c.scaffold,
          borderRadius: BorderRadius.circular(kRadiusControl),
          border: Border.all(
            color: selected ? c.accent.withOpacity(0.55) : c.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? c.accent : c.textMuted,
              size: 18,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                        color: c.textMuted, fontSize: 11.5, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
