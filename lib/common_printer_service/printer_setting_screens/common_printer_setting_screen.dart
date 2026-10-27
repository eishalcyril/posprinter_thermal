import 'package:animated_toggle_switch/animated_toggle_switch.dart';
import 'package:flutter/material.dart';

import '../bluetooth_printer_service/bluetooth_printer_service.dart';
import '../bluetooth_printer_service/printersettings.dart';
import '../printer_sdk_config.dart';
import '../printer_storage.dart';
import '../usb_printer_service/printer_services/printer_service.dart';
import '../usb_printer_service/printer_services/printer_setting_screen.dart';

/// The main SDK screen: pick Bluetooth or USB and manage the connection.
///
/// ```dart
/// Navigator.of(context).push(
///   MaterialPageRoute<void>(
///     builder: (_) => const CommonPrinterSettingScreen(),
///   ),
/// );
/// ```
class CommonPrinterSettingScreen extends StatefulWidget {
  const CommonPrinterSettingScreen({super.key});

  @override
  State<CommonPrinterSettingScreen> createState() =>
      _CommonPrinterSettingScreenState();
}

class _CommonPrinterSettingScreenState
    extends State<CommonPrinterSettingScreen> {
  bool _isBluetooth = true;
  String _paperSize = PrinterSdkConfig.defaultPaperSize;
  bool _loaded = false;

  // Evaluated during build so it always reflects the current window size.
  bool get _isWide => MediaQuery.sizeOf(context).width >= 560;

  /// USB host printing is Android-only. On every other platform the SDK shows
  /// the Bluetooth screen and hides the connection-type toggle entirely.
  bool get _usbSupported => PrinterService.isSupported;

  @override
  void initState() {
    super.initState();
    // The SDK opens storage before runApp, so in normal use the saved mode is
    // available synchronously. Loading it here (instead of in a microtask)
    // means the USB body is part of the very first frame. Swapping a large
    // scroll view into the Scaffold on a later startup frame can stall layout
    // on some Android devices.
    if (PrinterStorage.isReady) {
      _restoreSettings();
    } else {
      _bootstrap();
    }
  }

  void _restoreSettings() {
    final String savedPaperSize = PrinterStorage.readString(
      PrinterStorageKeys.paperSize,
      defaultValue: PrinterSdkConfig.defaultPaperSize,
    );

    _isBluetooth = PrinterStorage.readBool(
      PrinterStorageKeys.connectionType,
      defaultValue: true,
    );
    // A device that cannot do USB (for example iOS) always starts on
    // Bluetooth, even if USB was the last choice on another device.
    if (!_usbSupported) _isBluetooth = true;
    _paperSize = PrinterSdkConfig.paperSizes.contains(savedPaperSize)
        ? savedPaperSize
        : PrinterSdkConfig.defaultPaperSize;
    BluetoothService.optionprinttype = _paperSize;
    PrinterService.optionPrinterType = _paperSize;
    _loaded = true;
  }

  Future<void> _bootstrap() async {
    await PrinterStorage.ensureInitialized();
    if (!mounted) return;
    setState(_restoreSettings);
  }

  Future<void> _setConnectionType(bool isBluetooth) async {
    if (_isBluetooth == isBluetooth) return;

    setState(() => _isBluetooth = isBluetooth);
    await PrinterStorage.write(PrinterStorageKeys.connectionType, isBluetooth);

    if (!isBluetooth) {
      // Preserve the saved printer so switching back reconnects automatically.
      // `disconnect` also stops any pending Bluetooth reconnect loop.
      await BluetoothService.disconnect(clearSaved: false);
    }
    if (isBluetooth) {
      // Keep the saved printer so switching back reconnects automatically.
      // `disconnect` also cancels a pending USB reconnect loop.
      await PrinterService.disconnect(clearSaved: false);
    }
  }

  Future<void> _setPaperSize(String? value) async {
    if (value == null || value == _paperSize) return;

    setState(() {
      _paperSize = value;
      BluetoothService.optionprinttype = value;
      PrinterService.optionPrinterType = value;
    });
    await PrinterStorage.write(PrinterStorageKeys.paperSize, value);
  }

  bool get _isConnected => _isBluetooth
      ? BluetoothService.bluetoothIsConnected
      : PrinterService.isPrinterConnected;

  String get _footerMessage {
    if (_isBluetooth) {
      if (BluetoothService.isReconnecting) {
        final String saved = BluetoothService.savedPrinterName;
        return 'Reconnecting to ${saved.isEmpty ? 'the Bluetooth printer' : saved}…';
      }
      if (BluetoothService.isConnecting || BluetoothService.connectionLoading) {
        return 'Connecting to the Bluetooth printer…';
      }
      if (!BluetoothService.bluetoothIsConnected) {
        if (BluetoothService.hasSavedPrinter) {
          final String saved = BluetoothService.savedPrinterName;
          return '${saved.isEmpty ? 'Bluetooth printer' : saved} is '
              'disconnected. It will reconnect automatically.';
        }
        return 'Select a paired Bluetooth printer to connect.';
      }
      final String name = BluetoothService.connectedPrinterName;
      return '${name.isEmpty ? 'Bluetooth printer' : name} is connected and '
          'ready to print.';
    }

    if (!PrinterService.isPrinterConnected) {
      if (PrinterService.isConnecting) {
        return 'Connecting to the USB printer…';
      }
      if (PrinterService.isReconnecting) {
        return 'Reconnecting to the USB printer…';
      }
      final PrinterInfo? saved = PrinterService.savedPrinter;
      if (saved != null) {
        return '${saved.name} is disconnected. It will reconnect automatically.';
      }
      return 'Select a USB printer below to connect.';
    }
    final String name = PrinterService.printerName;
    return '${name.isEmpty ? 'USB printer' : name} is connected and ready to print.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PrinterSdkConfig.backgroundColor,
      appBar: AppBar(
        title: Text(
          PrinterSdkConfig.appBarTitle,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: PrinterSdkConfig.textPrimaryColor,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: PrinterSdkConfig.surfaceColor,
        surfaceTintColor: Colors.transparent,
        iconTheme: IconThemeData(color: PrinterSdkConfig.textPrimaryColor),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: PrinterSdkConfig.borderColor),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: _buildControlsCard(),
                ),
                Expanded(
                  child: !_loaded
                      ? Center(
                          child: SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: PrinterSdkConfig.primaryColor,
                            ),
                          ),
                        )
                      : _isBluetooth
                      ? BluetoothPrinterSettings(
                          key: const ValueKey<String>('bluetooth-settings'),
                          changedBluetoothStatus: () => setState(() {}),
                        )
                      : PrinterSettingScreen(
                          key: const ValueKey<String>('usb-settings'),
                          onStatusChanged: () => setState(() {}),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _buildFooter(),
    );
  }

  Widget _buildControlsCard() {
    // Hidden on platforms without USB host access (iOS, macOS, Linux, web):
    // there is nothing to switch to, so the SDK only offers Bluetooth.
    final Widget? toggle = _usbSupported
        ? AnimatedToggleSwitch<bool>.dual(
            current: _isBluetooth,
            first: false,
            second: true,
            spacing: _isWide ? 70 : 40,
            height: 48,
            borderWidth: 4,
            style: ToggleStyle(
              borderColor: PrinterSdkConfig.borderColor,
              backgroundColor: PrinterSdkConfig.backgroundColor,
              borderRadius: BorderRadius.circular(30),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            styleBuilder: (bool value) => ToggleStyle(
              // `value == true` is the Bluetooth side.
              indicatorColor: value
                  ? PrinterSdkConfig.bluetoothColor
                  : PrinterSdkConfig.usbColor,
            ),
            iconBuilder: (bool value) => Icon(
              value ? Icons.bluetooth_rounded : Icons.usb_rounded,
              color: Colors.white,
              size: 20,
            ),
            textBuilder: (bool value) => Center(
              child: Text(
                value ? 'Bluetooth' : 'USB',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: value
                      ? PrinterSdkConfig.bluetoothColor
                      : PrinterSdkConfig.usbColor,
                ),
              ),
            ),
            onChanged: _setConnectionType,
          )
        : null;

    final Widget paperDropdown = DropdownButtonFormField<String>(
      initialValue: _paperSize,
      isDense: true,
      decoration: InputDecoration(
        labelText: 'Paper size',
        filled: true,
        fillColor: PrinterSdkConfig.surfaceColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        labelStyle: TextStyle(
          color: PrinterSdkConfig.textSecondaryColor,
          fontSize: 13,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: PrinterSdkConfig.borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: PrinterSdkConfig.borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: PrinterSdkConfig.primaryColor,
            width: 1.6,
          ),
        ),
      ),
      icon: Icon(
        Icons.print_rounded,
        size: 20,
        color: PrinterSdkConfig.textSecondaryColor,
      ),
      dropdownColor: PrinterSdkConfig.surfaceColor,
      style: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: PrinterSdkConfig.textPrimaryColor,
      ),
      items: PrinterSdkConfig.paperSizes
          .map(
            (String option) =>
                DropdownMenuItem<String>(value: option, child: Text(option)),
          )
          .toList(),
      onChanged: _setPaperSize,
    );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PrinterSdkConfig.surfaceColor,
        borderRadius: BorderRadius.circular(PrinterSdkConfig.borderRadius),
        border: Border.all(color: PrinterSdkConfig.borderColor),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: toggle == null
          ? paperDropdown
          : _isWide
          ? Row(
              children: <Widget>[
                toggle,
                const SizedBox(width: 16),
                Expanded(child: paperDropdown),
              ],
            )
          : Column(
              children: <Widget>[
                toggle,
                const SizedBox(height: 10),
                paperDropdown,
              ],
            ),
    );
  }

  Widget _buildFooter() {
    final bool reconnecting = _isBluetooth
        ? BluetoothService.isReconnecting ||
              BluetoothService.isConnecting ||
              BluetoothService.connectionLoading
        : PrinterService.isReconnecting || PrinterService.isConnecting;
    final Color color = _isConnected
        ? PrinterSdkConfig.successColor
        : reconnecting
        ? PrinterSdkConfig.warningColor
        : PrinterSdkConfig.textSecondaryColor;

    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: BoxDecoration(
          color: PrinterSdkConfig.surfaceColor,
          border: Border(top: BorderSide(color: PrinterSdkConfig.borderColor)),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _footerMessage,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
