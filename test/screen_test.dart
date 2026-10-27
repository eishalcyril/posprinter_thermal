import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:posprinter_thermal/pos_printer_sdk.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('printer_sdk_test_');
    Hive.init(tempDir.path);
    // Pre-open the SDK box so screen bootstrap resolves on the next microtask.
    await Hive.openBox<dynamic>(PrinterSdkConfig.hiveBoxName);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  setUp(() {
    PrinterSdkConfig.reset();
    // Toasts use a platform channel that is unavailable in widget tests.
    PrinterSdkConfig.showToasts = false;
  });

  testWidgets('connection screen renders both connection types', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const CommonPrinterSettingScreen(),
      ),
    );

    // Let the post-frame Hive load and plugin fallbacks settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(CommonPrinterSettingScreen), findsOneWidget);
    expect(find.text('Paper size'), findsOneWidget);
    expect(find.text('Bluetooth'), findsWidgets);
    expect(find.text('USB'), findsWidgets);
    expect(find.text('Test print'), findsOneWidget);
  });

  testWidgets('connection screen fits a compact phone', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const CommonPrinterSettingScreen(),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // A RenderFlex overflow would throw during the pump above.
    expect(tester.takeException(), isNull);
    expect(find.text('Paper size'), findsOneWidget);
  });

  testWidgets('USB screen shows a friendly message on unsupported platforms', (
    WidgetTester tester,
  ) async {
    // USB host access is Android-only: pretend to be on iOS.
    //
    // The override has to be cleared inside the test body: flutter_test checks
    // that foundation debug variables are unset before tearDowns run.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const Scaffold(body: PrinterSettingScreen()),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(PrinterSettingScreen), findsOneWidget);
      expect(find.text('USB printing is not available here'), findsOneWidget);
      expect(find.textContaining('Android only'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS hides the USB option and offers Bluetooth only', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const CommonPrinterSettingScreen(),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The paper selector stays, the connection-type toggle does not.
      expect(find.text('Paper size'), findsOneWidget);
      expect(find.text('USB'), findsNothing);
      expect(find.text('Bluetooth'), findsWidgets);
      expect(find.text('Test print'), findsOneWidget);

      // On iOS the screen really probes the link, which arms a 5 second
      // timeout. Let it expire so no timer outlives the test.
      await tester.pump(const Duration(seconds: 6));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Android keeps the Bluetooth/USB toggle', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const CommonPrinterSettingScreen(),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('USB'), findsWidgets);
    expect(find.text('Bluetooth'), findsWidgets);
  });
}
