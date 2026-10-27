import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_esc_pos_utils/flutter_esc_pos_utils.dart';
import 'package:posprinter_usb_android/posprinter_usb_android.dart';

import '../../printer_connection_event.dart';
import '../../printer_sdk_config.dart';
import '../../printer_storage.dart';

// Kept so host apps that import this file directly still see the event types.
export '../../printer_connection_event.dart';

/// Stateless bridge to the platform USB printer APIs.
///
/// USB host access is Android-only; on every other platform (iOS, macOS,
/// Windows, Linux, web) [isSupported] returns `false`, the plugin is never
/// touched and the UI falls back to Bluetooth.
///
/// Connection lifecycle:
/// 1. [init] subscribes to the native USB state stream (once, for the whole
///    process), so unplugging a printer is noticed even while no settings
///    screen is open.
/// 2. On an unexpected detach the service emits
///    [PrinterConnectionEventType.disconnected] and schedules reconnects with
///    the delays from [PrinterSdkConfig.reconnectDelays].
/// 3. Reconnecting uses the printer persisted by the last successful
///    [connect], so no scan or user interaction is required.
/// 4. A print failure is treated like a detach: the service marks the link as
///    down, tries to reconnect and retries the job once.
///
/// A manual [disconnect] stops the automatic reconnect loop. Connecting again
/// (or calling [reconnectSaved]) re-enables it.
class PrinterService {
  PrinterService._();

  static final PrinterManager _manager = PrinterManager.instance;
  static final List<PrinterDevice> _discovered = <PrinterDevice>[];
  static final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  static final StreamController<PrinterConnectionEvent> _eventController =
      StreamController<PrinterConnectionEvent>.broadcast();

  static StreamSubscription<USBStatus>? _usbStatusSubscription;
  static CapabilityProfile? _capabilityProfile;
  static Future<void>? _initFuture;
  static Future<bool>? _connectOperation;
  static Future<void> _printChain = Future<void>.value();

  static USBStatus _usbStatus = USBStatus.none;
  static bool _initialized = false;
  static bool _isScanning = false;
  static bool _isConnecting = false;
  static bool _isDisconnecting = false;
  static bool _isPrinting = false;
  static bool _hasScanned = false;
  static String _printerName = '';

  // ── Reconnect state ─────────────────────────────────────────────────────
  static Timer? _reconnectTimer;
  static int _reconnectAttempt = 0;
  static bool _isReconnecting = false;
  static bool _hadConnectionLoss = false;
  static bool _autoReconnectSuppressed = false;

  /// Currently selected paper size (`58 mm` or `80 mm`).
  static String optionPrinterType = '58 mm';

  /// Stream of human readable status changes.
  static Stream<String> get statusStream => _statusController.stream;

  /// Stream of connection-loss / reconnect lifecycle events.
  static Stream<PrinterConnectionEvent> get connectionEvents =>
      _eventController.stream;

  /// Whether USB printing is available on this platform.
  ///
  /// Android is the only platform the SDK supports USB on. iOS has no USB
  /// device-host API, and the other desktop/web targets have no transport in
  /// the underlying plugin.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Whether a USB printer is currently connected.
  static bool get isPrinterConnected => _usbStatus == USBStatus.connected;

  static bool get isScanning => _isScanning;
  static bool get isConnecting => _isConnecting;
  static bool get isReconnecting => _isReconnecting;
  static bool get isPrinting => _isPrinting;

  /// Name of the connected printer, or an empty string.
  static String get printerName => _printerName;

  /// Human readable status, e.g. `Connected` or `Searching for printer`.
  static String get printerStatus => _computeStatus();

  /// Printers discovered during the latest scan.
  static List<PrinterInfo> get availablePrinters =>
      List<PrinterInfo>.unmodifiable(_discovered.map(PrinterInfo.fromDevice));

  /// Printer persisted by the last successful [connect], if any.
  ///
  /// Call [init] first so the Hive box is available.
  static PrinterInfo? get savedPrinter {
    final String name = PrinterStorage.readString(
      PrinterStorageKeys.usbPrinterName,
    );
    final String vendorId = PrinterStorage.readString(
      PrinterStorageKeys.usbVendorId,
    );
    final String productId = PrinterStorage.readString(
      PrinterStorageKeys.usbProductId,
    );
    if (name.isEmpty && vendorId.isEmpty && productId.isEmpty) return null;
    return PrinterInfo(name: name, vendorId: vendorId, productId: productId);
  }

