import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

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

    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusCard),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
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
            ],
          ),
        ),
      ),
    );
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
