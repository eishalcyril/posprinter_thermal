import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_esc_pos_utils/flutter_esc_pos_utils.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/post_code.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal_windows.dart';

import '../printer_connection_event.dart';
import '../printer_sdk_config.dart';
import '../printer_storage.dart';

// Keep the lifecycle types available to callers importing this file directly.
export '../printer_connection_event.dart';

/// Human readable Bluetooth printer states.
abstract final class BluetoothPrinterStatus {
  static const String unsupported = 'Unsupported';
  static const String notConnected = 'Not connected';
  static const String connecting = 'Connecting';
  static const String disconnecting = 'Disconnecting';
  static const String connected = 'Connected';
  static const String reconnecting = 'Reconnecting';
  static const String scanning = 'Searching';
  static const String printing = 'Printing';
  static const String notFound = 'No paired printers found';
}

/// Stateless bridge to the platform Bluetooth printer APIs.
///
/// The class exposes plain static members on purpose: the SDK is used from
/// multiple screens and services and does not require an inherited widget or a
/// provider.
///
/// Connection lifecycle:
/// 1. [init] can be called once during app startup. It restores the persisted
///    printer, checks whether the platform still holds an open socket (which is
///    what happens after a Flutter hot restart) and, when the socket is gone,
///    starts the automatic reconnect loop.
/// 2. While a printer is connected a lightweight watchdog verifies the link, so
///    a printer that is switched off is noticed without a print job.
/// 3. A failed print is treated like a dropped link: the service reconnects the
///    saved printer and retries the job once.
/// 4. A manual [disconnect] stops the loop until the user connects again.
class BluetoothService {
  BluetoothService._();

  static final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  static final StreamController<PrinterConnectionEvent> _eventController =
      StreamController<PrinterConnectionEvent>.broadcast();
  static final _BluetoothLifecycleObserver _lifecycleObserver =
      _BluetoothLifecycleObserver();

  static Future<void>? _initFuture;
  static Future<bool>? _connectOperation;
  static Future<bool>? _statusCheck;
  static Future<void> _printChain = Future<void>.value();

  static Timer? _reconnectTimer;
  static Timer? _healthTimer;

  static bool _initialized = false;
  static bool _isScanning = false;
  static bool _isConnecting = false;
  static bool _isDisconnecting = false;
  static bool _isReconnecting = false;
  static bool _hadConnectionLoss = false;
  static bool _autoReconnectSuppressed = false;
  static bool _hasScanned = false;
  static int _reconnectAttempt = 0;

  /// Currently selected paper size (`58 mm` or `80 mm`).
  static String optionprinttype = '58 mm';

  /// Whether the underlying Bluetooth printer plugin supports this platform.
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  /// Whether the platform needs runtime Bluetooth permissions before scanning
  /// or connecting.
  ///
  /// Only Android 12+ does: the printer plugin requires `BLUETOOTH_SCAN` and
  /// `BLUETOOTH_CONNECT` to be granted at runtime. On iOS the equivalent
  /// `permission_handler` groups (`bluetoothScan`, `bluetoothConnect`) are not
  /// implemented and always report *denied*, so asking for them there would
  /// block scanning forever. iOS drives its own CoreBluetooth prompt from
  /// `NSBluetoothAlwaysUsageDescription` the first time the plugin scans or
  /// connects.
  static bool get requiresRuntimePermissions =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool bluetoothIsConnected = false;
  static String printerStatus = BluetoothPrinterStatus.notConnected;
  static String currenstMsg = '';
  static String connectedPrinterMac = '';
  static String connectedPrinterName = '';
  static bool connectionLoading = false;
  static bool isPrinting = false;
  static List<BluetoothInfo> bluetooth = <BluetoothInfo>[];
  static CapabilityProfile? profile;

  /// Stream of human readable status changes.
  static Stream<String> get statusStream => _statusController.stream;

  /// Stream of connection-loss / reconnect lifecycle events.
  static Stream<PrinterConnectionEvent> get connectionEvents =>
      _eventController.stream;

