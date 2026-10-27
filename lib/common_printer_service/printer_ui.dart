import 'dart:async';

import 'package:flutter/material.dart';

import 'printer_sdk_config.dart';

/// Semantic tone of an SDK toast.
enum PrinterToastType { success, error, info }

/// Tracks the host app's root overlays so the SDK can render toasts and other
/// floating UI without requiring a `BuildContext` at the call site.
///
/// The SDK screens call [attach] while they build. Services (reconnect loops,
/// print callbacks) can then show a toast even though they have no context.
abstract final class PrinterOverlay {
  static OverlayState? _overlay;

  /// Remembers the root overlay of [context].
  ///
  /// Safe to call on every build: only the first overlay is kept.
  static void attach(BuildContext context) {
    final OverlayState? current = _overlay;
    if (current != null && current.mounted) return;
    _overlay = Overlay.maybeOf(context, rootOverlay: true);
  }

  /// Forgets the remembered overlay. Called when the host tears the SDK down.
  static void detach() => _overlay = null;

  /// The remembered overlay, or `null` when it was never captured or the host
  /// app has rebuilt its tree since.
  static OverlayState? get overlay {
    final OverlayState? current = _overlay;
    if (current == null || !current.mounted) return null;
    return current;
  }

  /// Resolves the overlay for [context] when one is supplied, falling back to
  /// the remembered root overlay.
  static OverlayState? resolve(BuildContext? context) {
    if (context != null) {
      final OverlayState? fromContext = Overlay.maybeOf(
        context,
        rootOverlay: true,
      );
      if (fromContext != null) return fromContext;
    }
    return overlay;
  }
}

/// Shows a themed toast.
///
/// The toast is rendered in the host app's root overlay instead of a
/// [SnackBar], so the SDK never depends on the host's [ScaffoldMessenger] and
/// can be driven from services and callbacks. Only one SDK toast is visible at
/// a time; a new one replaces the previous one.
void showPrinterToast(
  String message, {
  PrinterToastType type = PrinterToastType.info,
  BuildContext? context,
}) {
  final String text = message.trim();
  if (text.isEmpty || !PrinterSdkConfig.showToasts) return;

  final Color background = switch (type) {
    PrinterToastType.success => PrinterSdkConfig.successColor,
    PrinterToastType.error => PrinterSdkConfig.errorColor,
    PrinterToastType.info => PrinterSdkConfig.primaryColor,
  };

  showPrinterToastWithColor(
    text,
    color: background,
    context: context,
  );
}

/// Shows a toast with an explicit [color].
///
/// Prefer [showPrinterToast]; this exists for callers that already resolved a
/// semantic color themselves.
void showPrinterToastWithColor(
  String message, {
  required Color color,
  BuildContext? context,
}) {
  final String text = message.trim();
  if (text.isEmpty || !PrinterSdkConfig.showToasts) return;

  final OverlayState? overlay = PrinterOverlay.resolve(context);
  if (overlay == null) {
    // No Flutter tree (or no overlay) to render into yet. Keep the message
    // visible in debug builds instead of silently dropping it.
    debugPrint('posprinter_thermal: $text');
    return;
  }

  _activeToast?.remove();
  _activeToast = null;

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext _) => _PrinterToastOverlay(
      message: text,
      background: color,
      onDismissed: () {
        if (identical(_activeToast, entry)) _activeToast = null;
        if (entry.mounted) entry.remove();
      },
    ),
  );

  _activeToast = entry;
  try {
    overlay.insert(entry);
  } catch (_) {
    _activeToast = null;
  }
}

OverlayEntry? _activeToast;

/// Hides the visible toast, if any.
void hidePrinterToast() {
  _activeToast?.remove();
  _activeToast = null;
}

/// Backwards-compatible helper for the old app-level `displaySnackBar`.
///
/// Prefer [showPrinterToast] in new code.
@Deprecated('Use showPrinterToast instead.')
void displaySnackBar({
  required Color color,
  required String message,
  BuildContext? context,
}) {
  showPrinterToastWithColor(message, color: color, context: context);
}

/// Fade + slide toast built from Material widgets.
class _PrinterToastOverlay extends StatefulWidget {
  const _PrinterToastOverlay({
    required this.message,
    required this.background,
    required this.onDismissed,
  });

  final String message;
  final Color background;
  final VoidCallback onDismissed;

  @override
  State<_PrinterToastOverlay> createState() => _PrinterToastOverlayState();
}

class _PrinterToastOverlayState extends State<_PrinterToastOverlay>
    with SingleTickerProviderStateMixin {
  static const Duration _visibleFor = Duration(milliseconds: 2200);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 160),
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _timer = Timer(_visibleFor, _dismiss);
  }

  Future<void> _dismiss() async {
    _timer?.cancel();
    if (!mounted) return;
    await _controller.reverse();
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: SafeArea(
        top: false,
        child: IgnorePointer(
          child: FadeTransition(
            opacity: _curve,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.35),
                end: Offset.zero,
              ).animate(_curve),
              child: Material(
                color: Colors.transparent,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: widget.background,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Text(
                      widget.message,
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows a premium styled confirmation dialog.
///
/// Returns `true` only when the confirm button was tapped.
Future<bool> showPrinterConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Yes',
  String cancelLabel = 'No',
  bool destructive = false,
}) async {
  final bool? result = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final Color actionColor = destructive
          ? PrinterSdkConfig.errorColor
          : PrinterSdkConfig.primaryColor;

      return AlertDialog(
        backgroundColor: PrinterSdkConfig.surfaceColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PrinterSdkConfig.borderRadius),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: PrinterSdkConfig.textPrimaryColor,
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        content: Text(
          message,
          style: TextStyle(
            color: PrinterSdkConfig.textSecondaryColor,
            fontSize: 14,
            height: 1.4,
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: PrinterSdkConfig.textSecondaryColor,
            ),
            child: Text(cancelLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: actionColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );

  return result ?? false;
}