  static bool get hasSavedPrinter => savedPrinter != null;

  /// Loads (and caches) the ESC/POS capability profile.
  static Future<CapabilityProfile> loadCapabilityProfile() async {
    return _capabilityProfile ??= await CapabilityProfile.load();
  }

  /// Initializes the platform listeners and the ESC/POS profile.
  ///
  /// Idempotent and safe to call concurrently from app startup, the settings
  /// screen and print jobs. Calling it once during app startup (for example
  /// from `PrinterSdk.initialize`) is enough to keep detach detection active
  /// for the whole process.
  static Future<void> init() {
    return _initFuture ??= _initialize();
  }

  static Future<void> _initialize() async {
    if (_initialized) return;
    _initialized = true;

    // Never touch the platform plugin on a platform that cannot do USB.
    if (!isSupported) {
      _emit();
      return;
    }

    await PrinterStorage.ensureInitialized();

    if (_printerName.isEmpty) {
      _printerName = PrinterStorage.readString(
        PrinterStorageKeys.usbPrinterName,
      );
    }

    try {
      await loadCapabilityProfile();
    } catch (_) {
      // Printing surfaces a clearer error if the profile is unavailable.
    }

    try {
      _usbStatusSubscription ??= _manager.stateUSB.listen(_onUsbStatus);
    } catch (_) {
      // USB events are unavailable on unsupported platforms.
    }

    _emit();
  }

  /// Scans for USB printers.
  ///
  /// When [autoConnectSaved] is `true` (the default) the persisted printer is
  /// reconnected as soon as it is available. Scanning no longer disconnects an
  /// active printer, so it is safe to refresh the list while connected.
  static Future<List<PrinterInfo>> scan({bool autoConnectSaved = true}) async {
    if (!isSupported) {
      _hasScanned = true;
      _emit();
      return availablePrinters;
    }
    if (_isScanning) return availablePrinters;

    await init();

    _isScanning = true;
    _discovered.clear();
    _emit();

    try {
      final List<PrinterDevice> devices = await _discoverDevices();
      for (final PrinterDevice device in devices) {
        if (!_discovered.any(
          (PrinterDevice item) => _sameDevice(item, device),
        )) {
          _discovered.add(device);
        }
      }
    } finally {
      _isScanning = false;
      _hasScanned = true;
      _emit();
    }

    if (autoConnectSaved && !isPrinterConnected && hasSavedPrinter) {
      // An explicit scan is also how a host re-enables USB after switching
      // connection type, so it intentionally clears the manual-disconnect
      // suppression.
      await reconnectSaved();
    }

    return availablePrinters;
  }

  /// Connects to [printer] and persists it for future auto-reconnects.
  static Future<bool> connect(PrinterInfo printer) {
    if (!isSupported) return Future<bool>.value(false);

    // Coalesce concurrent attempts (manual tap + automatic retry).
    final Future<bool>? active = _connectOperation;
    if (active != null) return active;

    final Future<bool> operation = _connectInternal(printer);
    _connectOperation = operation;
    return operation.whenComplete(() => _connectOperation = null);
  }

  static Future<bool> _connectInternal(PrinterInfo printer) async {
    await init();

    if (isPrinterConnected && _printerName == printer.name) {
      _finishRecoveryIfNeeded();
      return true;
    }
    if (_isConnecting) return false;

    _isConnecting = true;
    _emit();

    try {
      final bool result = await _manager
          .connect(
            type: PrinterType.usb,
            model: UsbPrinterInput(
              name: printer.name,
              vendorId: printer.vendorId,
              productId: printer.productId,
            ),
          )
          .timeout(PrinterSdkConfig.connectTimeout);

      if (!result) return false;

      _usbStatus = USBStatus.connected;
      _printerName = printer.name;
      _autoReconnectSuppressed = false;
      _reconnectAttempt = 0;
      _cancelReconnectTimer();
      await _persistPrinter(printer);
      _finishRecoveryIfNeeded();
      _emit();
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    } finally {
      _isConnecting = false;
      _emit();
    }
  }

