import 'package:flutter/foundation.dart';

/// What happened to a printer that used to be connected.
enum PrinterConnectionEventType {
  /// The link dropped (cable pull, printer powered off, out of range, ...).
  disconnected,

  /// The service is waiting for, or trying, the next reconnect.
  reconnecting,

  /// A reconnect attempt succeeded.
  reconnected,

  /// Reconnect was abandoned (no saved printer, retries exhausted, ...).
  reconnectFailed,
}

/// Immutable connection-lifecycle notification shared by [PrinterService] and
/// [BluetoothService].
///
/// Host apps can show a banner or dialog by listening to
/// `PrinterService.connectionEvents` or `BluetoothService.connectionEvents`.
/// Reconnection itself is handled by the services, so the UI is optional.
@immutable
class PrinterConnectionEvent {
  const PrinterConnectionEvent({
    required this.type,
    required this.message,
    this.attempt = 0,
    this.maxAttempts = 0,
    this.nextRetry,
  });

  final PrinterConnectionEventType type;
  final String message;

  /// 1-based reconnect attempt, or `0` when not applicable.
  final int attempt;

  /// Maximum number of attempts, or `0` for unlimited.
  final int maxAttempts;

  /// Delay before the attempt announced by this event.
  final Duration? nextRetry;

  bool get isRecovered => type == PrinterConnectionEventType.reconnected;

  @override
  String toString() {
    return 'PrinterConnectionEvent(${type.name}, attempt: $attempt, '
        'message: $message)';
  }
}
