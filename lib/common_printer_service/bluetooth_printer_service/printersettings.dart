import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import '../global_loader_controller.dart';
import '../printer_sdk_config.dart';
import '../printer_storage.dart';
import '../printer_ui.dart';
import '../printer_widgets.dart';
import 'bluetooth_printer_service.dart';

/// Premium Bluetooth printer connection screen.
///
/// Drop it anywhere inside a [Scaffold]; it fills the available height and
/// keeps its own state. The screen is a thin view over [BluetoothService]:
/// - the service owns connecting and automatic reconnection;
/// - the screen mirrors its status and forwards user intents;
/// - reconnection keeps running when the screen is closed, because the service
///   initializes once per process from `PrinterSdk.initialize`.
class BluetoothPrinterSettings extends StatefulWidget {
  const BluetoothPrinterSettings({super.key, this.changedBluetoothStatus});

  /// Invoked whenever the connection state changes.
  final VoidCallback? changedBluetoothStatus;

  @override
  State<BluetoothPrinterSettings> createState() =>
      _BluetoothPrinterSettingsState();
}

class _BluetoothPrinterSettingsState extends State<BluetoothPrinterSettings> {
  StreamSubscription<String>? _statusSubscription;
  StreamSubscription<PrinterConnectionEvent>? _eventSubscription;

  List<BluetoothInfo> _items = <BluetoothInfo>[];
  String _status = BluetoothService.printerStatus;
  String _savedMac = '';
  String _savedName = '';
  String _connectedMac = '';
  String _connectedName = '';
  String _platformVersion = '';
  int _batteryLevel = 0;
  bool _isBluetoothEnabled = false;
  bool _isPermissionGranted = false;
  bool _busy = false;
  bool _hostNotifyScheduled = false;
  PrinterConnectionEvent? _lastEvent;