  static bool get isScanning => _isScanning;
  static bool get isConnecting => _isConnecting;
  static bool get isDisconnecting => _isDisconnecting;
  static bool get isReconnecting => _isReconnecting;

  /// Whether a printer was connected successfully at least once and persisted.
  static bool get hasSavedPrinter => savedPrinterMac.isNotEmpty;

  /// MAC address persisted by the last successful connection.
  static String get savedPrinterMac =>
      PrinterStorage.readString(PrinterStorageKeys.bluetoothMac).trim();

  /// Display name persisted by the last successful connection.
  static String get savedPrinterName {
    final String stored = PrinterStorage.readString(
      PrinterStorageKeys.bluetoothName,
    ).trim();
    if (stored.isNotEmpty) return stored;
    return savedPrinterMac;
  }

  /// Loads the ESC/POS capability profile (cached).
  static Future<CapabilityProfile> _loadProfile() async {
    return profile ??= await CapabilityProfile.load();
  }

  /// Builds a generator for the currently selected paper size.
  static Future<Generator> _generator() async {
    final CapabilityProfile capabilityProfile = await _loadProfile();
    return Generator(
      optionprinttype == '80 mm' ? PaperSize.mm80 : PaperSize.mm58,
      capabilityProfile,
    );
  }

  /// Initializes the persisted printer and starts connection monitoring.
  ///
  /// Idempotent and safe to call concurrently. Calling it once during app
  /// startup (for example from `PrinterSdk.initialize`) keeps reconnection
  /// active for the whole process and restores the printer after a hot restart.
  static Future<void> init() {
    return _initFuture ??= _initialize();
  }

  static Future<void> _initialize() async {
    if (_initialized) return;
    _initialized = true;

    await PrinterStorage.ensureInitialized();

    if (!isSupported) {
      printerStatus = BluetoothPrinterStatus.unsupported;
      _emit();
      return;
    }

    if (connectedPrinterMac.isEmpty) {
      connectedPrinterMac = savedPrinterMac;
    }
    if (connectedPrinterName.isEmpty) {
      connectedPrinterName = savedPrinterName;
    }

    try {
      WidgetsBinding.instance.addObserver(_lifecycleObserver);
    } catch (_) {
      // Lifecycle observation is optional (tests / headless platforms).
    }

    _emit();
    unawaited(_restoreConnection());
  }

  /// Reconnects the persisted printer without user interaction.
  ///
  /// Returns `true` when the printer is connected. Used by the automatic retry
  /// loop and exposed for a "Reconnect" button.
  static Future<bool> reconnectSaved() async {
    await init();
    final String mac = savedPrinterMac;
    if (mac.isEmpty) return false;

    if (bluetoothIsConnected) {
      _finishRecoveryIfNeeded();
      return true;
    }

    _autoReconnectSuppressed = false;
    final bool connected = await connectToBluetoothPrinter(
      mac: mac,
      deviceName: savedPrinterName,
    );
    if (connected) {
      _reconnectAttempt = 0;
      _finishRecoveryIfNeeded();
    }
    return connected;
  }

  /// Verifies the current link and reconnects the saved printer when needed.
  ///
  /// Safe to call before a print job or from a "Reconnect" action.
  static Future<bool> ensureConnected() async {
    await init();
    if (!isSupported) return false;
    if (await _checkConnection()) return true;
    if (_autoReconnectSuppressed) return false;
    return reconnectSaved();
  }

  /// Refreshes [bluetoothIsConnected] from the platform and returns it.
  static Future<bool> getCurrentConnectionStatus() async {
    await init();
    if (!isSupported) {
      bluetoothIsConnected = false;
      printerStatus = BluetoothPrinterStatus.unsupported;
      _emit();
      return false;
    }
    return _checkConnection();
  }