  /// Reconnects the persisted printer without user interaction.
  ///
  /// Returns `true` when the printer is connected. Used by the automatic retry
  /// loop and exposed for a "Reconnect" button.
  static Future<bool> reconnectSaved() async {
    final PrinterInfo? saved = savedPrinter;
    if (saved == null) return false;

    if (isPrinterConnected) {
      _finishRecoveryIfNeeded();
      return true;
    }

    _autoReconnectSuppressed = false;
    final bool connected = await connect(saved);
    if (connected) {
      _reconnectAttempt = 0;
      _finishRecoveryIfNeeded();
    }
    return connected;
  }

  /// Disconnects the active USB printer.
  ///
  /// When [clearSaved] is `true` (the default) the printer persisted for
  /// auto-reconnect is forgotten and automatic reconnects stop. Pass `false`
  /// when switching connection type so the host app can reconnect later.
  static Future<bool> disconnect({bool clearSaved = true}) async {
    _autoReconnectSuppressed = true;
    _hadConnectionLoss = false;
    _isReconnecting = false;
    _reconnectAttempt = 0;
    _cancelReconnectTimer();

    if (!isPrinterConnected) {
      _usbStatus = USBStatus.none;
      _printerName = '';
      if (clearSaved) await _clearSavedPrinter();
      _emit();
      return true;
    }

    _isDisconnecting = true;
    _emit();

    bool result = false;
    try {
      result = await _manager
          .disconnect(type: PrinterType.usb)
          .timeout(PrinterSdkConfig.connectTimeout);
    } on TimeoutException {
      result = false;
    } catch (_) {
      result = false;
    } finally {
      _usbStatus = USBStatus.none;
      _printerName = '';
      _isDisconnecting = false;
      if (clearSaved) await _clearSavedPrinter();
      _emit();
    }
    return result;
  }

  /// Whether the persisted printer is physically attached right now.
  ///
  /// Opens a short discovery pass; callers should not poll this faster than
  /// once per second.
  static Future<bool> isSavedPrinterAttached() async {
    if (!isSupported) return false;
    final PrinterInfo? saved = savedPrinter;
    if (saved == null) return false;

    if (_discovered.any((PrinterDevice device) => _matches(saved, device))) {
      return true;
    }
    if (_isScanning) return false;

    final List<PrinterDevice> devices = await _discoverDevices();
    return devices.any((PrinterDevice device) => _matches(saved, device));
  }

  /// Builds and prints the SDK test receipt.
  static Future<bool> testPrint() async {
    if (!isPrinterConnected) return false;

    final PrinterInfo saved =
        savedPrinter ??
        PrinterInfo(name: _printerName, vendorId: '', productId: '');
    final String name = saved.name.isNotEmpty ? saved.name : _printerName;

    final List<int> bytes = await buildTestReceipt(
      printerName: name,
      vendorId: saved.vendorId,
      productId: saved.productId,
    );
    return printBytes(bytes);
  }

  /// Builds the bytes of the test receipt without printing it.
  static Future<List<int>> buildTestReceipt({
    required String printerName,
    String vendorId = '',
    String productId = '',
  }) async {
    await init();
    final CapabilityProfile profile = await loadCapabilityProfile();
    final Generator generator = Generator(
      PrinterSdkConfig.is80mm(optionPrinterType)
          ? PaperSize.mm80
          : PaperSize.mm58,
      profile,
    );

    final DateTime now = DateTime.now();
    final String timestamp =
        '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}';

    List<int> bytes = <int>[];
    bytes += generator.reset();
    bytes += generator.text(
      'PRINT TEST',
      styles: const PosStyles(
        bold: true,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
        align: PosAlign.center,
      ),
    );
    bytes += generator.hr();
    bytes += generator.text(
      printerName,
      styles: const PosStyles(align: PosAlign.center),
    );
    if (vendorId.isNotEmpty) {
      bytes += generator.text('Vendor ID : $vendorId');
    }
    if (productId.isNotEmpty) {
      bytes += generator.text('Product ID : $productId');
    }
    bytes += generator.text('Paper : $optionPrinterType');
    bytes += generator.text('Printed : $timestamp');
    bytes += generator.feed(2);
    bytes += generator.cut();
    return bytes;
  }