  @override
  void initState() {
    super.initState();

    _statusSubscription = BluetoothService.statusStream.listen(_onStatus);
    _eventSubscription = BluetoothService.connectionEvents.listen(_onEvent);

    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _eventSubscription?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _bootstrap() async {
    await PrinterStorage.ensureInitialized();
    if (!mounted) return;

    setState(() {
      _savedMac = BluetoothService.savedPrinterMac;
      _savedName = BluetoothService.savedPrinterName;
    });

    await _ensurePermissions();
    if (!mounted) return;

    await BluetoothService.init();
    if (!mounted) return;

    setState(() {
      _items = BluetoothService.bluetooth;
      _status = BluetoothService.printerStatus;
      _syncPrinterIdentity();
    });

    await initPlatformState(notify: false);
    if (!mounted || !BluetoothService.isSupported) return;

    // Restores the saved printer and reconnects it after a hot restart.
    await _scan(autoConnectSaved: true, notify: false);
  }

  /// Notifies the host after the current frame.
  ///
  /// Status events can arrive while the parent scaffold is building or laying
  /// out; coalescing them avoids calling `setState` on the host mid-layout.
  void _notifyHost() {
    if (_hostNotifyScheduled) return;
    _hostNotifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hostNotifyScheduled = false;
      if (mounted) widget.changedBluetoothStatus?.call();
    });
    if (!WidgetsBinding.instance.hasScheduledFrame) {
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  void _syncPrinterIdentity() {
    _connectedMac = BluetoothService.connectedPrinterMac;
    _connectedName = BluetoothService.connectedPrinterName;
    _savedMac = BluetoothService.savedPrinterMac;
    _savedName = BluetoothService.savedPrinterName;
  }

  void _onStatus(String status) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _items = BluetoothService.bluetooth;
      _syncPrinterIdentity();
    });
    _notifyHost();
  }

  void _onEvent(PrinterConnectionEvent event) {
    if (!mounted) return;

    final PrinterConnectionEventType previous =
        _lastEvent?.type ?? PrinterConnectionEventType.reconnected;
    setState(() {
      _lastEvent = event;
      _syncPrinterIdentity();
    });

    if (event.type == PrinterConnectionEventType.reconnected &&
        previous != PrinterConnectionEventType.reconnected) {
      showPrinterToast(event.message, type: PrinterToastType.success);
    } else if (event.type == PrinterConnectionEventType.reconnectFailed) {
      showPrinterToast(event.message, type: PrinterToastType.error);
    }

    _notifyHost();
  }

  // ---------------------------------------------------------------------------
  // Permissions and platform state
  // ---------------------------------------------------------------------------

  Future<void> _ensurePermissions() async {
    if (!BluetoothService.isSupported) {
      if (!mounted) return;
      setState(() => _isPermissionGranted = false);
      return;
    }

    // iOS (and Windows) have no runtime Bluetooth permission group. Asking
    // permission_handler for `bluetoothScan`/`bluetoothConnect` there always
    // reports denied, which used to block the search button. iOS shows its own
    // CoreBluetooth prompt from NSBluetoothAlwaysUsageDescription when the
    // plugin first scans or connects.
    if (!BluetoothService.requiresRuntimePermissions) {
      if (!mounted) return;
      setState(() => _isPermissionGranted = true);
      return;
    }

    bool granted = false;
    try {
      granted = await _requestBluetoothPermissions();
    } catch (_) {
      // Permission APIs are not available on every desktop/test platform.
      granted = false;
    }
    if (!mounted) return;

    setState(() => _isPermissionGranted = granted);
    if (!granted) {
      showPrinterToast(
        'Bluetooth permissions are required to discover and connect the '
        'printer.',
        type: PrinterToastType.error,
      );
    }
  }

  /// Requests the Android 12+ runtime permissions the printer plugin needs.
  ///
  /// Never call this on iOS: `permission_handler` does not implement these
  /// groups there and reports them permanently denied. See
  /// [BluetoothService.requiresRuntimePermissions].
  Future<bool> _requestBluetoothPermissions() async {
    // On Android 11 and below permission_handler reports these groups as
    // granted automatically; on Android 12+ they map to the two runtime
    // permissions required by the printer plugin.
    final PermissionStatus scan = await Permission.bluetoothScan.status;
    final PermissionStatus connect = await Permission.bluetoothConnect.status;
    if (scan.isGranted && connect.isGranted) return true;

    final Map<Permission, PermissionStatus> statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    return statuses[Permission.bluetoothScan]?.isGranted == true &&
        statuses[Permission.bluetoothConnect]?.isGranted == true;
  }

  Future<void> checkConnectionStatus() async {
    await BluetoothService.getCurrentConnectionStatus();
    if (!mounted) return;
    setState(_syncPrinterIdentity);
  }

  /// Refreshes the Bluetooth adapter, battery and platform information.
  ///
  /// Pass [notify] `false` during bootstrap to avoid a burst of toasts on every
  /// screen open or hot restart.
  Future<void> initPlatformState({bool notify = true}) async {
    if (!BluetoothService.isSupported) {
      if (!mounted) return;
      setState(() {
        _platformVersion = BluetoothPrinterStatus.unsupported;
        _batteryLevel = 0;
        _isBluetoothEnabled = false;
        _isPermissionGranted = false;
      });
      if (notify) {
        showPrinterToast(
          'Bluetooth printing is not supported on this platform.',
          type: PrinterToastType.error,
        );
      }
      return;
    }

    await BluetoothService.getCurrentConnectionStatus();
    if (!mounted) return;

    String platformVersion = 'Unavailable';
    int battery = 0;
    bool bluetoothEnabled = false;
    bool permissionGranted = false;

    try {
      platformVersion = await PrintBluetoothThermal.platformVersion;
      // The plugin's battery getter reports the *host device's* battery and,
      // on iOS, raises `UNAVAILABLE` ("Nivel de batería no disponible")
      // whenever UIDevice cannot expose it — which is the normal case on iOS
      // and in the simulator, and it prints that failure to the console.
      // Ask on Android only; elsewhere the card shows "—" instead.
      if (defaultTargetPlatform == TargetPlatform.android) {
        battery = await PrintBluetoothThermal.batteryLevel;
      }
      if (_isPermissionGranted) {
        // Do not call the plugin's permission getter when permission_handler
        // already reported a denial: that getter requests the permission again
        // and would show a second system dialog.
        permissionGranted =
            await PrintBluetoothThermal.isPermissionBluetoothGranted;
        bluetoothEnabled = await PrintBluetoothThermal.bluetoothEnabled;
      }
    } catch (_) {
      // MissingPluginException on desktop/web, PlatformException on mobile.
    }

    if (!mounted) return;
    setState(() {
      _platformVersion = platformVersion;
      _batteryLevel = battery;
      _isBluetoothEnabled = bluetoothEnabled;
      _isPermissionGranted = permissionGranted;
      _items = BluetoothService.bluetooth;
      _status = BluetoothService.printerStatus;
      _syncPrinterIdentity();
    });

    if (!notify) return;
    showPrinterToast(
      bluetoothEnabled
          ? 'Bluetooth is on. Search for your printer.'
          : 'Bluetooth is off. Enable it in system settings.',
      type: bluetoothEnabled ? PrinterToastType.info : PrinterToastType.error,
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _scan({bool autoConnectSaved = true, bool notify = true}) async {
    if (_busy || BluetoothService.isScanning) return;

    if (BluetoothService.isSupported && !_isPermissionGranted) {
      await _ensurePermissions();
      if (!mounted || !_isPermissionGranted) return;
    }

    setState(() => _busy = true);
    try {
      final List<BluetoothInfo> result =
          await BluetoothService.getBluetoothDevices(
            autoConnectSaved: autoConnectSaved,
            onStatusChanged:
                (bool isConnecting, bool isConnected, String printerStatus) {
                  if (!mounted) return;
                  setState(() => _status = printerStatus);
                },
          );

      if (!mounted) return;
      setState(() {
        _items = result;
        _status = BluetoothService.printerStatus;
        _syncPrinterIdentity();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted || !notify) return;

    if (BluetoothService.bluetoothIsConnected) {
      showPrinterToast(
        'Connected to '
        '${BluetoothService.connectedPrinterName.isEmpty ? 'the printer' : BluetoothService.connectedPrinterName}.',
        type: PrinterToastType.success,
      );
    } else if (_items.isEmpty) {
      showPrinterToast(
        'No paired Bluetooth printer found. Pair it in system settings first.',
        type: PrinterToastType.error,
      );
    } else {
      showPrinterToast(
        'Found ${_items.length} paired device(s). Tap one to connect.',
        type: PrinterToastType.success,
      );
    }
    _notifyHost();
  }

  Future<void> _handleDeviceTap(BluetoothInfo device, bool isConnected) async {
    final String mac = device.macAdress;
    final String deviceName = device.name;

    if (BluetoothService.bluetoothIsConnected) {
      if (isConnected) {
        showPrinterToast(
          'Already connected to $deviceName.',
          type: PrinterToastType.info,
        );
        return;
      }

      final String current = BluetoothService.connectedPrinterName.isEmpty
          ? 'the current printer'
          : BluetoothService.connectedPrinterName;
      final bool shouldSwitch = await showPrinterConfirmDialog(
        context,
        title: 'Switch printer?',
        message: 'Disconnect from $current and connect to $deviceName instead?',
        confirmLabel: 'Switch',
        destructive: true,
      );
      if (!shouldSwitch || !mounted) return;

      // Preserve the saved record so the old printer can be restored if the
      // new connection fails.
      await BluetoothService.disconnect(clearSaved: false);
      if (!mounted) return;
    }

    await _connect(mac, deviceName);
  }

  Future<void> _connect(String mac, String deviceName) async {
    if (_busy) return;

    setState(() => _busy = true);
    final bool result = await BluetoothService.connectToBluetoothPrinter(
      mac: mac,
      deviceName: deviceName,
      onStatusChanged:
          (bool isConnecting, bool isConnected, String printerStatus) {
            if (!mounted) return;
            setState(() => _status = printerStatus);
          },
    );
    if (!mounted) return;

    setState(() {
      _busy = false;
      _status = BluetoothService.printerStatus;
      _syncPrinterIdentity();
    });

    showPrinterToast(
      result
          ? 'Connected to $deviceName.'
          : 'Could not connect to $deviceName. Make sure the printer is on and '
                'paired, then try again.',
      type: result ? PrinterToastType.success : PrinterToastType.error,
    );
    _notifyHost();
  }

  Future<void> _reconnect() async {
    if (_busy) return;

    if (!BluetoothService.hasSavedPrinter) {
      showPrinterToast(
        'No saved Bluetooth printer. Search and connect one first.',
        type: PrinterToastType.error,
      );
      return;
    }

    setState(() => _busy = true);
    final bool result = await BluetoothService.reconnectSaved();
    if (!mounted) return;

    setState(() {
      _busy = false;
      _status = BluetoothService.printerStatus;
      _syncPrinterIdentity();
    });

    if (result) {
      final String name = _savedName.isEmpty ? 'the printer' : _savedName;
      showPrinterToast('Reconnected to $name.', type: PrinterToastType.success);
    } else {
      showPrinterToast(
        'Reconnect failed. Keep the printer powered on and try again.',
        type: PrinterToastType.error,
      );
    }
    _notifyHost();
  }

  Future<void> _disconnect() async {
    if (_busy) return;

    setState(() => _busy = true);
    await BluetoothService.disconnect();
    if (!mounted) return;

    setState(() {
      _busy = false;
      _status = BluetoothService.printerStatus;
      _lastEvent = null;
      _syncPrinterIdentity();
    });

    showPrinterToast(
      'Bluetooth printer disconnected.',
      type: PrinterToastType.info,
    );
    _notifyHost();
  }

  Future<void> _printTest() async {
    if (!BluetoothService.bluetoothIsConnected || BluetoothService.isPrinting) {
      showPrinterToast(
        'Connect a Bluetooth printer before printing.',
        type: PrinterToastType.error,
      );
      return;
    }

    if (PrinterSdkConfig.showPrintLoader && mounted) {
      GlobalLoaderController().show(context);
    }

    bool result = false;
    try {
      final String name = _connectedName.isNotEmpty
          ? _connectedName
          : (_savedName.isNotEmpty ? _savedName : _connectedMac);
      final List<int> bytes = await BluetoothService.demoPrintBluetooth(
        printerName: name,
      );
      result = await BluetoothService.printBytes(
        bytesToPrint: bytes,
        onStatusChanged:
            (bool isPrinting, bool isConnected, String printerStatus) {
              if (!mounted) return;
              setState(() => _status = printerStatus);
            },
      );
    } catch (_) {
      result = false;
    } finally {
      GlobalLoaderController().hide();
    }

    if (!mounted) return;
    setState(() {
      _status = BluetoothService.printerStatus;
      _syncPrinterIdentity();
    });
    showPrinterToast(
      result
          ? 'Test print sent to ${_connectedName.isEmpty ? 'the printer' : _connectedName}.'
          : 'Print could not be sent. Reconnect the printer and retry.',
      type: result ? PrinterToastType.success : PrinterToastType.error,
    );
    _notifyHost();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  List<BluetoothInfo> get _displayItems {
    final List<BluetoothInfo> list = <BluetoothInfo>[];
    final Set<String> seen = <String>{};

    void add(String name, String mac) {
      final String key = mac.trim().toUpperCase();
      if (key.isEmpty || !seen.add(key)) return;
      list.add(BluetoothInfo(name: name, macAdress: mac));
    }

    if (BluetoothService.bluetoothIsConnected && _connectedMac.isNotEmpty) {
      add(
        _connectedName.isEmpty ? 'Connected printer' : _connectedName,
        _connectedMac,
      );
    }
    if (_savedMac.isNotEmpty) {
      add(_savedName.isEmpty ? 'Saved printer' : _savedName, _savedMac);
    }
    for (final BluetoothInfo device in _items) {
      add(device.name, device.macAdress);
    }

    return list;
  }

  @override
  Widget build(BuildContext context) {
    // Remember the host app's root overlay so service callbacks can show
    // toasts without a BuildContext.
    PrinterOverlay.attach(context);

    if (!BluetoothService.isSupported) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          decoration: BoxDecoration(
            color: PrinterSdkConfig.surfaceColor,
            borderRadius: BorderRadius.circular(PrinterSdkConfig.borderRadius),
            border: Border.all(color: PrinterSdkConfig.borderColor),
          ),
          child: const PrinterEmptyState(
            icon: Icons.bluetooth_disabled_rounded,
            title: 'Bluetooth printing is not available here',
            message:
                'Bluetooth thermal printers can be used on Android, iOS and '
                'Windows. Switch to USB on this device.',
          ),
        ),
      );
    }

    final Size screenSize = MediaQuery.sizeOf(context);
    final bool isCompact = screenSize.width < 400 || screenSize.height < 700;

    final bool connected = BluetoothService.bluetoothIsConnected;
    final bool scanning = BluetoothService.isScanning;
    final bool connecting = BluetoothService.isConnecting;
    final bool reconnecting = BluetoothService.isReconnecting;
    final bool printing = BluetoothService.isPrinting;
    final bool busy = _busy || scanning || connecting || printing;
    final List<BluetoothInfo> items = _displayItems;
    final bool hasSaved = _savedMac.isNotEmpty;

    final String printerName = connected
        ? (_connectedName.isEmpty ? 'Bluetooth printer' : _connectedName)
        : hasSaved
        ? (_savedName.isEmpty ? 'Saved printer' : _savedName)
        : 'Bluetooth thermal printer';

    return ListView(
      padding: EdgeInsets.fromLTRB(
        isCompact ? 8 : 12,
        8,
        isCompact ? 8 : 12,
        12,
      ),
      children: <Widget>[
        PrinterHeroCard(
          icon: connected
              ? Icons.bluetooth_connected_rounded
              : Icons.bluetooth_rounded,
          title: printerName,
          subtitle: _heroSubtitle(connected, scanning, reconnecting),
          statusLabel: _heroStatusLabel(connected, scanning),
          statusColor: connected
              ? PrinterSdkConfig.successColor
              : reconnecting || connecting || scanning
              ? PrinterSdkConfig.warningColor
              : PrinterSdkConfig.textSecondaryColor,
          accentColor: PrinterSdkConfig.bluetoothColor,
          accentDarkColor: PrinterSdkConfig.bluetoothDarkColor,
          busy: scanning || connecting || reconnecting,
        ),
        SizedBox(height: isCompact ? 10 : 12),
        _StatusGrid(
          compact: isCompact,
          isBluetoothEnabled: _isBluetoothEnabled,
          isPermissionGranted: _isPermissionGranted,
          batteryLevel: _batteryLevel,
          platformVersion: _platformVersion,
          connected: connected,
          reconnecting: reconnecting || connecting,
        ),
        if (!connected && hasSaved) ...<Widget>[
          SizedBox(height: isCompact ? 10 : 12),
          _ReconnectBanner(
            savedPrinterName: _savedName.isEmpty ? 'Saved printer' : _savedName,
            reconnecting: reconnecting,
            event: _lastEvent,
            canRetry: !busy,
            onRetry: _reconnect,
          ),
        ],
        SizedBox(height: isCompact ? 10 : 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: <Widget>[
            PrinterActionButton(
              icon: Icons.search_rounded,
              label: scanning ? 'Searching' : 'Search',
              onPressed: busy && !scanning ? null : () => _scan(),
              tone: connected
                  ? PrinterActionTone.neutral
                  : PrinterActionTone.primary,
              accentColor: PrinterSdkConfig.bluetoothColor,
              isLoading: scanning,
            ),
            PrinterActionButton(
              icon: Icons.print_rounded,
              label: 'Test print',
              onPressed: connected && !busy ? _printTest : null,
              tone: connected
                  ? PrinterActionTone.primary
                  : PrinterActionTone.neutral,
              accentColor: PrinterSdkConfig.bluetoothColor,
              isLoading: printing,
            ),
            if (connected)
              PrinterActionButton(
                icon: Icons.bluetooth_disabled_rounded,
                label: 'Disconnect',
                onPressed: busy ? null : _disconnect,
                tone: PrinterActionTone.danger,
              ),
          ],
        ),
        SizedBox(height: isCompact ? 10 : 12),
        _DeviceList(
          items: items,
          savedMac: _savedMac,
          connectedMac: connected ? _connectedMac : '',
          connected: connected,
          scanning: scanning,
          busy: busy,
          status: _status,
          hasSaved: hasSaved,
          onScan: () => _scan(),
          onSelect: _handleDeviceTap,
        ),
      ],
    );
  }

  String _heroSubtitle(bool connected, bool scanning, bool reconnecting) {
    if (connected) {
      return _connectedMac.isEmpty
          ? 'Connected over Bluetooth'
          : 'Connected • $_connectedMac';
    }
    if (scanning) return 'Looking for paired printers…';
    if (reconnecting) {
      return 'Reconnecting automatically. Keep the printer powered on.';
    }
    if (_savedMac.isNotEmpty) {
      return 'Saved printer: ${_savedName.isEmpty ? _savedMac : _savedName}. '
          'Tap Retry or Search.';
    }
    return 'Pair the printer in system Bluetooth settings, then tap Search.';
  }

  String _heroStatusLabel(bool connected, bool scanning) {
    if (connected) return 'Connected';
    if (scanning) return 'Searching';
    if (BluetoothService.isConnecting) return 'Connecting';
    if (BluetoothService.isReconnecting) return 'Reconnecting';
    return 'Not connected';
  }
}

// -----------------------------------------------------------------------------
// Local presentational widgets
// -----------------------------------------------------------------------------

class _StatusGrid extends StatelessWidget {
  const _StatusGrid({
    required this.compact,
    required this.isBluetoothEnabled,
    required this.isPermissionGranted,
    required this.batteryLevel,
    required this.platformVersion,
    required this.connected,
    required this.reconnecting,
  });

  final bool compact;
  final bool isBluetoothEnabled;
  final bool isPermissionGranted;
  final int batteryLevel;
  final String platformVersion;
  final bool connected;
  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    final String bluetoothValue = !isPermissionGranted
        ? 'No permission'
        : isBluetoothEnabled
        ? 'Enabled'
        : 'Disabled';

    return PrinterStatusGrid(
      children: <Widget>[
        PrinterStatusCard(
          compact: compact,
          icon: BluetoothService.isScanning
              ? Icons.bluetooth_searching_rounded
              : connected
              ? Icons.bluetooth_connected_rounded
              : Icons.bluetooth_rounded,
          label: 'Bluetooth',
          value: bluetoothValue,
          color: isBluetoothEnabled
              ? PrinterSdkConfig.bluetoothColor
              : PrinterSdkConfig.textSecondaryColor,
        ),
        PrinterStatusCard(
          compact: compact,
          icon: Icons.battery_full_rounded,
          label: 'Host battery',
          value: batteryLevel > 0 ? '$batteryLevel%' : '—',
          color: batteryLevel > 20
              ? PrinterSdkConfig.successColor
              : PrinterSdkConfig.errorColor,
        ),
        PrinterStatusCard(
          compact: compact,
          icon: Icons.link_rounded,
          label: 'Connection',
          value: connected
              ? 'Connected'
              : reconnecting
              ? 'Retrying'
              : 'Disconnected',
          color: connected
              ? PrinterSdkConfig.successColor
              : reconnecting
              ? PrinterSdkConfig.warningColor
              : PrinterSdkConfig.textSecondaryColor,
        ),
        PrinterStatusCard(
          compact: compact,
          icon: Icons.phone_android_rounded,
          label: 'Platform',
          value: platformVersion.isEmpty ? '—' : platformVersion,
          color: PrinterSdkConfig.primaryColor,
        ),
      ],
    );
  }
}

