import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';

import 'printer_sdk_config.dart';

/// App-wide printing indicator rendered in the root overlay.
///
/// Shows the bundled [printer_loading](assets/animations/printer_loading.json)
/// animation next to [PrinterSdkConfig.loadingLabel] while a job is on its way
/// to the printer. The animation is part of the package, so host apps get it
/// without declaring any asset of their own.
class GlobalLoaderController {
  static final GlobalLoaderController _instance =
      GlobalLoaderController._internal();
  factory GlobalLoaderController() => _instance;
  GlobalLoaderController._internal();

  static const String _assetPath =
      'assets/animations/printer_loading.json';
  static const String _packageName = 'posprinter_thermal';

  OverlayEntry? _overlayEntry;
  bool _isShowing = false;

  /// Loaded once and reused by every overlay rebuild.
  ///
  /// A package dependency exposes its assets under `packages/<name>/...`,
  /// while this repository's own demo app exposes them at the plain path, so
  /// both keys are tried.
  Future<ByteData>? _animation;

  Future<ByteData> _loadAnimation() {
    return _animation ??= () async {
      try {
        return await rootBundle.load('packages/$_packageName/$_assetPath');
      } catch (_) {
        return rootBundle.load(_assetPath);
      }
    }();
  }

  /// Optional navigator key retained for host apps that used it before.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// Shows the floating printing indicator.
  void show(BuildContext? context) {
    if (!PrinterSdkConfig.showPrintLoader) return;
    if (context == null || _isShowing) return;

    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _isShowing = true;
    _overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        right: 16,
        bottom: 16,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: PrinterSdkConfig.surfaceColor,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: PrinterSdkConfig.borderColor),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 32,
                  height: 32,
                  child: FutureBuilder<ByteData>(
                    future: _loadAnimation(),
                    builder: (BuildContext context,
                        AsyncSnapshot<ByteData> snapshot) {
                      if (!snapshot.hasData) {
                        return Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: PrinterSdkConfig.primaryColor,
                          ),
                        );
                      }
                      return Lottie.memory(
                        snapshot.data!.buffer.asUint8List(),
                        repeat: true,
                        fit: BoxFit.contain,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  PrinterSdkConfig.loadingLabel,
                  style: TextStyle(
                    color: PrinterSdkConfig.textPrimaryColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      overlay.insert(_overlayEntry!);
    } catch (_) {
      _isShowing = false;
      _overlayEntry = null;
    }
  }

  /// Hides the indicator. Safe to call even when nothing is visible.
  void hide() {
    if (!_isShowing) return;
    _isShowing = false;

    try {
      _overlayEntry?.remove();
    } catch (_) {
      // The entry may already be detached if the app was rebuilt.
    } finally {
      _overlayEntry = null;
    }
  }
}
