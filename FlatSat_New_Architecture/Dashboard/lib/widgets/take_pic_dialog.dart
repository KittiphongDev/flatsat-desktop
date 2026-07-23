import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/websocket_service.dart';
import '../theme/app_theme.dart';

/// Popup shown when the user presses TAKE PIC: choose the capture resolution
/// (remembered for next time), then send the command.
Future<void> showTakePicDialog(BuildContext context) {
  final settings = context.read<SettingsService>();
  final ws = context.read<WebSocketService>();
  int sel = settings.picResolution;

  return showDialog(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSt) {
        final c = ctx.colors;
        return AlertDialog(
          backgroundColor: c.surface,
          title: Row(
            children: [
              Icon(Icons.photo_camera, color: c.accent, size: 20),
              const SizedBox(width: 10),
              const Text('Take picture'),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Resolution — JPEG, 4:3',
                    style: TextStyle(
                        color: c.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1)),
                const SizedBox(height: 6),
                for (final r in kPicResolutions)
                  RadioListTile<int>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeColor: c.accent,
                    value: r.id,
                    groupValue: sel,
                    onChanged: (v) => setSt(() => sel = v ?? sel),
                    title: Text(r.label,
                        style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    subtitle: Text(r.detail,
                        style: TextStyle(color: c.textMuted, fontSize: 11)),
                  ),
                const SizedBox(height: 4),
                Text(
                  'Higher resolution = sharper but a bigger file and slower '
                  'download over the radio.',
                  style: TextStyle(color: c.textMuted, fontSize: 11, height: 1.35),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.accent),
              onPressed: () {
                settings.setPicResolution(sel);
                ws.capturePhoto(
                    autoPower: settings.autoPowerOnCapture, resolution: sel);
                Navigator.pop(ctx);
              },
              child: const Text('Capture'),
            ),
          ],
        );
      });
    },
  );
}
