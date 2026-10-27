import 'package:posprinter_usb_android/posprinter_usb_android.dart';

/// Printer transport used by [PrinterManager].
///
/// USB host printing is the only transport this package implements.
enum PrinterType { usb }

/// Entry point for discovering and printing to USB printers on Android.
///
/// ```dart
/// final PrinterManager manager = PrinterManager.instance;
/// await for (final PrinterDevice device in manager.discovery(type: PrinterType.usb)) {
///   // ...
/// }
/// ```
class PrinterManager {
  PrinterManager._();

  static final PrinterManager _instance = PrinterManager._();

  /// Process-wide shared instance.
  static PrinterManager get instance => _instance;

  /// The USB transport.
  final UsbPrinterConnector usbPrinterConnector = UsbPrinterConnector.instance;

  /// Stream of the USB printers that are attached right now.
  Stream<PrinterDevice> discovery({required PrinterType type}) =>
      usbPrinterConnector.discovery();

  /// Opens the printer described by [model].
  ///
  /// Completes only after Android has answered the USB permission dialog.
  Future<bool> connect({
    required PrinterType type,
    required BasePrinterInput model,
  }) {
    if (model is! UsbPrinterInput) return Future<bool>.value(false);
    return usbPrinterConnector.connect(model);
  }

  /// Closes the active USB connection.
  Future<bool> disconnect({required PrinterType type, int? delayMs}) =>
      usbPrinterConnector.disconnect(delayMs: delayMs);

  /// Writes raw ESC/POS [bytes] to the open USB connection.
  Future<bool> send({required PrinterType type, required List<int> bytes}) =>
      usbPrinterConnector.send(bytes);

  /// USB state changes reported by Android.
  Stream<USBStatus> get stateUSB => usbPrinterConnector.currentStatus;

  /// Last USB state reported by Android.
  USBStatus get currentStatusUSB => usbPrinterConnector.status;
}
