import 'package:flutter/material.dart';

import 'bluetooth_printer_service/bluetooth_printer_service.dart';
import 'printer_sdk_config.dart';
import 'printer_storage.dart';
import 'usb_printer_service/printer_services/printer_service.dart';

/// Entry point for the thermal printer SDK.
///
/// Call [initialize] once during app startup (before showing the settings
/// screen) so the SDK can open its Hive box and start monitoring both
/// connection types for automatic reconnection. For Bluetooth this is what
/// restores the saved printer after a Flutter hot restart.
///
/// ```dart
/// await PrinterSdk.initialize(
///   primaryColor: const Color(0xFF0F766E),
///   hiveBoxName: 'my_app_printer',
/// );
/// runApp(MyApp());
/// ```
///
/// The call is optional and idempotent: each screen also initializes lazily, so
/// forgetting it only costs a few milliseconds on first open.
abstract final class PrinterSdk {
  /// Configures the SDK and opens its local storage.
  ///
  /// Every parameter is optional; omitted values keep their current setting
  /// from [PrinterSdkConfig].
  static Future<void> initialize({
    Color? primaryColor,
    Color? primaryDarkColor,
    Color? accentColor,
    Color? bluetoothColor,
    Color? bluetoothDarkColor,
    Color? usbColor,
    Color? usbDarkColor,
    Color? successColor,
    Color? errorColor,
    Color? warningColor,
    Color? backgroundColor,
    Color? surfaceColor,
    String? hiveBoxName,
    String? appBarTitle,
    List<String>? paperSizes,
    String? defaultPaperSize,
    Duration? scanTimeout,
    Duration? connectTimeout,
    Duration? printTimeout,
    bool? autoReconnect,
    Duration? bluetoothHealthCheckInterval,
    List<Duration>? reconnectDelays,
    int? reconnectMaxAttempts,
    bool? showToasts,
    bool? showPrintLoader,
  }) async {
    if (primaryColor != null) PrinterSdkConfig.primaryColor = primaryColor;
    if (primaryDarkColor != null) {
      PrinterSdkConfig.primaryDarkColor = primaryDarkColor;
    }
    if (accentColor != null) PrinterSdkConfig.accentColor = accentColor;
    if (bluetoothColor != null) {
      PrinterSdkConfig.bluetoothColor = bluetoothColor;
    }
    if (bluetoothDarkColor != null) {
      PrinterSdkConfig.bluetoothDarkColor = bluetoothDarkColor;
    }
    if (usbColor != null) PrinterSdkConfig.usbColor = usbColor;
    if (usbDarkColor != null) PrinterSdkConfig.usbDarkColor = usbDarkColor;
    if (successColor != null) PrinterSdkConfig.successColor = successColor;
    if (errorColor != null) PrinterSdkConfig.errorColor = errorColor;
    if (warningColor != null) PrinterSdkConfig.warningColor = warningColor;
    if (backgroundColor != null) {
      PrinterSdkConfig.backgroundColor = backgroundColor;
    }
    if (surfaceColor != null) PrinterSdkConfig.surfaceColor = surfaceColor;
    if (hiveBoxName != null) PrinterSdkConfig.hiveBoxName = hiveBoxName;
    if (appBarTitle != null) PrinterSdkConfig.appBarTitle = appBarTitle;
    if (paperSizes != null && paperSizes.isNotEmpty) {
      PrinterSdkConfig.paperSizes = List<String>.unmodifiable(paperSizes);
    }
    if (defaultPaperSize != null) {
      PrinterSdkConfig.defaultPaperSize = defaultPaperSize;
    }
    if (scanTimeout != null) PrinterSdkConfig.scanTimeout = scanTimeout;
    if (connectTimeout != null) {
      PrinterSdkConfig.connectTimeout = connectTimeout;
    }
    if (printTimeout != null) PrinterSdkConfig.printTimeout = printTimeout;
    if (autoReconnect != null) PrinterSdkConfig.autoReconnect = autoReconnect;
    if (bluetoothHealthCheckInterval != null) {
      PrinterSdkConfig.bluetoothHealthCheckInterval =
          bluetoothHealthCheckInterval;
    }
    if (reconnectDelays != null && reconnectDelays.isNotEmpty) {
      PrinterSdkConfig.reconnectDelays = List<Duration>.unmodifiable(
        reconnectDelays,
      );
    }
    if (reconnectMaxAttempts != null) {
      PrinterSdkConfig.reconnectMaxAttempts = reconnectMaxAttempts;
    }
    if (showToasts != null) PrinterSdkConfig.showToasts = showToasts;
    if (showPrintLoader != null) {
      PrinterSdkConfig.showPrintLoader = showPrintLoader;
    }

    await PrinterStorage.ensureInitialized();

    // Restore the paper size so programmatic printing uses the same width as
    // the UI, even when the settings screen has not been opened yet.
    final String paperSize = PrinterStorage.readString(
      PrinterStorageKeys.paperSize,
      defaultValue: PrinterSdkConfig.defaultPaperSize,
    );
    BluetoothService.optionprinttype = paperSize;
    PrinterService.optionPrinterType = paperSize;

    // Subscribe to the native USB state stream now, not when the settings
    // screen opens. This is what lets the service notice an unplugged printer
    // and start reconnecting while the host app is on another screen. USB is
    // Android-only, so this is skipped entirely elsewhere (no plugin access).
    if (PrinterService.isSupported) {
      await PrinterService.init();
    }

    // Restore the saved Bluetooth printer and start the connection watchdog.
    // This is what makes a Flutter hot restart reconnect automatically.
    await BluetoothService.init();
  }

  /// Releases streams and platform listeners held by the SDK.
  ///
  /// Only needed when the host app tears down the engine manually; regular
  /// apps can ignore it.
  static Future<void> dispose() async {
    await PrinterService.dispose();
    await BluetoothService.dispose();
  }
}
