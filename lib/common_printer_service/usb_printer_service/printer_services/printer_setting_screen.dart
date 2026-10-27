import 'dart:async';

import 'package:flutter/material.dart';

import '../../global_loader_controller.dart';
import '../../printer_sdk_config.dart';
import '../../printer_storage.dart';
import '../../printer_ui.dart';
import '../../printer_widgets.dart';
import 'printer_service.dart';

/// Premium USB printer connection screen.
///
/// Drop it inside a [Scaffold] (the parent screen already provides one when
/// using `CommonPrinterSettingScreen`) and it fills the available height.
///
/// The screen is a thin view over [PrinterService]:
/// - the service owns scanning, connecting and automatic reconnection;
/// - the screen only mirrors its status and forwards user intents;
/// - automatic reconnects keep running when this screen is closed, because the
///   service subscribes to USB events once per process.
class PrinterSettingScreen extends StatefulWidget {
  const PrinterSettingScreen({super.key, this.onStatusChanged});

  /// Invoked whenever the connection state changes.
  final VoidCallback? onStatusChanged;

  @override
  State<PrinterSettingScreen> createState() => _PrinterSettingScreenState();
}

class _PrinterSettingScreenState extends State<PrinterSettingScreen> {
  bool _busy = false;
  bool _hostNotifyScheduled = false;
  String _status = PrinterService.printerStatus;
  PrinterInfo? _selectedPrinter;
  PrinterConnectionEvent? _lastEvent;
  StreamSubscription<String>? _statusSubscription;
  StreamSubscription<PrinterConnectionEvent>? _eventSubscription;

  String get _paperSize => PrinterService.optionPrinterType;

  @override
  void initState() {
    super.initState();

    _statusSubscription = PrinterService.statusStream.listen(_onStatus);
    _eventSubscription = PrinterService.connectionEvents.listen(_onEvent);

    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _eventSubscription?.cancel();
    super.dispose();
  }

