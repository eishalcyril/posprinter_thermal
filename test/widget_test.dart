import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:posprinter_thermal/pos_printer_sdk.dart';

void main() {
  tearDown(PrinterSdkConfig.reset);

  test('Android runtime Bluetooth permissions are only requested on Android', () {
    // Widget tests run as Android by default.
    expect(BluetoothService.requiresRuntimePermissions, isTrue);

    // permission_handler does not implement BLUETOOTH_SCAN/CONNECT on iOS and
    // reports them permanently denied, so the SDK must not gate scanning on
    // them there. Bluetooth itself still works on iOS.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      expect(BluetoothService.requiresRuntimePermissions, isFalse);
      expect(BluetoothService.isSupported, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(BluetoothService.requiresRuntimePermissions, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('config exposes sensible defaults', () {
    expect(PrinterSdkConfig.paperSizes, contains('58 mm'));
    expect(PrinterSdkConfig.paperSizes, contains('80 mm'));
    expect(PrinterSdkConfig.hiveBoxName, isNotEmpty);
    expect(PrinterSdkConfig.is80mm('80 mm'), isTrue);
    expect(PrinterSdkConfig.is80mm('58 mm'), isFalse);
  });

  test('reconnect defaults keep retrying with a backoff', () {
    expect(PrinterSdkConfig.autoReconnect, isTrue);
    expect(PrinterSdkConfig.reconnectDelays, isNotEmpty);
    expect(
      PrinterSdkConfig.reconnectDelays,
      orderedEquals(PrinterSdkConfig.reconnectDelays.toList()..sort()),
    );
    expect(PrinterSdkConfig.reconnectMaxAttempts, 0);
  });

  test('PrinterStatus exposes the reconnect state', () {
    expect(PrinterStatus.reconnecting, 'Reconnecting');
  });

  test('initialize applies reconnect options', () async {
    await PrinterSdk.initialize(
      autoReconnect: false,
      reconnectDelays: const <Duration>[Duration(seconds: 1)],
      reconnectMaxAttempts: 2,
    );

    expect(PrinterSdkConfig.autoReconnect, isFalse);
    expect(PrinterSdkConfig.reconnectDelays, const <Duration>[
      Duration(seconds: 1),
    ]);
    expect(PrinterSdkConfig.reconnectMaxAttempts, 2);
  });

  test('initialize applies branding options', () async {
    await PrinterSdk.initialize(
      primaryColor: const Color(0xFF0F766E),
      appBarTitle: 'My Printers',
      defaultPaperSize: '80 mm',
    );

    expect(PrinterSdkConfig.primaryColor, const Color(0xFF0F766E));
    expect(PrinterSdkConfig.appBarTitle, 'My Printers');
    expect(PrinterSdkConfig.defaultPaperSize, '80 mm');
  });

  test('reset restores defaults', () {
    PrinterSdkConfig.primaryColor = Colors.red;
    PrinterSdkConfig.reset();
    expect(PrinterSdkConfig.primaryColor, const Color(0xFF2563EB));
  });

  test('USB printer equality ignores address but not identity', () {
    const PrinterInfo a = PrinterInfo(
      name: 'Printer',
      vendorId: '1',
      productId: '2',
      address: 'usb:1',
    );
    const PrinterInfo b = PrinterInfo(
      name: 'Printer',
      vendorId: '1',
      productId: '2',
      address: 'usb:2',
    );
    const PrinterInfo c = PrinterInfo(
      name: 'Other',
      vendorId: '1',
      productId: '2',
    );

    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
  });

  testWidgets('printing loader renders the bundled animation and label', (
    tester,
  ) async {
    late BuildContext rootContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            rootContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    GlobalLoaderController().show(rootContext);
    // The animation asset is resolved asynchronously before it renders.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Printing'), findsOneWidget);
    expect(find.byType(Lottie), findsOneWidget);

    GlobalLoaderController().hide();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
