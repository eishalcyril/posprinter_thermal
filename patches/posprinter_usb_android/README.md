# posprinter_usb_android

Android **USB host** transport for ESC/POS thermal receipt printers.

It lists the printers attached over USB, performs the Android USB permission
handshake, opens the bulk OUT endpoint and writes raw ESC/POS bytes to it. There
is no Bluetooth, BLE or network (TCP) code in this package, and no third-party
Dart dependency: it only depends on Flutter.

This package is a maintained, Android-only fork of
[`flutter_pos_printer_platform_image_3`](https://pub.dev/packages/flutter_pos_printer_platform_image_3)
1.2.4. See [CHANGELOG.md](CHANGELOG.md) for what changed and
[LICENSE](LICENSE) for attribution.

---

## Platform support

| | Android | iOS | Windows | macOS | Linux | Web |
|---|---|---|---|---|---|---|
| USB host printing | ✅ | — | — | — | — | — |

Android exposes USB host access through `UsbManager`, which this plugin drives.
On every other platform the API is a no-op: `discovery()` yields nothing,
`connect()` returns `false` and the state stream is empty.

## Requirements

- Android `minSdk` 21 or newer.
- `android.hardware.usb.host` on the device (declared as `required="false"` by
  the plugin, so the app still installs on devices without a USB host port).
- Flutter 3.44 / Dart 3.12 or newer. This is what lets the module use AGP's
  built-in Kotlin support instead of applying the Kotlin Gradle Plugin itself.

## Usage

```dart
import 'package:posprinter_usb_android/posprinter_usb_android.dart';

final PrinterManager manager = PrinterManager.instance;

// 1. List attached printers.
final List<PrinterDevice> printers = await manager
    .discovery(type: PrinterType.usb)
    .toList();

// 2. Connect. Completes only after the Android permission dialog is answered.
final PrinterDevice printer = printers.first;
final bool connected = await manager.connect(
  type: PrinterType.usb,
  model: UsbPrinterInput(
    name: printer.name,
    vendorId: printer.vendorId,
    productId: printer.productId,
  ),
);

// 3. Send raw ESC/POS bytes.
await manager.send(type: PrinterType.usb, bytes: escPosBytes);

// 4. Close.
await manager.disconnect(type: PrinterType.usb);
```

### USB state events

`PrinterManager.instance.stateUSB` reports what the platform is doing:

| `USBStatus` | Meaning |
|---|---|
| `none` | No printer connected (also sent on detach). |
| `connecting` | Android is showing the USB permission dialog. |
| `connected` | Access was granted. |
| `attached` | A USB device was just plugged in — a good moment to reconnect. |

```dart
manager.stateUSB.listen((USBStatus status) {
  if (status == USBStatus.attached) {
    // The printer was replugged; try to reconnect it.
  }
});
```

### ESC/POS bytes

The plugin only transports bytes. Generate them with
[`flutter_esc_pos_utils`](https://pub.dev/packages/flutter_esc_pos_utils) or any
other ESC/POS generator.

## Example

`example/` contains a small app that scans for USB printers, connects to the one
you tap and prints a test receipt. Run it on a physical Android device with a
USB receipt printer attached:

```bash
cd example
flutter run
```

## Credits

Forked from
[`flutter_pos_printer_platform_image_3`](https://pub.dev/packages/flutter_pos_printer_platform_image_3)
by [diantahoc](https://github.com/diantahoc/flutter_pos_printer_platform), which
in turn was forked from
[`flutter_pos_printer_platform`](https://pub.dev/packages/flutter_pos_printer_platform)
by [arthas1888](https://github.com/arthas1888/flutter_pos_printer_platform).

## License

MIT — see [LICENSE](LICENSE). The upstream copyright notice is retained.
