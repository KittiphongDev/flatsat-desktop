import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A telemetry card with an icon, title, and value. Theme-aware.
class TelemetryCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final Color? accentColor;
  final String? subtitle;
  final Widget? trailing;

  const TelemetryCard({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    this.accentColor,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // accentColor is a *state* signal, not decoration. When a card has no
    // meaningful state (a plain reading like temperature or RSSI) it stays
    // neutral, so the only colored cards on screen are the ones saying
    // something.
    final hasState = accentColor != null;
    final iconColor = accentColor ?? c.textSecondary;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(kRadiusCard),
        // Hairline neutral border, no colored glow.
        border: Border.all(color: c.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 16),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: monoStyle(
                color: hasState ? accentColor! : c.textPrimary,
                fontSize: 23,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(
                color: c.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A small status indicator dot with label.
class StatusIndicator extends StatelessWidget {
  final bool isActive;
  final String label;

  const StatusIndicator({
    super.key,
    required this.isActive,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = isActive ? c.success : c.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Flat dot — the old neon bloom was the most "generated" detail here.
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

/// Subsystem power card with toggle.
class SubsystemCard extends StatelessWidget {
  final String name;
  final IconData icon;
  final bool isOn;
  final VoidCallback onToggle;
  final bool locked; // display-only (e.g. Communication — can't cut the link)

  const SubsystemCard({
    super.key,
    required this.name,
    required this.icon,
    required this.isOn,
    required this.onToggle,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = isOn ? c.success : c.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(kRadiusCard),
        border: Border.all(
          color: isOn ? c.success.withOpacity(0.35) : c.border,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  locked
                      ? 'POWERED ON · LOCKED'
                      : (isOn ? 'POWERED ON' : 'POWERED OFF'),
                  style: TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          if (locked)
            Tooltip(
              message:
                  'Communication power is locked — switching it off from the '
                  'ground would cut the radio link.',
              child: Icon(Icons.lock_outline, color: c.textMuted, size: 18),
            )
          else
          GestureDetector(
            onTap: onToggle,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 44,
              height: 24,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(kRadiusCard),
                color: isOn
                    ? c.success.withOpacity(0.3)
                    : c.textMuted.withOpacity(0.25),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 200),
                alignment:
                    isOn ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isOn ? c.success : c.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A styled command button.
class CommandButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  const CommandButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return _CommandButtonBody(icon: icon, label: label, onPressed: onPressed);
  }
}

/// Cohesive, low-chroma command button with a subtle accent on hover/press.
class _CommandButtonBody extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const _CommandButtonBody({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  State<_CommandButtonBody> createState() => _CommandButtonBodyState();
}

class _CommandButtonBodyState extends State<_CommandButtonBody> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = _hover;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onPressed,
          borderRadius: BorderRadius.circular(kRadiusControl),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadiusControl),
              color: active ? c.accent.withOpacity(0.10) : c.surface,
              border: Border.all(
                color: active ? c.accent.withOpacity(0.55) : c.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  color: active ? c.accent : c.textSecondary,
                  size: 17,
                ),
                const SizedBox(width: 9),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: active ? c.accent : c.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
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
