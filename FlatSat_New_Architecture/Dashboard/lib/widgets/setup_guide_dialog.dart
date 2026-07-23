import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../platform.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

/// Show the setup guide. [firstRun] marks the first-launch flag as seen on close.
Future<void> showSetupGuide(BuildContext context, {bool firstRun = false}) {
  return showDialog(
    context: context,
    barrierDismissible: !firstRun,
    builder: (_) => SetupGuideDialog(firstRun: firstRun),
  );
}

/// First-run / re-openable guide: what to install and allow, per operating
/// system, to use the ground station.
class SetupGuideDialog extends StatefulWidget {
  final bool firstRun;
  const SetupGuideDialog({super.key, this.firstRun = false});

  @override
  State<SetupGuideDialog> createState() => _SetupGuideDialogState();
}

class _SetupGuideDialogState extends State<SetupGuideDialog> {
  late HostOs _os = currentHostOs;

  static const Map<HostOs, List<String>> _steps = {
    HostOs.windows: [
      'Install Python 3 from python.org — tick "Add python.exe to PATH" during setup.',
      'If the ground-station COM port doesn\'t appear, install its USB-serial driver (CP210x / CH340 / FTDI).',
      'Start everything by double-clicking run_mission_control.bat.',
      'Close the Arduino IDE Serial Monitor before running — it locks the port.',
      'If auto-detect picks the wrong port, choose the GS port in the dashboard (Change port).',
    ],
    HostOs.macos: [
      'Install Python 3 (python.org or "brew install python").',
      'Install a USB-serial driver (CH340 / CP210x) if your adapter isn\'t recognised.',
      'First launch: right-click run_mission_control.command → Open (to pass Gatekeeper).',
      'Close the Arduino Serial Monitor before running.',
      'Pick the GS port in the dashboard if needed (Change port).',
    ],
    HostOs.linux: [
      'Python 3 is usually preinstalled; the launcher installs pyserial + websockets for you.',
      'Give yourself serial access:  sudo usermod -aG dialout \$USER  then log out and back in.',
      'Close the Arduino Serial Monitor before running.',
      'Start with:  ./run_mission_control.sh',
      'The GS KISS link is a USB-serial adapter (usually /dev/ttyUSB0) — pick it in the port selector.',
    ],
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final steps = _steps[_os]!;

    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.rocket_launch_outlined, color: c.accent, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    widget.firstRun ? 'WELCOME — QUICK SETUP' : 'SETUP GUIDE',
                    style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5),
                  ),
                  const Spacer(),
                  if (!widget.firstRun)
                    IconButton(
                      icon: Icon(Icons.close, color: c.textMuted, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'What to install and allow so the dashboard can reach the ground '
                'station. Pick your operating system:',
                style: TextStyle(color: c.textMuted, fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 14),

              // OS selector
              Row(
                children: [
                  for (final os in HostOs.values) ...[
                    _OsChip(
                      label: os.label,
                      selected: _os == os,
                      onTap: () => setState(() => _os = os),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
              const SizedBox(height: 16),

              // Steps
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: c.accent.withOpacity(0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Text('${i + 1}',
                            style: TextStyle(
                                color: c.accent,
                                fontSize: 11,
                                fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          steps[i],
                          style: TextStyle(
                              color: c.textPrimary, fontSize: 12.5, height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: c.accent),
                  onPressed: () {
                    if (widget.firstRun) {
                      context.read<SettingsService>().setFirstRunDone(true);
                    }
                    Navigator.pop(context);
                  },
                  child: Text(widget.firstRun ? 'Got it — let\'s go' : 'Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OsChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _OsChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.accent.withOpacity(0.12) : c.scaffold,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? c.accent.withOpacity(0.6) : c.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? c.accent : c.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
