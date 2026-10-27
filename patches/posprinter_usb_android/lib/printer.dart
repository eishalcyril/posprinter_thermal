import 'package:flutter/services.dart';

/// Method channel shared with the Android implementation.
final MethodChannel flutterPrinterChannel =
    const MethodChannel('com.sersoluciones.flutter_pos_printer_platform');

/// Event channel that reports USB attach/detach/connect state on Android.
final EventChannel flutterPrinterEventChannelUSB =
    const EventChannel('com.sersoluciones.flutter_pos_printer_platform/usb_state');

/// USB connection states reported by the Android implementation.
///
/// The order is significant: the platform sends the index of this enum.
enum USBStatus { none, connecting, connected, attached }

/// Base class for the input model passed to a connector.
abstract class BasePrinterInput {}

/// Sends raw ESC/POS bytes over a printer transport.
abstract class PrinterConnector<T> {
  /// Writes [bytes] to the printer.
  Future<bool> send(List<int> bytes);

  /// Opens the transport described by [model].
  Future<bool> connect(T model);

  /// Closes the transport.
  Future<bool> disconnect({int? delayMs});
}