  /// Notifies the host after the current frame.
  ///
  /// Status events can arrive while the parent scaffold is building or laying
  /// out. Calling `setState` on the host at that point can leave the body
  /// stuck half-laid-out (notably on cold start), so coalesce notifications
  /// into a post-frame callback instead.
  void _notifyHost() {
    if (_hostNotifyScheduled) return;
    _hostNotifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hostNotifyScheduled = false;
      if (mounted) widget.onStatusChanged?.call();
    });
    if (!WidgetsBinding.instance.hasScheduledFrame) {
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _bootstrap() async {
    await PrinterService.init();
    await PrinterStorage.ensureInitialized();
    if (!mounted) return;

    final String savedPaperSize = PrinterStorage.readString(
      PrinterStorageKeys.paperSize,
      defaultValue: PrinterSdkConfig.defaultPaperSize,
    );

    setState(() {
      PrinterService.optionPrinterType = savedPaperSize;
      _selectedPrinter = PrinterService.savedPrinter;
      _status = PrinterService.printerStatus;
    });

    if (!PrinterService.isSupported) return;

    // Scanning auto-connects the saved printer, including after the app was
    // restarted while the device stayed plugged in.
    await _scan(autoConnectSaved: true, notify: false);
    _notifyHost();
  }

  void _onStatus(String status) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _syncSelection();
    });
    // The host scaffold owns the footer; keep it in sync with automatic
    // connects, detaches and reconnects that happen without a button press.
    _notifyHost();
  }

  void _onEvent(PrinterConnectionEvent event) {
    if (!mounted) return;

    final PrinterConnectionEventType previous =
        _lastEvent?.type ?? PrinterConnectionEventType.reconnected;

    setState(() => _lastEvent = event);

    if (event.type == PrinterConnectionEventType.reconnected &&
        previous != PrinterConnectionEventType.reconnected) {
      showPrinterToast(event.message, type: PrinterToastType.success);
    } else if (event.type == PrinterConnectionEventType.reconnectFailed) {
      showPrinterToast(event.message, type: PrinterToastType.error);
    }

    // Keep the host scaffold's footer (CommonPrinterSettingScreen) in sync
    // while the link is down or recovering.
    _notifyHost();
  }

  /// Keeps the selection pointing at a real, current [PrinterInfo].
  void _syncSelection() {
    if (PrinterService.isPrinterConnected) {
      final PrinterInfo? selected = _selectedPrinter;
      if (selected != null) {
        for (final PrinterInfo printer in PrinterService.availablePrinters) {
          if (printer.matches(selected)) {
            _selectedPrinter = printer;
            return;
          }
        }
        return;
      }

      _selectedPrinter =
          PrinterService.savedPrinter ??
          (PrinterService.printerName.isEmpty
              ? null
              : PrinterInfo(
                  name: PrinterService.printerName,
                  vendorId: '',
                  productId: '',
                ));
      return;
    }

    // While disconnected, keep a saved selection so the user can retry
    // without scanning again.
    _selectedPrinter ??= PrinterService.savedPrinter;
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _scan({bool autoConnectSaved = true, bool notify = true}) async {
    if (_busy) return;

    setState(() => _busy = true);
    try {
      await PrinterService.scan(autoConnectSaved: autoConnectSaved);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = PrinterService.printerStatus;
          _syncSelection();
        });
      }
    }

    if (!mounted || !notify) return;

    final List<PrinterInfo> printers = PrinterService.availablePrinters;
    if (PrinterService.isPrinterConnected) {
      showPrinterToast(
        'USB printer connected.',
        type: PrinterToastType.success,
      );
    } else if (printers.isEmpty) {
      showPrinterToast(
        'No USB printer detected. Check the cable and tap Scan again.',
        type: PrinterToastType.error,
      );
    } else {
      showPrinterToast(
        '${printers.length} printer(s) found. Tap one to connect.',
        type: PrinterToastType.info,
      );
    }
  }

  Future<void> _connect(PrinterInfo printer) async {
    if (_busy) return;

    if (PrinterService.isPrinterConnected) {
      final PrinterInfo? current = _selectedPrinter;
      if (current != null && printer.matches(current)) {
        showPrinterToast(
          'Already connected to ${printer.name}.',
          type: PrinterToastType.info,
        );
        return;
      }

      final bool shouldSwitch = await showPrinterConfirmDialog(
        context,
        title: 'Switch printer?',
        message:
            'Disconnect from ${current?.name ?? 'the current printer'} '
            'and connect to ${printer.name} instead?',
        confirmLabel: 'Switch',
        destructive: true,
      );
      if (!shouldSwitch || !mounted) return;

      await PrinterService.disconnect(clearSaved: false);
      if (!mounted) return;
    }

    setState(() {
      _busy = true;
      _selectedPrinter = printer;
    });

    final bool result = await PrinterService.connect(printer);
    if (!mounted) return;

    setState(() {
      _busy = false;
      _status = PrinterService.printerStatus;
      _syncSelection();
    });

    showPrinterToast(
      result
          ? '${printer.name} connected.'
          : 'Could not connect to ${printer.name}. Replug the cable and retry.',
      type: result ? PrinterToastType.success : PrinterToastType.error,
    );
    _notifyHost();
  }

  Future<void> _reconnect() async {
    if (_busy) return;

    if (PrinterService.savedPrinter == null) {
      showPrinterToast(
        'No saved printer. Scan and connect one first.',
        type: PrinterToastType.error,
      );
      return;
    }

    setState(() => _busy = true);
    final bool result = await PrinterService.reconnectSaved();
    if (!mounted) return;

    setState(() {
      _busy = false;
      _status = PrinterService.printerStatus;
      _syncSelection();
    });

    if (!result) {
      showPrinterToast(
        'Reconnect failed. Check the cable and try again.',
        type: PrinterToastType.error,
      );
    }
  }

  Future<void> _disconnect() async {
    if (_busy) return;

    setState(() => _busy = true);
    await PrinterService.disconnect();
    if (!mounted) return;

    setState(() {
      _busy = false;
      _selectedPrinter = null;
      _status = PrinterService.printerStatus;
      _lastEvent = null;
    });

    showPrinterToast('USB printer disconnected.', type: PrinterToastType.info);
    _notifyHost();
  }

  Future<void> _testPrint() async {
    if (!PrinterService.isPrinterConnected || PrinterService.isPrinting) {
      showPrinterToast(
        'Connect a USB printer before printing.',
        type: PrinterToastType.error,
      );
      return;
    }

    if (PrinterSdkConfig.showPrintLoader && mounted) {
      GlobalLoaderController().show(context);
    }

    bool result = false;
    try {
      result = await PrinterService.testPrint();
    } catch (_) {
      result = false;
    } finally {
      GlobalLoaderController().hide();
    }

    if (!mounted) return;
    showPrinterToast(
      result
          ? 'Test print sent to ${_selectedPrinter?.name ?? 'the printer'}.'
          : 'Print could not be sent. Reconnect the printer and retry.',
      type: result ? PrinterToastType.success : PrinterToastType.error,
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Remember the host app's root overlay so service callbacks can show
    // toasts without a BuildContext.
    PrinterOverlay.attach(context);

    if (!PrinterService.isSupported) {
      return _buildUnsupported();
    }

    // Read the live MediaQuery on every build. Capturing it once in
    // didChangeDependencies can record the transient 0x0 size from the first
    // frame and leave the screen in the wrong breakpoint after startup.
    final Size screenSize = MediaQuery.sizeOf(context);
    final bool isCompact = screenSize.width < 400 || screenSize.height < 700;

    final List<PrinterInfo> printers = PrinterService.availablePrinters;
    final bool connected = PrinterService.isPrinterConnected;
    final bool scanning = PrinterService.isScanning;
    final bool reconnecting = PrinterService.isReconnecting;
    final bool busy =
        _busy ||
        scanning ||
        PrinterService.isConnecting ||
        PrinterService.isPrinting;

    final PrinterInfo? saved = PrinterService.savedPrinter;
    final String deviceName = _selectedPrinter?.name.isNotEmpty == true
        ? _selectedPrinter!.name
        : (PrinterService.printerName.isNotEmpty
              ? PrinterService.printerName
              : (saved?.name.isNotEmpty == true
                    ? saved!.name
                    : 'No printer selected'));

    // Keep this a ListView rather than a SingleChildScrollView. The latter
    // intermittently stalled its first layout on Android 14 cold starts,
    // leaving the header and footer visible with a blank body.
    return ListView(
      padding: EdgeInsets.fromLTRB(
        isCompact ? 8 : 12,
        8,
        isCompact ? 8 : 12,
        12,
      ),
      children: <Widget>[
        PrinterHeroCard(
          icon: Icons.usb_rounded,
          title: connected ? deviceName : 'USB thermal printer',
          subtitle: _heroSubtitle(connected, scanning, saved),
          statusLabel: _heroStatusLabel(connected, scanning),
          statusColor: connected
              ? PrinterSdkConfig.successColor
              : reconnecting
              ? PrinterSdkConfig.warningColor
              : PrinterSdkConfig.textSecondaryColor,
          accentColor: PrinterSdkConfig.usbColor,
          accentDarkColor: PrinterSdkConfig.usbDarkColor,
          busy: scanning || PrinterService.isConnecting || reconnecting,
        ),
        SizedBox(height: isCompact ? 10 : 12),
        PrinterStatusGrid(
          children: <Widget>[
            PrinterStatusCard(
              compact: isCompact,
              icon: Icons.usb_rounded,
              label: 'USB',
              value: scanning
                  ? 'Scanning'
                  : connected
                  ? 'Active'
                  : _status == PrinterStatus.notFound
                  ? 'Not found'
                  : 'Idle',
              color: connected
                  ? PrinterSdkConfig.successColor
                  : scanning || reconnecting
                  ? PrinterSdkConfig.warningColor
                  : PrinterSdkConfig.usbColor,
            ),
            PrinterStatusCard(
              compact: isCompact,
              icon: Icons.link_rounded,
              label: 'Connection',
              value: connected
                  ? 'Connected'
                  : reconnecting
                  ? 'Reconnecting'
                  : 'Disconnected',
              color: connected
                  ? PrinterSdkConfig.successColor
                  : reconnecting
                  ? PrinterSdkConfig.warningColor
                  : PrinterSdkConfig.textSecondaryColor,
            ),
            PrinterStatusCard(
              compact: isCompact,
              icon: Icons.print_rounded,
              label: 'Device',
              value: connected ? deviceName : 'None',
              color: connected
                  ? PrinterSdkConfig.usbColor
                  : PrinterSdkConfig.textSecondaryColor,
            ),
            PrinterStatusCard(
              compact: isCompact,
              icon: Icons.receipt_long_rounded,
              label: 'Paper',
              value: _paperSize,
              color: PrinterSdkConfig.primaryColor,
            ),
          ],
        ),
        if (!connected && saved != null) ...<Widget>[
          SizedBox(height: isCompact ? 10 : 12),
          _ReconnectBanner(
            savedPrinterName: saved.name,
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
              icon: Icons.sync_rounded,
              label: scanning ? 'Scanning' : 'Scan',
              onPressed: busy && !scanning ? null : () => _scan(),
              tone: connected
                  ? PrinterActionTone.neutral
                  : PrinterActionTone.primary,
              accentColor: PrinterSdkConfig.usbColor,
              isLoading: scanning,
            ),
            PrinterActionButton(
              icon: Icons.print_rounded,
              label: 'Test print',
              onPressed: connected && !busy ? _testPrint : null,
              tone: connected
                  ? PrinterActionTone.primary
                  : PrinterActionTone.neutral,
              accentColor: PrinterSdkConfig.usbColor,
              isLoading: PrinterService.isPrinting,
            ),
            if (connected)
              PrinterActionButton(
                icon: Icons.link_off_rounded,
                label: 'Disconnect',
                onPressed: busy ? null : _disconnect,
                tone: PrinterActionTone.danger,
              ),
          ],
        ),
        SizedBox(height: isCompact ? 10 : 12),
        _DeviceList(
          printers: printers,
          selectedPrinter: _selectedPrinter,
          savedPrinter: saved,
          connected: connected,
          scanning: scanning,
          busy: busy,
          status: _status,
          onScan: () => _scan(),
          onSelect: _connect,
        ),
      ],
    );
  }

  String _heroSubtitle(bool connected, bool scanning, PrinterInfo? saved) {
    if (connected) {
      final String hardwareId = _selectedPrinter?.hardwareId ?? '';
      return hardwareId.isNotEmpty ? hardwareId : 'Connected over USB';
    }
    if (scanning) return 'Searching for connected printers...';
    if (PrinterService.isReconnecting) {
      return 'Trying to reconnect automatically. Keep the printer powered on.';
    }
    if (saved != null) {
      return 'Saved printer: ${saved.name}. Plug it in and tap Scan.';
    }
    return 'Plug in the printer and tap Scan';
  }

  String _heroStatusLabel(bool connected, bool scanning) {
    if (connected) return 'Connected';
    if (scanning) return 'Scanning';
    if (PrinterService.isReconnecting) return 'Reconnecting';
    return 'Not connected';
  }

  Widget _buildUnsupported() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        decoration: BoxDecoration(
          color: PrinterSdkConfig.surfaceColor,
          borderRadius: BorderRadius.circular(PrinterSdkConfig.borderRadius),
          border: Border.all(color: PrinterSdkConfig.borderColor),
        ),
        child: const PrinterEmptyState(
          icon: Icons.usb_off_rounded,
          title: 'USB printing is not available here',
          message:
              'USB thermal printers are supported on Android only. '
              'Use Bluetooth on this device.',
        ),
      ),
    );
  }
}

