import 'package:flutter/material.dart';

import 'printer_sdk_config.dart';

/// Lays status cards out in a responsive grid.
///
/// Four cards per row on phones and wider, two per row on very narrow screens.
class PrinterStatusGrid extends StatelessWidget {
  const PrinterStatusGrid({
    super.key,
    required this.children,
    this.spacing = 8,
  });

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = constraints.maxWidth >= 360 ? 4 : 2;
        final double width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: children
              .map((Widget child) => SizedBox(width: width, child: child))
              .toList(),
        );
      },
    );
  }
}

/// A compact metric tile used by the connection screens.
class PrinterStatusCard extends StatelessWidget {
  const PrinterStatusCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  /// Slightly reduces padding for small phones.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 10 : 12,
      ),
      decoration: BoxDecoration(
        color: PrinterSdkConfig.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PrinterSdkConfig.borderColor),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: compact ? 28 : 32,
            height: compact ? 28 : 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: compact ? 16 : 18, color: color),
          ),
          SizedBox(height: compact ? 5 : 7),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: PrinterSdkConfig.textSecondaryColor,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 11.5 : 12.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small rounded status badge, e.g. `Connected`.
class PrinterStatusPill extends StatelessWidget {
  const PrinterStatusPill({
    super.key,
    required this.label,
    required this.color,
    this.onGradient = false,
    this.showDot = true,
  });

  final String label;
  final Color color;

  /// Renders a white translucent pill when placed on a colored gradient.
  final bool onGradient;
  final bool showDot;

  @override
  Widget build(BuildContext context) {
    final Color background = onGradient
        ? Colors.white.withValues(alpha: 0.18)
        : color.withValues(alpha: 0.12);
    final Color foreground = onGradient ? Colors.white : color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(30),
        border: onGradient
            ? Border.all(color: Colors.white.withValues(alpha: 0.28))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showDot) ...<Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: foreground,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}

/// The hero card at the top of a connection screen.
class PrinterHeroCard extends StatelessWidget {
  const PrinterHeroCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.statusLabel,
    required this.statusColor,
    this.accentColor,
    this.accentDarkColor,
    this.onGradient = true,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String statusLabel;
  final Color statusColor;

  /// Gradient start. Defaults to [PrinterSdkConfig.primaryColor].
  final Color? accentColor;

  /// Gradient end. Defaults to [PrinterSdkConfig.primaryDarkColor].
  final Color? accentDarkColor;

  final bool onGradient;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final bool gradient = onGradient;
    final Color accent = accentColor ?? PrinterSdkConfig.primaryColor;
    final Color accentDark = accentDarkColor ?? PrinterSdkConfig.primaryDarkColor;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: gradient
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[accent, accentDark],
              )
            : null,
        color: gradient ? null : PrinterSdkConfig.surfaceColor,
        borderRadius: BorderRadius.circular(PrinterSdkConfig.borderRadius + 4),
        border: gradient
            ? null
            : Border.all(color: PrinterSdkConfig.borderColor),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: gradient
                ? accent.withValues(alpha: 0.28)
                : Colors.black.withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: gradient
                  ? Colors.white.withValues(alpha: 0.18)
                  : accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              border: gradient
                  ? Border.all(color: Colors.white.withValues(alpha: 0.25))
                  : null,
            ),
            child: Icon(
              icon,
              color: gradient ? Colors.white : accent,
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: gradient
                        ? Colors.white
                        : PrinterSdkConfig.textPrimaryColor,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.25,
                    color: gradient
                        ? Colors.white.withValues(alpha: 0.8)
                        : PrinterSdkConfig.textSecondaryColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: gradient ? Colors.white : accent,
              ),
            )
          else
            PrinterStatusPill(
              label: statusLabel,
              color: gradient ? Colors.white : statusColor,
              onGradient: gradient,
            ),
        ],
      ),
    );
  }
}

/// A pressable device row shared by the Bluetooth and USB screens.
class PrinterDeviceTile extends StatelessWidget {
  const PrinterDeviceTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.isConnected,
    required this.onTap,
    this.icon = Icons.print_rounded,
    this.trailing,
    this.enabled = true,
    this.accentColor,
  });

  final String title;
  final String subtitle;
  final bool isConnected;
  final VoidCallback? onTap;
  final IconData icon;
  final Widget? trailing;
  final bool enabled;

  /// Accent used while the device is not connected. Defaults to
  /// [PrinterSdkConfig.primaryColor].
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final Color accent = isConnected
        ? PrinterSdkConfig.successColor
        : (accentColor ?? PrinterSdkConfig.primaryColor);

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: isConnected
            ? PrinterSdkConfig.successColor.withValues(alpha: 0.06)
            : PrinterSdkConfig.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isConnected
                ? PrinterSdkConfig.successColor.withValues(alpha: 0.45)
                : PrinterSdkConfig.borderColor,
            width: isConnected ? 1.4 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: <Widget>[
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 20, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: isConnected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: PrinterSdkConfig.textPrimaryColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: PrinterSdkConfig.textSecondaryColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                trailing ??
                    (isConnected
                        ? PrinterStatusPill(
                            label: 'Connected',
                            color: PrinterSdkConfig.successColor,
                          )
                        : Icon(
                            Icons.chevron_right_rounded,
                            color: PrinterSdkConfig.textSecondaryColor,
                            size: 20,
                          )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Friendly empty state with an optional call to action.
class PrinterEmptyState extends StatelessWidget {
  const PrinterEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: PrinterSdkConfig.primaryColor.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 26, color: PrinterSdkConfig.primaryColor),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: PrinterSdkConfig.textPrimaryColor,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: PrinterSdkConfig.textSecondaryColor,
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 14),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Visual tone of [PrinterActionButton].
enum PrinterActionTone { primary, danger, neutral }

/// Responsive action button used on the connection screens.
class PrinterActionButton extends StatelessWidget {
  const PrinterActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tone = PrinterActionTone.neutral,
    this.isLoading = false,
    this.accentColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final PrinterActionTone tone;
  final bool isLoading;

  /// Background of [PrinterActionTone.primary]. Defaults to
  /// [PrinterSdkConfig.primaryColor].
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final Color background = switch (tone) {
      PrinterActionTone.primary =>
        accentColor ?? PrinterSdkConfig.primaryColor,
      PrinterActionTone.danger => PrinterSdkConfig.errorColor,
      PrinterActionTone.neutral => PrinterSdkConfig.surfaceColor,
    };
    final Color foreground = switch (tone) {
      PrinterActionTone.primary || PrinterActionTone.danger => Colors.white,
      PrinterActionTone.neutral => PrinterSdkConfig.textPrimaryColor,
    };

    final Widget leading = isLoading
        ? SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
          )
        : Icon(icon, size: 17);

    final BorderSide side = tone == PrinterActionTone.neutral
        ? BorderSide(color: PrinterSdkConfig.borderColor)
        : BorderSide.none;

    return FilledButton.icon(
      onPressed: isLoading ? null : onPressed,
      icon: leading,
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        disabledBackgroundColor: tone == PrinterActionTone.neutral
            ? PrinterSdkConfig.surfaceColor
            : background.withValues(alpha: 0.45),
        disabledForegroundColor: foreground.withValues(alpha: 0.65),
        animationDuration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        minimumSize: const Size(0, 42),
        side: side,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
    );
  }
}
