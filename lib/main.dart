import 'dart:async';

import 'package:flutter/material.dart';
import 'package:posprinter_thermal/pos_printer_sdk.dart';

Future<void> main() async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Configure the SDK once. Replace the color with your brand color.
      await PrinterSdk.initialize(
        primaryColor: const Color(0xFF2563EB),
        appBarTitle: 'Printer Settings',
      );

      runApp(const DemoApp());
    },
    (Object error, StackTrace stackTrace) {
      debugPrint('Uncaught error: $error');
      debugPrint('Stack trace: $stackTrace');
    },
  );
}

/// Demo host app for the printer SDK.
///
/// The SDK itself lives in `lib/common_printer_service` and is exported by
/// `lib/pos_printer_sdk.dart`; this app only wires it up.
class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Printer SDK Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: PrinterSdkConfig.primaryColor,
        ),
        scaffoldBackgroundColor: PrinterSdkConfig.backgroundColor,
      ),
      home: const CommonPrinterSettingScreen(),
    );
  }
}