  /// Builds the bytes for the SDK test receipt.
  static Future<List<int>> demoPrintBluetooth({
    required String printerName,
  }) async {
    List<int> bytes = <int>[];
    final Generator generator = await _generator();
    final DateTime now = DateTime.now();

    bytes += generator.reset();
    bytes += generator.text(
      'PRINT TEST',
      styles: const PosStyles(
        height: PosTextSize.size2,
        width: PosTextSize.size2,
        align: PosAlign.center,
        bold: true,
      ),
    );
    bytes += generator.hr();
    bytes += generator.text(
      'Bluetooth connection OK',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.text('Printer: $printerName');
    bytes += generator.text('Paper: $optionprinttype');
    bytes += generator.text(
      'Printed: ${now.year}-${_two(now.month)}-${_two(now.day)} '
      '${_two(now.hour)}:${_two(now.minute)}',
    );
    bytes += generator.feed(2);
    bytes += generator.cut();
    return bytes;
  }

  /// Disconnects the active Bluetooth printer.
  ///
  /// When [clearSaved] is `true` (the default) the persisted printer is
  /// forgotten and automatic reconnects stop. Pass `false` when switching to
  /// USB so the host can reconnect later.
  static Future<bool> disconnect({bool clearSaved = true}) async {
    _autoReconnectSuppressed = true;
    _hadConnectionLoss = false;
    _isReconnecting = false;
    _reconnectAttempt = 0;
    _cancelReconnectTimer();
    _stopHealthWatch();

    if (!isSupported) {
      bluetoothIsConnected = false;
      connectedPrinterMac = '';
      connectedPrinterName = '';
      printerStatus = BluetoothPrinterStatus.unsupported;
      if (clearSaved) await _clearSavedPrinter();
      _emit();
      return false;
    }

    _isDisconnecting = true;
    printerStatus = BluetoothPrinterStatus.disconnecting;
    _emit();

    bool result = false;
    try {
      result = await PrintBluetoothThermal.disconnect.timeout(
        PrinterSdkConfig.connectTimeout,
      );
    } on TimeoutException {
      result = false;
    } catch (_) {
      result = false;
    } finally {
      bluetoothIsConnected = false;
      connectedPrinterMac = '';
      connectedPrinterName = '';
      printerStatus = BluetoothPrinterStatus.notConnected;
      _isDisconnecting = false;
      if (clearSaved) await _clearSavedPrinter();
      _emit();
    }
    return result;
  }

  /// Connects to a paired printer and persists it for future auto-reconnects.
  static Future<bool> connectToBluetoothPrinter({
    required String mac,
    required String deviceName,
    Function(bool isConnecting, bool isConnected, String printerStatus)?
    onStatusChanged,
  }) {
    final Future<bool> operation = _connectOperation ??= _connectInternal(
      mac: mac,
      deviceName: deviceName,
      onStatusChanged: onStatusChanged,
    );
    return operation.whenComplete(() {
      if (identical(_connectOperation, operation)) _connectOperation = null;
    });
  }

  static Future<bool> _connectInternal({
    required String mac,
    required String deviceName,
    Function(bool isConnecting, bool isConnected, String printerStatus)?
    onStatusChanged,
  }) async {
    await init();

    if (!isSupported) {
      printerStatus = BluetoothPrinterStatus.unsupported;
      _emit();
      return false;
    }

    if (bluetoothIsConnected && _sameMac(connectedPrinterMac, mac)) {
      _finishRecoveryIfNeeded();
      return true;
    }

    if (_isConnecting) return false;

    _isConnecting = true;
    connectionLoading = true;
    printerStatus = BluetoothPrinterStatus.connecting;
    _emit();
    onStatusChanged?.call(true, false, printerStatus);

    try {
      // The native plugin tears down an existing socket itself, so switching
      // printers does not need an explicit disconnect first.
      final bool result = await PrintBluetoothThermal.connect(
        macPrinterAddress: mac,
      ).timeout(PrinterSdkConfig.connectTimeout);

      if (!result) {
        printerStatus = 'Unable to connect';
        _emit();
        return false;
      }

      bluetoothIsConnected = true;
      connectedPrinterMac = mac;
      connectedPrinterName = deviceName;
      printerStatus = BluetoothPrinterStatus.connected;

      _reconnectAttempt = 0;
      _autoReconnectSuppressed = false;
      _cancelReconnectTimer();
      _stopHealthWatch();
      await _persistPrinter(mac, deviceName);
      _startHealthWatch();
      _finishRecoveryIfNeeded();
      _emit();
      return true;
    } on TimeoutException {
      printerStatus = 'Connection timed out';
      _emit();
      return false;
    } catch (e) {
      printerStatus = 'Exception :: ${e.toString()}';
      _emit();
      return false;
    } finally {
      _isConnecting = false;
      connectionLoading = false;
      onStatusChanged?.call(
        connectionLoading,
        bluetoothIsConnected,
        printerStatus,
      );
      _emit();
    }
  }

  /// Returns the list of paired Bluetooth devices.
  ///
  /// Duplicate records (some Android builds repeat the built-in printer) are
  /// removed. When [autoConnectSaved] is `true` the persisted printer is
  /// reconnected if it is not connected yet.
  static Future<List<BluetoothInfo>> getBluetoothDevices({
    bool autoConnectSaved = true,
    Function(bool isConnecting, bool isConnected, String printerStatus)?
    onStatusChanged,
  }) async {
    await init();

    if (!isSupported) {
      printerStatus = BluetoothPrinterStatus.unsupported;
      _emit();
      return <BluetoothInfo>[];
    }
    if (_isScanning) return bluetooth;

    _isScanning = true;
    connectionLoading = true;
    printerStatus = BluetoothPrinterStatus.scanning;
    _emit();
    onStatusChanged?.call(
      connectionLoading,
      bluetoothIsConnected,
      printerStatus,
    );

    try {
      final List<BluetoothInfo> listResult =
          await PrintBluetoothThermal.pairedBluetooths;
      final List<BluetoothInfo> unique = <BluetoothInfo>[];
      final Set<String> seen = <String>{};
      for (final BluetoothInfo device in listResult) {
        final String key = device.macAdress.trim().toUpperCase();
        if (key.isEmpty || !seen.add(key)) continue;
        unique.add(device);
      }
      bluetooth = unique;
      _hasScanned = true;
      if (unique.isEmpty) {
        printerStatus = BluetoothPrinterStatus.notFound;
      } else if (!bluetoothIsConnected) {
        printerStatus = 'Select a device to connect.';
      }
    } catch (e) {
      printerStatus = 'Exception :: ${e.toString()}';
    } finally {
      _isScanning = false;
      connectionLoading = false;
      onStatusChanged?.call(
        connectionLoading,
        bluetoothIsConnected,
        printerStatus,
      );
      _emit();
    }

    if (autoConnectSaved &&
        !bluetoothIsConnected &&
        savedPrinterMac.isNotEmpty) {
      // An explicit scan is how a host re-enables Bluetooth after switching
      // connection type, so it clears the manual-disconnect suppression.
      await reconnectSaved();
    }

    return bluetooth;
  }

  /// Sends raw ESC/POS bytes to the connected printer.
  ///
  /// Jobs are serialized so two receipts never interleave. A stale link is
  /// reconnected and the job is retried once.
  static Future<bool> printBytes({
    required List<int> bytesToPrint,
    Function(bool isPrinting, bool isConnected, String printerStatus)?
    onStatusChanged,
  }) {
    if (bytesToPrint.isEmpty) return Future<bool>.value(false);
    return _enqueuePrint(() => _sendBytes(bytesToPrint, onStatusChanged));
  }

  static Future<bool> _sendBytes(
    List<int> bytes,
    Function(bool isPrinting, bool isConnected, String printerStatus)?
    onStatusChanged,
  ) async {
    await init();

    if (!await ensureConnected()) {
      printerStatus = BluetoothPrinterStatus.notConnected;
      isPrinting = false;
      onStatusChanged?.call(false, false, printerStatus);
      _emit();
      return false;
    }

    isPrinting = true;
    printerStatus = BluetoothPrinterStatus.printing;
    onStatusChanged?.call(true, bluetoothIsConnected, printerStatus);
    _emit();

    bool sent = await _writeBytes(bytes);

    if (!sent) {
      _markLinkDown('The printer did not acknowledge the print job.');
      if (await reconnectSaved()) {
        sent = await _writeBytes(bytes);
      }
    }

    isPrinting = false;
    if (sent) {
      printerStatus = 'Print job done';
    } else {
      printerStatus = 'Print job failed';
    }
    onStatusChanged?.call(false, bluetoothIsConnected, printerStatus);
    _emit();
    return sent;
  }

  static Future<bool> _writeBytes(List<int> bytes) async {
    try {
      final bool result = defaultTargetPlatform == TargetPlatform.windows
          ? await PrintBluetoothThermalWindows.writeBytes(bytes: bytes)
          : await PrintBluetoothThermal.writeBytes(bytes);

      return await Future<bool>.value(
        result,
      ).timeout(PrinterSdkConfig.printTimeout, onTimeout: () => false);
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

  /// Builds a Windows-specific demo receipt.
  static Future<List<int>> testWindows() async {
    List<int> bytes = <int>[];

    bytes += PostCode.text(
      text: 'Size compressed',
      fontSize: FontSize.compressed,
    );
    bytes += PostCode.text(text: 'Size normal', fontSize: FontSize.normal);
    bytes += PostCode.text(text: 'Bold', bold: true);
    bytes += PostCode.text(text: 'Inverse', inverse: true);
    bytes += PostCode.text(text: 'AlignPos right', align: AlignPos.right);
    bytes += PostCode.text(text: 'Size big', fontSize: FontSize.big);
    bytes += PostCode.enter();

    bytes += PostCode.row(
      texts: <String>['PRODUCT', 'VALUE'],
      proportions: <int>[60, 40],
      fontSize: FontSize.compressed,
    );
    for (int i = 0; i < 3; i++) {
      bytes += PostCode.row(
        texts: <String>['Item $i', '$i,00'],
        proportions: <int>[60, 40],
        fontSize: FontSize.compressed,
      );
    }

    bytes += PostCode.line();
    bytes += PostCode.barcode(barcodeData: '123456789');
    bytes += PostCode.qr('123456789');
    bytes += PostCode.enter(nEnter: 5);

    return bytes;
  }

  /// Prints a base64 encoded raw ESC/POS payload.
  static Future<bool> printOrderBytes({
    required dynamic bytesToPrint,
    Function(bool isPrinting, bool isConnected, String printerStatus)?
    onStatusChanged,
  }) async {
    if (bytesToPrint is! String) {
      printerStatus = 'Invalid print payload';
      _emit();
      return false;
    }

    final List<int> imageData = await compute<String, List<int>>(
      _decodeBase64InBackground,
      bytesToPrint,
    );
    final Generator generator = await _generator();
    final List<int> ticket = <int>[...generator.rawBytes(imageData)];

    return printBytes(bytesToPrint: ticket, onStatusChanged: onStatusChanged);
  }

  /// Releases timers and platform listeners. The service is unusable
  /// afterwards until [init] is called again.
  static Future<void> dispose() async {
    _cancelReconnectTimer();
    _stopHealthWatch();
    try {
      WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    } catch (_) {
      // No binding (unit tests) - nothing to release.
    }

    bluetoothIsConnected = false;
    connectedPrinterMac = '';
    connectedPrinterName = '';
    printerStatus = BluetoothPrinterStatus.notConnected;
    connectionLoading = false;
    isPrinting = false;
    _initialized = false;
    _initFuture = null;
    _connectOperation = null;
    _statusCheck = null;
    _isScanning = false;
    _isConnecting = false;
    _isDisconnecting = false;
    _isReconnecting = false;
    _hadConnectionLoss = false;
    _autoReconnectSuppressed = false;
    _hasScanned = false;
    _reconnectAttempt = 0;
    _emit();
  }

  // ---------------------------------------------------------------------------
  // Connection state
  // ---------------------------------------------------------------------------

  static Future<void> _restoreConnection() async {
    if (!isSupported ||
        _isConnecting ||
        _isReconnecting ||
        bluetoothIsConnected) {
      return;
    }

    final String mac = savedPrinterMac;
    if (mac.isEmpty || _autoReconnectSuppressed) return;

    if (!await _hasBluetoothPermission()) {
      // The settings screen requests the permission; it reconnects afterwards.
      return;
    }

    bool enabled = false;
    try {
      enabled = await PrintBluetoothThermal.bluetoothEnabled;
    } catch (_) {
      enabled = false;
    }
    if (!enabled) {
      _emitConnection(
        const PrinterConnectionEvent(
          type: PrinterConnectionEventType.reconnectFailed,
          message: 'Bluetooth is off. Turn it on to reconnect the printer.',
        ),
      );
      return;
    }

    // After a Flutter hot restart the native plugin usually keeps the socket
    // open. Verify it before reconnecting, so we never open a second socket.
    if (await _checkConnection()) return;

    _scheduleReconnect(
      immediate: true,
      reason: 'Restoring the saved Bluetooth printer.',
    );
  }

  static Future<bool> _checkConnection() {
    final Future<bool>? active = _statusCheck;
    if (active != null) return active;

    final Future<bool> check = _performStatusCheck();
    _statusCheck = check;
    return check.whenComplete(() {
      if (identical(_statusCheck, check)) _statusCheck = null;
    });
  }

  static Future<bool> _performStatusCheck() async {
    bool connected = false;
    try {
      connected =
          await PrintBluetoothThermal.connectionStatus.timeout(
            const Duration(seconds: 5),
            onTimeout: () => false,
          ) &&
          isSupported;
    } catch (_) {
      connected = false;
    }

    final bool previous = bluetoothIsConnected;

    if (connected) {
      bluetoothIsConnected = true;
      if (connectedPrinterMac.isEmpty) connectedPrinterMac = savedPrinterMac;
      if (connectedPrinterName.isEmpty) {
        connectedPrinterName = savedPrinterName;
      }
      printerStatus = BluetoothPrinterStatus.connected;
      _reconnectAttempt = 0;
      _startHealthWatch();
      _finishRecoveryIfNeeded();
      _emit();
      return true;
    }

    bluetoothIsConnected = false;

    if (previous &&
        !_autoReconnectSuppressed &&
        !_isDisconnecting &&
        !_isConnecting) {
      _markLinkDown('The Bluetooth printer is no longer reachable.');
      return false;
    }

    if (!_isConnecting && !_isDisconnecting && !_isReconnecting) {
      if (savedPrinterMac.isNotEmpty) {
        printerStatus = 'Disconnected';
      } else if (!_hasScanned) {
        printerStatus = BluetoothPrinterStatus.notConnected;
      }
    }
    _emit();
    return false;
  }

  /// Marks the link as down, emits one `disconnected` event and schedules the
  /// automatic reconnect loop.
  static void _markLinkDown(String reason) {
    if (_isDisconnecting || _autoReconnectSuppressed) return;

    _stopHealthWatch();
    _cancelReconnectTimer();
    bluetoothIsConnected = false;
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

  static void _scheduleReconnect({bool immediate = false, String? reason}) {
    if (_isDisconnecting || _autoReconnectSuppressed || bluetoothIsConnected) {
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

    final String mac = savedPrinterMac;
    if (mac.isEmpty) {
      _isReconnecting = false;
      _emitConnection(
        const PrinterConnectionEvent(
          type: PrinterConnectionEventType.reconnectFailed,
          message: 'No saved Bluetooth printer to reconnect.',
        ),
      );
      _emit();
      return;
    }

    final List<Duration> delays = PrinterSdkConfig.reconnectDelays;
    final int maxAttempts = PrinterSdkConfig.reconnectMaxAttempts;
    final bool exhausted = maxAttempts > 0 && _reconnectAttempt >= maxAttempts;

    if (exhausted) {
      _isReconnecting = false;
      _emitConnection(
        PrinterConnectionEvent(
          type: PrinterConnectionEventType.reconnectFailed,
          message:
              'Could not reconnect the printer. Keep it powered on and '
              'tap Reconnect.',
          attempt: _reconnectAttempt,
          maxAttempts: maxAttempts,
        ),
      );
      _emit();
      return;
    }

    final Duration delay = immediate || delays.isEmpty
        ? Duration.zero
        : delays[_reconnectAttempt.clamp(0, delays.length - 1)];

    _isReconnecting = true;
    printerStatus = BluetoothPrinterStatus.reconnecting;
    _emit();
    _emitConnection(
      PrinterConnectionEvent(
        type: PrinterConnectionEventType.reconnecting,
        message:
            reason ??
            'Reconnecting to ${savedPrinterName.isEmpty ? 'the printer' : savedPrinterName}…',
        attempt: _reconnectAttempt + 1,
        maxAttempts: maxAttempts,
        nextRetry: delay,
      ),
    );

    _reconnectTimer = Timer(delay, () async {
      if (_isDisconnecting ||
          _autoReconnectSuppressed ||
          bluetoothIsConnected) {
        return;
      }

      final bool connected = await connectToBluetoothPrinter(
        mac: mac,
        deviceName: savedPrinterName,
      );
      if (connected) return;

      _reconnectAttempt++;
      _scheduleReconnect();
    });
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
            '${connectedPrinterName.isEmpty ? 'Printer' : connectedPrinterName} '
            'reconnected.',
      ),
    );
    _emit();
  }

  static void _startHealthWatch() {
    final Duration interval = PrinterSdkConfig.bluetoothHealthCheckInterval;
    if (interval <= Duration.zero || _healthTimer != null) return;

    _healthTimer = Timer.periodic(interval, (_) {
      if (!_initialized ||
          !isSupported ||
          !bluetoothIsConnected ||
          _isConnecting ||
          _isDisconnecting ||
          isPrinting ||
          _autoReconnectSuppressed) {
        return;
      }
      unawaited(_checkConnection());
    });
  }

  static void _stopHealthWatch() {
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  static void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  static void _onAppResumed() {
    if (!_initialized || !isSupported) return;
    if (bluetoothIsConnected) {
      unawaited(_checkConnection());
      return;
    }
    if (_autoReconnectSuppressed || _isReconnecting) return;
    if (savedPrinterMac.isNotEmpty) {
      unawaited(_restoreConnection());
    }
  }

  static void _emit() {
    if (!_statusController.isClosed) {
      _statusController.add(printerStatus);
    }
  }

  static void _emitConnection(PrinterConnectionEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  // ---------------------------------------------------------------------------
  // Persistence and helpers
  // ---------------------------------------------------------------------------

  static Future<void> _persistPrinter(String mac, String name) async {
    await PrinterStorage.write(PrinterStorageKeys.bluetoothMac, mac);
    await PrinterStorage.write(PrinterStorageKeys.bluetoothName, name);
  }

  static Future<void> _clearSavedPrinter() async {
    await PrinterStorage.delete(PrinterStorageKeys.bluetoothMac);
    await PrinterStorage.delete(PrinterStorageKeys.bluetoothName);
  }

  static bool _sameMac(String a, String b) {
    return a.trim().toUpperCase() == b.trim().toUpperCase();
  }

  static Future<bool> _hasBluetoothPermission() async {
    if (!requiresRuntimePermissions) return true;

    try {
      final List<PermissionStatus> statuses = await Future.wait(
        <Future<PermissionStatus>>[
          Permission.bluetoothConnect.status,
          Permission.bluetoothScan.status,
        ],
      );
      // On Android 11 and below permission_handler reports these groups as
      // granted automatically; on Android 12+ both runtime permissions are
      // required by the printer plugin.
      return statuses.every((PermissionStatus status) => status.isGranted);
    } catch (_) {
      // Permission APIs can be unavailable on desktop or in tests.
      return true;
    }
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// Checks the link again when the app returns to the foreground (Bluetooth was
/// re-enabled, the printer was switched on, ...).
class _BluetoothLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      BluetoothService._onAppResumed();
    }
  }
}

// This method is written outside any class because [compute] runs it in an
// isolate.
List<int> _decodeBase64InBackground(String base64String) {
  final String padded = base64.normalize(base64String);
  return base64Decode(padded);
}
