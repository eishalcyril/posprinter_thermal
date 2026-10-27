import 'package:flutter/material.dart';

/// Global configuration for the thermal printer SDK.
///
/// Everything here is intentionally mutable so host applications can brand
/// the SDK without forking it. Call [PrinterSdk.initialize] once (or simply
/// assign the fields directly) before showing the connection screen.
///
/// ```dart
/// PrinterSdkConfig.primaryColor = const Color(0xFF0F766E);
/// PrinterSdkConfig.hiveBoxName = 'my_app_printer';
/// ```
class PrinterSdkConfig {
  PrinterSdkConfig._();

  // ---------------------------------------------------------------------------
  // Brand colors
  // ---------------------------------------------------------------------------

  /// Primary brand color. Used for buttons, toggles, gradients and accents.
  static Color primaryColor = const Color(0xFF2563EB);

  /// Darker shade of [primaryColor], used for gradient ends and pressed states.
  static Color primaryDarkColor = const Color(0xFF1D4ED8);

  /// Secondary accent color.
  static Color accentColor = const Color(0xFF0EA5E9);

  // ---------------------------------------------------------------------------
  // Connection-type accents
  // ---------------------------------------------------------------------------
  //
  // Bluetooth and USB each get their own accent so the two connection types
  // stay visually distinct in the toggle, the hero card, the action buttons and
  // the device list. The defaults are platform-neutral Material tones: any app
  // can keep them or point them at its own brand.

  /// Accent of the Bluetooth connection type.
  static Color bluetoothColor = const Color(0xFF2563EB);

  /// Darker shade of [bluetoothColor], used for the hero gradient.
  static Color bluetoothDarkColor = const Color(0xFF1D4ED8);

  /// Accent of the USB connection type.
  static Color usbColor = const Color(0xFF7C3AED);

  /// Darker shade of [usbColor], used for the hero gradient.
  static Color usbDarkColor = const Color(0xFF6D28D9);

  /// Color used for successful states (connected, print sent).
  static Color successColor = const Color(0xFF16A34A);

  /// Color used for destructive states (errors, disconnect).
  static Color errorColor = const Color(0xFFDC2626);

  /// Color used for in-progress states (scanning, pairing).
  static Color warningColor = const Color(0xFFD97706);

  /// Scaffold background.
  static Color backgroundColor = const Color(0xFFF6F8FC);

  /// Card / sheet background.
  static Color surfaceColor = const Color(0xFFFFFFFF);

  /// Hairline border used on cards and inputs.
  static Color borderColor = const Color(0xFFE4E9F2);

  /// Primary text color.
  static Color textPrimaryColor = const Color(0xFF0F172A);

  /// Secondary / muted text color.
  static Color textSecondaryColor = const Color(0xFF64748B);

  /// Color of the text/icon rendered on top of [primaryColor].
  static Color onPrimaryColor = const Color(0xFFFFFFFF);

  // ---------------------------------------------------------------------------
  // Shape and spacing
  // ---------------------------------------------------------------------------

  /// Default corner radius for cards, buttons and inputs.
  static double borderRadius = 16;

  /// Outer padding used by the SDK screens.
  static EdgeInsets screenPadding = const EdgeInsets.all(16);

  /// Vertical gap between sections.
  static double sectionSpacing = 12;

  // ---------------------------------------------------------------------------
  // Behavior
  // ---------------------------------------------------------------------------

  /// Hive box used for persisting the selected printer.
  ///
  /// The SDK opens this box lazily, so host apps no longer have to do it.
  /// Change the value before calling [PrinterSdk.initialize].
  static String hiveBoxName = 'posprinter_thermal';

  /// How long a Bluetooth / USB discovery pass may take.
  static Duration scanTimeout = const Duration(seconds: 6);

  /// How long a connection attempt may take.
  ///
  /// USB access is granted through an Android system dialog, so leave enough
  /// time for the user to tap "Allow" on the device.
  static Duration connectTimeout = const Duration(seconds: 20);

