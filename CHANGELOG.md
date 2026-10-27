# Changelog

All notable changes to this package are documented here.

## Unreleased

### iOS

- The Bluetooth screen no longer asks the printer plugin for the battery level
  on iOS. That getter reports the *host device's* battery and raises
  `UNAVAILABLE` (`Nivel de batería no disponible`) whenever `UIDevice` cannot
  expose it — the normal case on iOS — which the plugin printed to the debug
  console on every screen open. The battery card shows `—` on iOS now.
- The demo app's iOS project was migrated from CocoaPods to Swift Package
  Manager (all iOS plugins ship `Package.swift`), removing Flutter's
  "non-standard Podfile" warning from every launch.

### Printing loader

- **The printing loader now plays the bundled Lottie animation.**
  `assets/animations/printer_loading.json` is declared in the pubspec and
  ships with the package, so hosts get it automatically — no asset declaration
  needed on their side. The bubble shows the animation next to
  `PrinterSdkConfig.loadingLabel`, whose default is now `Printing`.

### Platform scope

- **USB is Android-only.** `PrinterService.isSupported` no longer reports
  Android and Windows; it is Android-only, matching the platform's USB host
  API. On every other platform the SDK never touches the USB plugin and the
  Bluetooth/USB toggle in `CommonPrinterSettingScreen` is hidden, leaving the
  Bluetooth screen as the only option. A saved `USB` connection type is ignored
  on those platforms.
- The Android USB transport now lives in its own package,
  [`posprinter_usb_android`](patches/posprinter_usb_android), instead of a
  `dependency_overrides` path to `flutter_pos_printer_platform_image_3`. A path
  override never reaches the people who install this package from pub.dev, so
  they used to get the unpatched upstream plugin — including its Kotlin compile
  bug. The new package is Android-only, ships no iOS or Windows code, depends on
  nothing but Flutter, and is published on its own.
- Deleted the vendored `libGSDK.a`, the iOS podspec and the Windows CMake
  project, so an iOS build no longer compiles the USB plugin at all.
- `PrinterSdk.initialize` skips `PrinterService.init()` on platforms without USB
  host access, and `PrinterService.init()` itself returns early there.

### Build

- Fixed the Flutter warning "Your app uses the following plugins that apply
  Kotlin Gradle Plugin (KGP): flutter_pos_printer_platform_image_3, fluttertoast,
  network_info_plus". All three sources are gone:
  - the USB plugin was migrated to AGP built-in Kotlin
    (`android/build.gradle.kts`, `kotlin.compilerOptions`, no `apply plugin:
    'kotlin-android'`);
  - `fluttertoast` was removed from the dependency graph;
  - `network_info_plus` left the graph together with the unused network
    transport it belonged to.
- The published package now has 12 fewer direct and transitive dependencies
  (`fluttertoast`, `network_info_plus`, `ping_discover_network_forked`,
  `image_v3`, `enum_to_string`, `rxdart`, `nm`, `win32`, ...).
- Minimum supported versions are now Flutter 3.44 / Dart 3.12, required by
  `kotlin.compilerOptions`.

### UI

- Toasts no longer use `fluttertoast`. `showPrinterToast` renders a themed
  fade/slide toast in the host app's root overlay, so the SDK still does not
  depend on the host's `ScaffoldMessenger` and carries one dependency less. New
  `PrinterOverlay.attach(context)` lets host apps register the overlay from
  their own widgets; `hidePrinterToast()` and
  `showPrinterToastWithColor()` are available too.
- New `PrinterSdkConfig.bluetoothColor` / `bluetoothDarkColor` and `usbColor` /
  `usbDarkColor`, all configurable through `PrinterSdk.initialize`. They give
  the Bluetooth and USB connection types distinct, platform-neutral accents in
  the toggle, the hero card, the status cards, the action buttons and the device
  lists. `PrinterHeroCard`, `PrinterActionButton` and `PrinterDeviceTile` accept
  the accent as an optional parameter.

### Bluetooth on iOS

- Fixed the Bluetooth screen refusing to search on iOS. It gated scanning on
  `Permission.bluetoothScan` / `Permission.bluetoothConnect`, which are Android
  12+ runtime permissions: `permission_handler_apple` does not implement them
  and reports them *permanently denied*, so the search button did nothing and
  the screen showed a misleading "Bluetooth permissions are required" toast. The
  runtime request now happens only on Android; iOS relies on its own
  CoreBluetooth prompt (`NSBluetoothAlwaysUsageDescription`). New
  `BluetoothService.requiresRuntimePermissions` exposes the distinction, and
  `_hasBluetoothPermission()` uses it too.
