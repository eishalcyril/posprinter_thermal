## 1.0.0

First release of `posprinter_usb_android`, an Android-only USB fork of
[`flutter_pos_printer_platform_image_3`](https://pub.dev/packages/flutter_pos_printer_platform_image_3)
1.2.4 (MIT, © 2022 Gustavo Morales and contributors).

Keeps the maintained Android USB fixes from the fork it is based on:

- A USB permission handshake that completes only once Android answers the
  dialog, instead of resolving `connectPrinter` before the grant.
- Android 13+ `IntentFilter` receivers registered with
  `Context.RECEIVER_NOT_EXPORTED`, and a cancelled stale `PendingIntent` from a
  previous process so the permission dialog cannot reappear over the launcher.
- `USBStatus.attached` events so the Dart side can reconnect immediately on
  replug, and `USBStatus.none` on detach.
- Chunked bulk writes that respect the endpoint's `maxPacketSize`, stop on the
  first failed chunk and close a stale endpoint so the next attempt re-opens it.

Reduced to the Android USB transport:

- Removed the iOS and Windows implementations (and the vendored `libGSDK.a`).
- Removed the Bluetooth, BLE and network (TCP) transports and the Star/TSPL/
  ESC-POS generator surface. The package now depends on nothing but Flutter.
- Removed the Bluetooth, Bluetooth-admin and location permissions from the
  plugin manifest, so they are no longer merged into the host app.
- `PrinterType` now only has `usb`, and `PrinterManager` only exposes the USB
  transport.
- Converted the Android build script to `build.gradle.kts` and migrated it to
  AGP built-in Kotlin. The module no longer applies the Kotlin Gradle Plugin
  itself, which clears Flutter's "plugins that apply KGP" warning.
- Minimum supported version is now Flutter 3.44 / Dart 3.12, required by
  `kotlin.compilerOptions`.