  /// How long a print job may take.
  static Duration printTimeout = const Duration(seconds: 10);

  /// Whether a disconnected USB or Bluetooth printer is reconnected
  /// automatically.
  ///
  /// The services always use the printer persisted by the last successful
  /// connection; a manual disconnect stops the loop until the next connect.
  static bool autoReconnect = true;

  /// How often a connected Bluetooth printer is verified.
  ///
  /// The `print_bluetooth_thermal` plugin has no connection stream: its health
  /// check writes a single space to the socket. Keep the interval reasonably
  /// long to avoid filling the printer's line buffer, or set it to
  /// [Duration.zero] to disable the watchdog and rely on print failures plus
  /// app-resume checks.
  static Duration bluetoothHealthCheckInterval = const Duration(seconds: 15);

  /// Delays between automatic reconnect attempts.
  ///
  /// The last entry is reused once the list is exhausted, so the printer is
  /// still picked up when it is replugged later. Set [reconnectMaxAttempts] to
  /// stop retrying.
  static List<Duration> reconnectDelays = const <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  /// Maximum automatic reconnect attempts.
  ///
  /// `0` means unlimited. The default keeps trying (with [reconnectDelays]) so
  /// a kiosk recovers after the printer is plugged back in, even hours later.
  static int reconnectMaxAttempts = 0;

  /// Whether transient status changes are surfaced as toasts.
  static bool showToasts = true;

  /// Whether to show the animated loading bubble while printing.
  static bool showPrintLoader = true;

  // ---------------------------------------------------------------------------
  // Copy
  // ---------------------------------------------------------------------------

  /// App bar title of the connection screen.
  static String appBarTitle = 'Printer Settings';

  /// Label shown inside the loading bubble, next to the printing animation.
  static String loadingLabel = 'Printing';

  /// Supported paper sizes, in display order.
  static List<String> paperSizes = const ['58 mm', '80 mm'];

  /// Default paper size for new installations.
  static String defaultPaperSize = '58 mm';

  /// Returns [paperSizes] mapped to a `PaperSize`-agnostic value.
  static bool is80mm(String paperSize) => paperSize.trim().startsWith('80');

  /// Resets every option to its factory default. Handy in tests.
  static void reset() {
    primaryColor = const Color(0xFF2563EB);
    primaryDarkColor = const Color(0xFF1D4ED8);
    accentColor = const Color(0xFF0EA5E9);
    bluetoothColor = const Color(0xFF2563EB);
    bluetoothDarkColor = const Color(0xFF1D4ED8);
    usbColor = const Color(0xFF7C3AED);
    usbDarkColor = const Color(0xFF6D28D9);
    successColor = const Color(0xFF16A34A);
    errorColor = const Color(0xFFDC2626);
    warningColor = const Color(0xFFD97706);
    backgroundColor = const Color(0xFFF6F8FC);
    surfaceColor = const Color(0xFFFFFFFF);
    borderColor = const Color(0xFFE4E9F2);
    textPrimaryColor = const Color(0xFF0F172A);
    textSecondaryColor = const Color(0xFF64748B);
    onPrimaryColor = const Color(0xFFFFFFFF);
    borderRadius = 16;
    screenPadding = const EdgeInsets.all(16);
    sectionSpacing = 12;
    hiveBoxName = 'posprinter_thermal';
    scanTimeout = const Duration(seconds: 6);
    connectTimeout = const Duration(seconds: 20);
    printTimeout = const Duration(seconds: 10);
    autoReconnect = true;
    bluetoothHealthCheckInterval = const Duration(seconds: 15);
    reconnectDelays = const <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 15),
      Duration(seconds: 30),
    ];
    reconnectMaxAttempts = 0;
    showToasts = true;
    showPrintLoader = true;
    appBarTitle = 'Printer Settings';
    loadingLabel = 'Printing';
    paperSizes = const ['58 mm', '80 mm'];
    defaultPaperSize = '58 mm';
  }
}