class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner({
    required this.savedPrinterName,
    required this.reconnecting,
    required this.event,
    required this.canRetry,
    required this.onRetry,
  });

  final String savedPrinterName;
  final bool reconnecting;
  final PrinterConnectionEvent? event;
  final bool canRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bool failed =
        event?.type == PrinterConnectionEventType.reconnectFailed;
    final Color accent = failed
        ? PrinterSdkConfig.errorColor
        : PrinterSdkConfig.warningColor;
    final String title = failed
        ? 'Printer offline'
        : reconnecting
        ? 'Reconnecting printer'
        : 'Printer disconnected';
    final String message = event?.message.isNotEmpty == true
        ? event!.message
        : 'Saved printer $savedPrinterName is not connected.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            failed
                ? Icons.error_outline_rounded
                : Icons.bluetooth_disabled_rounded,
            size: 20,
            color: accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: PrinterSdkConfig.textPrimaryColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: PrinterSdkConfig.textSecondaryColor,
                  ),
                ),
                if (reconnecting) ...<Widget>[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      color: accent,
                      backgroundColor: accent.withValues(alpha: 0.18),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: canRetry ? onRetry : null,
            style: TextButton.styleFrom(
              foregroundColor: accent,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text(
              'Retry',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.items,
    required this.savedMac,
    required this.connectedMac,
    required this.connected,
    required this.scanning,
    required this.busy,
    required this.status,
    required this.hasSaved,
    required this.onScan,
    required this.onSelect,
  });

  final List<BluetoothInfo> items;
  final String savedMac;
  final String connectedMac;
  final bool connected;
  final bool scanning;
  final bool busy;
  final String status;
  final bool hasSaved;
  final VoidCallback onScan;
  final Future<void> Function(BluetoothInfo device, bool isConnected) onSelect;

  bool _isConnected(BluetoothInfo device) {
    return connected &&
        connectedMac.isNotEmpty &&
        device.macAdress.toUpperCase() == connectedMac.toUpperCase();
  }

  bool _isSaved(BluetoothInfo device) {
    return savedMac.isNotEmpty &&
        device.macAdress.toUpperCase() == savedMac.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: PrinterSdkConfig.surfaceColor,
        borderRadius: BorderRadius.circular(PrinterSdkConfig.borderRadius),
        border: Border.all(color: PrinterSdkConfig.borderColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Paired printers',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: PrinterSdkConfig.textPrimaryColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        items.isEmpty
                            ? 'Pair the printer in system settings first.'
                            : 'Tap a device to connect automatically.',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: PrinterSdkConfig.textSecondaryColor,
                        ),
                      ),
                    ],
                  ),
                ),
                PrinterStatusPill(
                  label: '${items.length}',
                  color: PrinterSdkConfig.textSecondaryColor,
                  showDot: false,
                ),
                const SizedBox(width: 2),
                IconButton(
                  tooltip: 'Search again',
                  onPressed: scanning ? null : onScan,
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  color: PrinterSdkConfig.textSecondaryColor,
                  icon: const Icon(Icons.sync_rounded),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: PrinterSdkConfig.borderColor),
          if (items.isEmpty)
            SizedBox(
              height: 220,
              child: PrinterEmptyState(
                icon: scanning
                    ? Icons.bluetooth_searching_rounded
                    : Icons.bluetooth_rounded,
                title: scanning
                    ? 'Searching for paired printers'
                    : hasSaved
                    ? 'Saved printer not detected'
                    : status == BluetoothPrinterStatus.notFound
                    ? 'No paired printers found'
                    : 'No paired printers yet',
                message: scanning
                    ? 'Keep the printer powered on and nearby.'
                    : hasSaved
                    ? 'The saved printer is not in the system list. Turn it on '
                          'and tap Search, or use Retry above.'
                    : 'Pair your thermal printer in Android Bluetooth settings, '
                          'then tap Search again.',
                action: TextButton.icon(
                  onPressed: scanning ? null : onScan,
                  style: TextButton.styleFrom(
                    foregroundColor: PrinterSdkConfig.bluetoothColor,
                  ),
                  icon: const Icon(Icons.search_rounded, size: 18),
                  label: const Text('Search again'),
                ),
              ),
            )
          else
            ListView.separated(
              padding: const EdgeInsets.all(8),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (BuildContext context, int index) {
                final BluetoothInfo device = items[index];
                final bool isConnected = _isConnected(device);
                final bool isSaved = _isSaved(device);

                return PrinterDeviceTile(
                  title: device.name.isEmpty ? 'Unknown printer' : device.name,
                  subtitle: device.macAdress,
                  isConnected: isConnected,
                  enabled: !busy,
                  icon: isConnected
                      ? Icons.bluetooth_connected_rounded
                      : Icons.bluetooth_rounded,
                  accentColor: PrinterSdkConfig.bluetoothColor,
                  trailing: isConnected || !isSaved
                      ? null
                      : PrinterStatusPill(
                          label: 'Saved',
                          color: PrinterSdkConfig.bluetoothColor,
                          showDot: false,
                        ),
                  onTap: () => onSelect(device, isConnected),
                );
              },
            ),
        ],
      ),
    );
  }
}
