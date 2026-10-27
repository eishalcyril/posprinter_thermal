import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:posprinter_thermal/pos_printer_sdk.dart';

/// Drives [BluetoothService] through a scripted printer plugin so the
/// reconnect loop can be verified without hardware.
///
/// The plugin is a thin `MethodChannel('groons.web.app/print')` wrapper, so the
/// fake below is the same contract the real device exposes.
class _FakePrinter {
  bool connected = false;
  bool connectSucceeds = true;
  int connectAttempts = 0;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'bluetoothenabled':
      case 'ispermissionbluetoothgranted':
        return true;
      case 'connectionstatus':
        return connected;
      case 'connect':
        connectAttempts++;
        if (!connectSucceeds) return false;
        connected = true;
        return true;
      case 'disconnect':
        connected = false;
        return true;
      case 'pairedbluetooths':
        return <String>['InnerPrinter#00:11:22:33:44:55'];
      case 'writebytes':
      case 'printstring':
        return connected;
      default:
        return null;
    }
  }
}

const String _mac = '00:11:22:33:44:55';
const String _name = 'InnerPrinter';
const MethodChannel _channel = MethodChannel('groons.web.app/print');

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $reason.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final _FakePrinter printer = _FakePrinter();
  late Directory tempDir;
  late Box<dynamic> box;
  late List<PrinterConnectionEvent> events;
  late StreamSubscription<String> statusSub;
  late StreamSubscription<PrinterConnectionEvent> eventSub;
  final List<String> statuses = <String>[];

  setUp(() async {
    printer
      ..connected = false
      ..connectSucceeds = true
      ..connectAttempts = 0;

    tempDir = await Directory.systemTemp.createTemp('bt_reconnect_test');
    Hive.init(tempDir.path);
    box = await Hive.openBox<dynamic>(PrinterSdkConfig.hiveBoxName);
    await box.put(PrinterStorageKeys.bluetoothMac, _mac);
    await box.put(PrinterStorageKeys.bluetoothName, _name);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, printer.handle);

    PrinterSdkConfig.autoReconnect = true;
    PrinterSdkConfig.reconnectMaxAttempts = 0;
    PrinterSdkConfig.reconnectDelays = const <Duration>[
      Duration(milliseconds: 30),
    ];
    PrinterSdkConfig.bluetoothHealthCheckInterval = const Duration(
      milliseconds: 25,
    );

    events = <PrinterConnectionEvent>[];
    statuses.clear();
    statusSub = BluetoothService.statusStream.listen(statuses.add);
    eventSub = BluetoothService.connectionEvents.listen(events.add);
  });

  tearDown(() async {
    await statusSub.cancel();
    await eventSub.cancel();
    await BluetoothService.dispose();
    PrinterSdkConfig.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await box.close();
    await tempDir.delete(recursive: true);
  });

  test('restores the saved printer and reconnects after the link returns', () async {
    // 1. Cold start without a live socket: the saved printer is restored
    //    automatically, exactly what happens after a Flutter hot restart.
    await BluetoothService.init();
    await _waitFor(
      () => BluetoothService.bluetoothIsConnected,
      reason: 'initial auto-connect',
    );
    expect(BluetoothService.connectedPrinterMac, _mac);
    expect(BluetoothService.savedPrinterMac, _mac);
    expect(printer.connectAttempts, greaterThanOrEqualTo(1));

    // 2. The printer (or its service) disappears: the watchdog notices and the
    //    backoff loop starts retrying.
    printer
      ..connected = false
      ..connectSucceeds = false;
    await _waitFor(
      () => events.any(
        (PrinterConnectionEvent e) =>
            e.type == PrinterConnectionEventType.disconnected,
      ),
      reason: 'disconnect detection',
    );
    await _waitFor(
      () => BluetoothService.isReconnecting,
      reason: 'reconnect loop to start',
    );
    expect(BluetoothService.bluetoothIsConnected, isFalse);
    expect(BluetoothService.printerStatus, BluetoothPrinterStatus.reconnecting);

    final int attemptsWhenDown = printer.connectAttempts;
    await _waitFor(
      () => printer.connectAttempts > attemptsWhenDown + 1,
      reason: 'several failed reconnect attempts',
    );
    expect(
      events.where(
        (PrinterConnectionEvent e) =>
            e.type == PrinterConnectionEventType.reconnecting,
      ),
      isNotEmpty,
    );
    expect(
      events.any(
        (PrinterConnectionEvent e) =>
            e.type == PrinterConnectionEventType.reconnectFailed,
      ),
      isFalse,
      reason: 'unlimited retries must not give up early',
    );

    // 3. The printer comes back: the next scheduled attempt must succeed, stop
    //    the loop and report the recovery.
    printer
      ..connectSucceeds = true
      ..connected = true;
    await _waitFor(
      () => events.any((PrinterConnectionEvent e) => e.isRecovered),
      reason: 'reconnected event',
    );

    expect(BluetoothService.bluetoothIsConnected, isTrue);
    expect(BluetoothService.isReconnecting, isFalse);
    expect(BluetoothService.printerStatus, BluetoothPrinterStatus.connected);
    expect(
      BluetoothService.connectedPrinterName,
      _name,
      reason: 'the restored name must survive the reconnect',
    );
  });

  test('stops retrying when auto reconnect is disabled', () async {
    PrinterSdkConfig.autoReconnect = false;
    await BluetoothService.init();

    await _waitFor(
      () => events.any(
        (PrinterConnectionEvent e) =>
            e.type == PrinterConnectionEventType.reconnectFailed,
      ),
      reason: 'reconnectFailed event',
    );
    expect(BluetoothService.isReconnecting, isFalse);
    expect(BluetoothService.bluetoothIsConnected, isFalse);
    expect(printer.connectAttempts, 0);
  });
}