/// Non-modal connection-lost notice.
///
/// Reconnection keeps running in [PrinterService], so this banner never blocks
/// the host app (important for kiosk mode) and disappears on its own once the
/// printer is back.
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
            failed ? Icons.error_outline_rounded : Icons.usb_off_rounded,
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
    required this.printers,
    required this.selectedPrinter,
    required this.savedPrinter,
    required this.connected,
    required this.scanning,
    required this.busy,
    required this.status,
    required this.onScan,
    required this.onSelect,
  });

  final List<PrinterInfo> printers;
  final PrinterInfo? selectedPrinter;
  final PrinterInfo? savedPrinter;
  final bool connected;
  final bool scanning;
  final bool busy;
  final String status;
  final VoidCallback onScan;
  final ValueChanged<PrinterInfo> onSelect;

  bool _isSelected(PrinterInfo printer) {
    return selectedPrinter != null && printer.matches(selectedPrinter!);
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
                        'USB devices',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: PrinterSdkConfig.textPrimaryColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        printers.isEmpty
                            ? 'Plug in a printer, then scan.'
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
                  label: '${printers.length}',
                  color: PrinterSdkConfig.textSecondaryColor,
                  showDot: false,
                ),
                const SizedBox(width: 2),
                IconButton(
                  tooltip: 'Scan again',
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
          if (printers.isEmpty)
            SizedBox(
              height: 220,
              child: PrinterEmptyState(
                icon: scanning ? Icons.usb_rounded : Icons.usb_off_rounded,
                title: scanning
                    ? 'Searching for USB printers'
                    : savedPrinter != null
                    ? 'Saved printer not detected'
                    : status == PrinterStatus.notFound
                    ? 'No printer detected'
                    : 'No USB printer selected',
                message: scanning
                    ? 'Keep the printer powered on and connected.'
                    : savedPrinter != null
                    ? '${savedPrinter!.name} is saved for automatic reconnect. '
                          'Plug it in and tap Scan, or tap Retry above.'
                    : 'Connect the printer with a USB cable, then tap Scan. '
                          'On Android you may need to allow USB access.',
                action: TextButton.icon(
                  onPressed: scanning ? null : onScan,
                  style: TextButton.styleFrom(
                    foregroundColor: PrinterSdkConfig.usbColor,
                  ),
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('Scan for printers'),
                ),
              ),
            )
          else
            ListView.separated(
              padding: const EdgeInsets.all(8),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: printers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (BuildContext context, int index) {
                final PrinterInfo printer = printers[index];
                final bool isConnected = connected && _isSelected(printer);
                final bool isSelected = _isSelected(printer);

                return PrinterDeviceTile(
                  title: printer.name,
                  subtitle: printer.hardwareId.isEmpty
                      ? 'USB printer'
                      : printer.hardwareId,
                  isConnected: isConnected,
                  enabled: !busy,
                  icon: Icons.print_rounded,
                  accentColor: PrinterSdkConfig.usbColor,
                  trailing: isConnected
                      ? null
                      : isSelected
                      ? Icon(
                          Icons.check_circle_rounded,
                          size: 20,
                          color: PrinterSdkConfig.usbColor,
                        )
                      : null,
                  onTap: () => onSelect(printer),
                );
              },
            ),
        ],
      ),
    );
  }
}