- USB is hidden on iOS, so the SDK never touches the USB plugin there.

### Licensing

- `posprinter_usb_android` carries an MIT `LICENSE` that keeps the upstream
  `flutter_pos_printer_platform_image_3` copyright notice (MIT requires it) next
  to this project's own. Nothing is copied into this package's `LICENSE`, which
  stays plain MIT — a dependency's license does not need to be appended here.
  See the README section "License and third-party components".

### Package layout

- `patches/` (the plugin fork) is excluded from the published archive, and the
  local path override moved from `dependency_overrides` in `pubspec.yaml` to
  `pubspec_overrides.yaml`, so the published manifest has no path dependency and
  no override section.

### Previously unreleased

- USB printing now builds against the locally maintained plugin fork in
  `patches/posprinter_usb_android`. The fork fixes Android 13+ receiver
  registration, Android 14 mutable `PendingIntent` handling, USB permission
  handshakes and partial-chunk USB writes.
- A detached USB printer is now detected reliably, reconnect starts immediately
  when the device is plugged back in, and a stale USB endpoint is closed before
  retrying a failed print.
- USB settings screen simplified: tapping a discovered printer connects it
  automatically; the redundant Connect button was removed. The Disconnect action
  remains available while a printer is connected.
- Fixed a cold-start layout stall where the header and footer rendered but the
  USB body stayed blank until the app was backgrounded. The body now uses a
  list viewport and saved settings are restored before the first frame.
- The host footer now updates for automatic connects, detaches and reconnects
  (it previously kept showing "Connect a USB printer" after connecting).
- USB connection timeout raised to 20 seconds so the Android permission dialog
  can be answered without a premature failure.
- USB connection lifecycle is now handled by `PrinterService`: native detach
  detection, configurable auto-reconnect with backoff, lifecycle events
  (`connectionEvents`) and a single retry after a failed print job.
- Scanning while connected no longer disconnects the printer, and the saved
  printer is restored without printing a test receipt.
- `PrinterSdk.initialize` now subscribes to USB events immediately, so
  reconnection works app-wide instead of only while the settings screen is open.
- Rewritten USB settings screen: non-blocking reconnect banner, explicit
  reconnect action, stable selection state and up-to-date status cards.
- New `PrinterSdkConfig.autoReconnect`, `reconnectDelays` and
  `reconnectMaxAttempts` options.
- Bluetooth connection lifecycle is now handled by `BluetoothService`:
  `init()` restores the saved printer (including after a Flutter hot restart),
  a watchdog detects a dropped link, and reconnects use the same configurable
  backoff as USB. `statusStream`, `connectionEvents`, `reconnectSaved()`,
  `ensureConnected()` and `isReconnecting` mirror the USB API.
- `PrinterSdk.initialize` now also starts the Bluetooth service, so reconnection
  works before the settings screen is opened.
- `printBytes()` reconnects a stale Bluetooth link and retries the job once.
  Print jobs are serialized so two receipts cannot interleave.
- Bluetooth device discovery removes duplicate bonded entries (some Android
  builds list the built-in printer several times).
- Rewritten Bluetooth settings screen with the same hero, status grid,
  non-blocking reconnect banner, saved-printer state and action layout as the USB
  screen. The paper size no longer resets on rebuild.
- `BluetoothService.disconnect(clearSaved: false)` preserves the saved printer
  when switching to USB; switching back reconnects automatically.
- New `PrinterSdkConfig.bluetoothHealthCheckInterval` option (default 15 s).
  The plugin has no connection stream and probes the socket with a single space,
  so the watchdog is deliberately conservative and can be disabled with
  `Duration.zero`.
- `PrinterConnectionEvent` / `PrinterConnectionEventType` moved to a shared file
  and are now exported from the package root; the USB file re-exports them for
  source compatibility.

## 0.1.0

Initial public release.

- Premium, brandable `CommonPrinterSettingScreen` with a Bluetooth/USB toggle.
- Bluetooth discovery, connect, disconnect and ESC/POS test printing.
- USB discovery, auto-reconnect, connect, disconnect and ESC/POS test printing
  on Android and Windows.
- Configurable brand colors, copy, timeouts and paper sizes through
  `PrinterSdkConfig` and `PrinterSdk.initialize`.
- Persisted printer selection and paper size using Hive, opened lazily by the
  SDK.
- Toast-based feedback (no `ScaffoldMessenger` dependency) and themed dialogs.
- Responsive layouts that capture `MediaQuery` once per screen.
