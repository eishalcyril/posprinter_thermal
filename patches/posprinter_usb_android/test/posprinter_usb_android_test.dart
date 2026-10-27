import 'package:flutter_test/flutter_test.dart';
import 'package:posprinter_usb_android/posprinter_usb_android.dart';

void main() {
  test('USBStatus order matches the indices sent by the Android plugin', () {
    expect(USBStatus.values, <USBStatus>[
      USBStatus.none,
      USBStatus.connecting,
      USBStatus.connected,
      USBStatus.attached,
    ]);
  });

  test('PrinterManager is a singleton bound to the USB transport', () {
    expect(PrinterManager.instance, same(PrinterManager.instance));
    expect(PrinterManager.instance.usbPrinterConnector, isNotNull);
    expect(PrinterType.values, <PrinterType>[PrinterType.usb]);
  });

  test('connect rejects a model that is not a UsbPrinterInput', () async {
    final bool connected = await PrinterManager.instance.connect(
      type: PrinterType.usb,
      model: _OtherInput(),
    );
    expect(connected, isFalse);
  });

  test('discovery is empty on platforms without USB host access', () {
    // Widget tests run on the host, where Platform.isAndroid is false.
    expect(UsbPrinterConnector.instance.discovery(), emitsDone);
  });
}

class _OtherInput extends BasePrinterInput {}