  /// Sends raw ESC/POS bytes over USB.
  ///
  /// Jobs are serialized, so two receipts never interleave. When the first
  /// send fails, the link is treated as stale: the service reconnects the saved
  /// printer and retries the job once.
  static Future<bool> printBytes(
    List<int> bytes, {
    bool retryOnFailure = true,
  }) {
    if (bytes.isEmpty) return Future<bool>.value(false);
    return _enqueuePrint(() => _sendUsb(bytes, retryOnFailure: retryOnFailure));
  }

  static Future<bool> _sendUsb(
    List<int> bytes, {
    required bool retryOnFailure,
  }) async {
    await init();
    if (!isPrinterConnected) return false;

    _isPrinting = true;
    _emit();

    bool sent = false;
    try {
      sent = await _sendRawUsb(bytes);

      if (!sent && retryOnFailure) {
        _markLinkDown('The printer did not acknowledge the print job.');

        if (await reconnectSaved()) {
          sent = await _sendRawUsb(bytes);
        }
      }

      if (!sent) {
        _markLinkDown('The printer did not acknowledge the print job.');
      }
      return sent;
    } finally {
      _isPrinting = false;
      _emit();
    }
  }

  static Future<bool> _sendRawUsb(List<int> bytes) async {
    try {
      return await _manager
          .send(type: PrinterType.usb, bytes: bytes)
          .timeout(PrinterSdkConfig.printTimeout);
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _enqueuePrint(Future<bool> Function() job) {
    final Future<bool> result = _printChain.then((_) => job());
    // Keep the chain alive even when a job throws.
    _printChain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Legacy alias kept for host apps migrating from the old API.
  @Deprecated('Use testPrint() instead.')
  static Future<bool> demoPrint({
    required String printerName,
    required String printervendorId,
    required String printerproductId,
  }) {
    return testPrint();
  }

  /// Releases native listeners. The SDK is unusable afterwards until [init]
  /// is called again.
  static Future<void> dispose() async {
    _cancelReconnectTimer();
    await _usbStatusSubscription?.cancel();
    _usbStatusSubscription = null;
    _usbStatus = USBStatus.none;
    _printerName = '';
    _initialized = false;
    _initFuture = null;
    _isConnecting = false;
    _isDisconnecting = false;
    _isPrinting = false;
    _isScanning = false;
    _isReconnecting = false;
    _hadConnectionLoss = false;
    _autoReconnectSuppressed = false;
    _reconnectAttempt = 0;
    _connectOperation = null;
    _hasScanned = false;
    _discovered.clear();
    _emit();
  }

  // ---------------------------------------------------------------------------
  // Connection state
  // ---------------------------------------------------------------------------

  static void _onUsbStatus(USBStatus status) {
    // A device was plugged in. This is not a connection state: use it as an
    // immediate wake-up for the reconnect loop instead of waiting for the next
    // backoff slot.
    if (status == USBStatus.attached) {
      if (!isPrinterConnected &&
          !_isDisconnecting &&
          !_autoReconnectSuppressed &&
          savedPrinter != null) {
        _cancelReconnectTimer();
        _reconnectAttempt = 0;
        unawaited(_reconnectAfterAttach());
      }
      return;
    }

    final USBStatus previous = _usbStatus;
    if (previous == status) return;

    _usbStatus = status;

    if (status == USBStatus.connected) {
      _isConnecting = false;
      _reconnectAttempt = 0;
      _autoReconnectSuppressed = false;
      _finishRecoveryIfNeeded();
      _emit();
      return;
    }

    // Asking Android for USB permission emits `connecting`. That is a step
    // towards a connection, not a detach; treating it as one caused a loop of
    // permission requests.
    if (status == USBStatus.connecting) {
      _emit();
      return;
    }

    final bool unexpectedDetach =
        previous == USBStatus.connected &&
        !_isDisconnecting &&
        !_isConnecting &&
        !_autoReconnectSuppressed;

    _emit();

    if (unexpectedDetach) {
      _markLinkDown('The USB printer was disconnected.');
    }
  }

  /// Marks the link as down, emits one `disconnected` event and schedules the
  /// automatic reconnect loop.
  static void _markLinkDown(String reason) {
    if (_isDisconnecting || _autoReconnectSuppressed) return;

    _usbStatus = USBStatus.none;
    _reconnectAttempt = 0;

    if (!_hadConnectionLoss) {
      _hadConnectionLoss = true;
      _emitConnection(
        PrinterConnectionEvent(
          type: PrinterConnectionEventType.disconnected,
          message: reason,
        ),
      );
    }

    _emit();
    _scheduleReconnect();
  }

  static void _scheduleReconnect() {
    if (_isDisconnecting || _autoReconnectSuppressed || isPrinterConnected) {
      return;
    }

    _cancelReconnectTimer();

    if (!PrinterSdkConfig.autoReconnect) {
      _isReconnecting = false;
      _emitConnection(
        const PrinterConnectionEvent(
          type: PrinterConnectionEventType.reconnectFailed,
          message: 'Automatic reconnect is disabled.',
        ),
      );
      _emit();
      return;
    }

    final PrinterInfo? saved = savedPrinter;
    if (saved == null) {
      _isReconnecting = false;
      _emitConnection(
        const PrinterConnectionEvent(
          type: PrinterConnectionEventType.reconnectFailed,
          message: 'No saved printer to reconnect.',
        ),
      );
      _emit();
      return;
    }

    final List<Duration> delays = PrinterSdkConfig.reconnectDelays;
    if (delays.isEmpty) {
      _isReconnecting = false;
      _emitConnection(
        const PrinterConnectionEvent(
          type: PrinterConnectionEventType.reconnectFailed,
          message: 'Reconnect is not configured.',
        ),
      );
      _emit();
      return;
    }

    final int maxAttempts = PrinterSdkConfig.reconnectMaxAttempts;
    final bool exhausted = maxAttempts > 0 && _reconnectAttempt >= maxAttempts;

    if (exhausted) {
      _isReconnecting = false;
      _emitConnection(
        PrinterConnectionEvent(
          type: PrinterConnectionEventType.reconnectFailed,
          message:
              'Could not reconnect the printer. Check the cable and '
              'tap Reconnect.',
          attempt: _reconnectAttempt,
          maxAttempts: maxAttempts,
        ),
      );
      _emit();
      return;
    }

    final Duration delay =
        delays[_reconnectAttempt.clamp(0, delays.length - 1)];

    _isReconnecting = true;
    _emit();
    _emitConnection(
      PrinterConnectionEvent(
        type: PrinterConnectionEventType.reconnecting,
        message: 'Reconnecting to ${saved.name}…',
        attempt: _reconnectAttempt + 1,
        maxAttempts: maxAttempts,
        nextRetry: delay,
      ),
    );

    _reconnectTimer = Timer(delay, () async {
      if (_isDisconnecting || _autoReconnectSuppressed || isPrinterConnected) {
        return;
      }

      final bool connected = await reconnectSaved();
      if (connected) return;

      _reconnectAttempt++;
      _scheduleReconnect();
    });
  }

  static Future<void> _reconnectAfterAttach() async {
    _isReconnecting = true;
    _emit();

    final bool connected = await reconnectSaved();
    if (connected) return;

    _reconnectAttempt++;
    _scheduleReconnect();
  }

  static void _finishRecoveryIfNeeded() {
    _cancelReconnectTimer();
    _isReconnecting = false;

    if (!_hadConnectionLoss) return;

    _hadConnectionLoss = false;
    _reconnectAttempt = 0;
    _emitConnection(
      PrinterConnectionEvent(
        type: PrinterConnectionEventType.reconnected,
        message:
            '${_printerName.isEmpty ? 'Printer' : _printerName} '
            'reconnected.',
      ),
    );
    _emit();
  }

  static void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  static String _computeStatus() {
    if (_isDisconnecting) return PrinterStatus.disconnecting;
    if (_isConnecting || _usbStatus == USBStatus.connecting) {
      return PrinterStatus.connecting;
    }
    if (_isScanning) return PrinterStatus.scanning;
    if (_isReconnecting && !isPrinterConnected) {
      return PrinterStatus.reconnecting;
    }
    if (_isPrinting) return PrinterStatus.printing;
    if (_usbStatus == USBStatus.connected) return PrinterStatus.connected;
    if (_hasScanned && _discovered.isEmpty) return PrinterStatus.notFound;
    return PrinterStatus.notConnected;
  }

  static void _emit() {
    if (!_statusController.isClosed) {
      _statusController.add(_computeStatus());
    }
  }

  static void _emitConnection(PrinterConnectionEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  // ---------------------------------------------------------------------------
  // Discovery and persistence
  // ---------------------------------------------------------------------------

  static Future<List<PrinterDevice>> _discoverDevices() async {
    if (!isSupported) return const <PrinterDevice>[];

    final List<PrinterDevice> devices = <PrinterDevice>[];
    final Completer<void> done = Completer<void>();
    StreamSubscription<PrinterDevice>? subscription;

    try {
      subscription = _manager
          .discovery(type: PrinterType.usb)
          .listen(
            (PrinterDevice device) {
              if (!devices.any(
                (PrinterDevice item) => _sameDevice(item, device),
              )) {
                devices.add(device);
              }
            },
            onError: (Object _) {
              if (!done.isCompleted) done.complete();
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: false,
          );

      await done.future.timeout(PrinterSdkConfig.scanTimeout, onTimeout: () {});
    } catch (_) {
      // Discovery errors are not fatal; return whatever was found.
    } finally {
      await subscription?.cancel();
    }

    return devices;
  }

  static bool _sameDevice(PrinterDevice a, PrinterDevice b) {
    return a.name == b.name &&
        a.vendorId == b.vendorId &&
        a.productId == b.productId;
  }

  static bool _matches(PrinterInfo printer, PrinterDevice device) {
    if (printer.vendorId.isNotEmpty || printer.productId.isNotEmpty) {
      return printer.vendorId == device.vendorId &&
          printer.productId == device.productId;
    }
    return printer.name == device.name;
  }

  static Future<void> _persistPrinter(PrinterInfo printer) async {
    await PrinterStorage.write(
      PrinterStorageKeys.usbVendorId,
      printer.vendorId,
    );
    await PrinterStorage.write(
      PrinterStorageKeys.usbProductId,
      printer.productId,
    );
    await PrinterStorage.write(PrinterStorageKeys.usbPrinterName, printer.name);
  }

  static Future<void> _clearSavedPrinter() async {
    await PrinterStorage.delete(PrinterStorageKeys.usbVendorId);
    await PrinterStorage.delete(PrinterStorageKeys.usbProductId);
    await PrinterStorage.delete(PrinterStorageKeys.usbPrinterName);
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// Immutable description of a USB printer, used by the UI.
class PrinterInfo {
  const PrinterInfo({
    required this.name,
    required this.vendorId,
    required this.productId,
    this.address = '',
  });

  factory PrinterInfo.fromDevice(PrinterDevice device) {
    return PrinterInfo(
      name: device.name,
      vendorId: device.vendorId ?? '',
      productId: device.productId ?? '',
      address: device.address ?? '',
    );
  }

  final String name;
  final String vendorId;
  final String productId;
  final String address;

  /// Whether this record refers to the same physical printer as [other].
  ///
  /// Android exposes vendor/product ids, Windows usually only the printer name,
  /// so identity falls back to the name when the ids are missing.
  bool matches(PrinterInfo other) {
    if (vendorId.isNotEmpty || productId.isNotEmpty) {
      return vendorId == other.vendorId && productId == other.productId;
    }
    return name == other.name;
  }

  /// Human readable hardware identifier.
  String get hardwareId {
    if (vendorId.isEmpty && productId.isEmpty) return address;
    final String vendor = vendorId.isEmpty ? '—' : vendorId;
    final String product = productId.isEmpty ? '—' : productId;
    return 'VID $vendor • PID $product';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PrinterInfo &&
        other.name == name &&
        other.vendorId == vendorId &&
        other.productId == productId;
  }

  @override
  int get hashCode => Object.hash(name, vendorId, productId);
}

/// Human readable USB printer states.
abstract final class PrinterStatus {
  static const String connecting = 'Connecting';
  static const String disconnecting = 'Disconnecting';
  static const String connected = 'Connected';
  static const String notFound = 'Printer not found';
  static const String notConnected = 'Not connected';
  static const String reconnecting = 'Reconnecting';
  static const String scanning = 'Searching for printer';
  static const String printing = 'Printing';
}
