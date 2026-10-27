# Development log — posprinter_thermal

Living document for restoring context quickly. Read this before changing
dependencies or Gradle configuration, and append an entry whenever you make a
build-affecting change.

**Last updated:** 2026-10-27

---

## How to use this file

1. Start with [Current status](#current-status) and
   [Open issues / next steps](#open-issues--next-steps).
2. Check [Pinned dependencies](#pinned-dependencies) before running
   `flutter pub upgrade`.
3. After fixing something, add a dated entry to
   [Session log](#session-log) with symptom → root cause → fix → verification.

---

## Project snapshot

`posprinter_thermal` is a Flutter **SDK/package** (not just an app) for
Bluetooth and USB thermal printers. It ships reusable screens, Hive-backed
settings, ESC/POS test printing, and a themeable widget set.

| Area | Location |
|---|---|
| Public API / entry point | `lib/pos_printer_sdk.dart` |
| Run-only demo app | `lib/main.dart` |
| Bluetooth service + screen | `lib/common_printer_service/bluetooth_printer_service/` |
| USB service + screens | `lib/common_printer_service/usb_printer_service/` |
| Branding/config | `lib/common_printer_service/printer_sdk_config.dart` |
| Persistence (Hive) | `lib/common_printer_service/printer_storage.dart` |
| Android shell | `android/` |
| Minimal pub.dev example | `example/` (no Android/iOS shells) |
| Android USB plugin (own package) | `patches/posprinter_usb_android/` |
| Local path override | `pubspec_overrides.yaml` (repo root and `example/`) |
| Task shortcuts | `Taskfile.yml` |

Supported platforms: Android (Bluetooth + USB), iOS (Bluetooth only),
Windows (Bluetooth only), macOS/Linux/Web (Bluetooth only, limited support).
USB is Android-only: `PrinterService.isSupported` is true only there, the
connection-type toggle is hidden elsewhere and the USB plugin ships no iOS or
Windows code.

---

## Environment (verified 2026-10-26)

| Tool | Version |
|---|---|
| Flutter | 3.47.8 (stable) |
| Dart | 3.13.7 |
| Android Gradle Plugin | 9.0.1 |
| Gradle wrapper | 9.1.0 |
| Kotlin Gradle Plugin | 2.3.20 |
| JDK | 17 (Android Studio bundled) |
| App `compileSdk` / `targetSdk` / `minSdk` | 36 / 36 / 24 (`flutter.*` defaults) |
| Installed Android platform | `android-37.0`, `android-36` |
| Android build-tools | 36.1.0 |

Relevant template flags in `android/gradle.properties` (added by the Flutter
template, do not remove casually):

```properties
android.newDsl=false
android.builtInKotlin=false
```

---

## Current status

| Check | Result |
|---|---|
| `flutter pub get` | ✅ |
| `flutter analyze` | ✅ No issues found |
| `flutter test` | ✅ 15 tests pass |
| Plugin `flutter analyze` / `flutter test` | ✅ Clean / 4 tests pass (`patches/posprinter_usb_android`) |
| Plugin example `flutter analyze` / `flutter test` / `flutter build apk --debug` | ✅ Clean / 1 test passes / builds |
| `flutter build apk --debug` | ✅ Builds `build/app/outputs/flutter-apk/app-debug.apk`; no KGP warning |
| `dart pub publish --dry-run` | ✅ 1 warning (no homepage) + 1 hint (path override); archive is clean |
| Release APK / App Bundle | ⚠️ Not verified after the 2026-10-23 dependency changes |
| Physical-device USB printing | ✅ Verified on `23043RP34I` (connect, print, detach/replug) |
| Physical-device Bluetooth printing | ✅ Verified on `I23M01` (cold start, hot restart, link-loss reconnect, test print) |
| iOS build | ⚠️ Not verified |

---

## Pinned dependencies

Do **not** remove these pins without re-testing an Android build.

| Package | Pin | Why |
|---|---|---|
| `permission_handler` | `^12.0.3` | 13.x pulls `permission_handler_android` 14.x, which requires `compileSdk 37`. API 37 is only published as `android-37.0`, which AGP 9.0.1 cannot resolve. |
| `posprinter_usb_android` | `^1.0.0` + local path override | Upstream `flutter_pos_printer_platform_image_3` is unmaintained. The Android USB transport is maintained here as its own package, `patches/posprinter_usb_android`; it fixes the USB permission handshake, attach/detach events, partial writes and stale endpoints. The path override lives in `pubspec_overrides.yaml`, so the published manifest stays free of path dependencies. |

Resolved versions today:

| Package | Resolved |
|---|---|
| `permission_handler` | 12.0.3 |
| `permission_handler_android` | 13.0.1 (`compileSdk 35`) |
| `posprinter_usb_android` | 1.0.0, path override (`compileSdk` from `flutter.compileSdkVersion`) |
| `print_bluetooth_thermal` | 1.2.5 |
| `hive` | 2.2.3 |

Removed from the graph on 2026-10-27: `fluttertoast`, `network_info_plus`,
`network_info_plus_platform_interface`, `ping_discover_network_forked`,
`image_v3`, `enum_to_string`, `rxdart`, `nm`, `win32`, `dbus`,
`ffi_leak_tracker`.

Removal conditions:

- `permission_handler`: upgrade once `permission_handler_android` builds against
  `android-37.0` with a supported AGP, or once a 13.x patch no longer requires
  SDK 37. Track <https://github.com/baseflow/flutter-permission-handler/issues/1556>.
- `posprinter_usb_android`: keep this repo's checkout (and the local path
  override) in sync with the published package. Revisit upstream only if a
  maintained release fixes the Kotlin and USB lifecycle regressions.
- `android/build.gradle.kts` compileSdk override: remove when all plugins ship
  a `compileSdk` of 34+ (ideally 36). It is now a no-op for the USB plugin,
  which uses `flutter.compileSdkVersion`.

---

## Session log

### 2026-10-27 — USB restricted to Android, KGP warning cleared, plugin published as its own package

**Symptom**

```text
WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin
(KGP): flutter_pos_printer_platform_image_3, fluttertoast, network_info_plus
Future versions of Flutter will fail to build if your app uses plugins that
apply KGP.
```

Plus: USB was offered on platforms that cannot use it, an iOS build pulled the
USB plugin's vendored `libGSDK.a`, and the whole USB stack reached consumers
only through a `dependency_overrides` path — which pub ignores for anyone who
installs the package, so they got the unpatched upstream plugin (including the
`USBPrinterService.kt` compile bug fixed on 2026-10-23).

**Root cause**

- Flutter's `detectApplyingKotlinGradlePlugin` regex-scans each plugin's
  Android build script for a KGP declaration. Three modules matched:
  - `flutter_pos_printer_platform_image_3` (`apply plugin: 'kotlin-android'` in
    the vendored Groovy `build.gradle`);
  - `fluttertoast` 10.0.2 (`id("org.jetbrains.kotlin.android")` in its
    `plugins {}` block);
  - `network_info_plus` 4.1.0+1, which the USB plugin pulled in for its TCP
    transport (`apply plugin: 'kotlin-android'`).
- `PrinterService.isSupported` was true on Android **and Windows**, and the
  plugin's iOS pod was still declared, so an iOS build compiled the plugin's
  iOS sources and static library for a feature iOS cannot use.
- `pubspec.yaml` resolved the USB plugin from `patches/...` via
  `dependency_overrides`. Overrides are read from the *root* package only, so
  consumers always resolved the pub.dev release.

**Fix**

1. The plugin became its own package: `patches/posprinter_usb_android`
   (version `1.0.0`), Android-only, MIT with the upstream notice retained.
   - `flutter.plugin.platforms` declares `android` only; the `ios/` directory
     (podspec + `libGSDK.a`) and `windows/` were deleted.
   - The Dart surface was reduced to the USB transport: the Bluetooth/BLE and
     TCP connectors, the Star/TSPL/ESC-POS generators and `utils.dart` are gone,
     so the package depends on nothing but Flutter (previously `rxdart`,
     `image_v3`, `enum_to_string`, `network_info_plus`,
     `ping_discover_network_forked`).
   - `PrinterType` now only has `usb`; `PrinterManager` only exposes USB; the
     `FlutterPosPrinterPlatformPlugin` Kotlin file was rewritten USB-only and the
     dead `USBPrinterAdapter`/`UsbReceiver`/`bluetooth`/`models` sources removed.
   - The plugin manifest no longer declares Bluetooth, Bluetooth-admin or
     location permissions, so they cannot be merged into host apps; it declares
     `android.hardware.usb.host` (`required="false"`).
   - `android/build.gradle` (Groovy, AGP 7.1.2/KGP 1.6.20 classpath) was replaced
     by `android/build.gradle.kts` with `plugins { id("com.android.library") }`,
     `compileSdk = flutter.compileSdkVersion` and a `kotlin.compilerOptions`
     block — no KGP application.
   - Its example app was rewritten as an Android USB demo and its Android shell
     migrated off KGP too.
2. Bluetooth on iOS was broken independently of USB, and was fixed in the same
   pass. `BluetoothPrinterSettings` gated scanning on
   `Permission.bluetoothScan` / `Permission.bluetoothConnect`. Those are Android
   12+ runtime permissions: `permission_handler_apple` has no case for them and
   falls through to `UnknownPermissionStrategy`, whose `checkPermissionStatus`
   returns `PermissionStatusDenied` and `requestPermission` returns
   `PermissionStatusPermanentlyDenied`. On iOS that left `_isPermissionGranted`
   `false`, so `_scan()` returned early and the screen showed "Bluetooth
   permissions are required…" while the search button did nothing. Added
   `BluetoothService.requiresRuntimePermissions` (Android only), used it in both
   `_ensurePermissions` and `_hasBluetoothPermission`, and left iOS to its own
   CoreBluetooth prompt.
3. This package (`posprinter_thermal`):
   - depends on `posprinter_usb_android: ^1.0.0`; the local checkout is wired up
     through `pubspec_overrides.yaml` (root and `example/`), so no path
     dependency or override section reaches the published manifest;
   - `PrinterService.isSupported` is Android-only, `PrinterService.init()`
     returns early elsewhere and `PrinterSdk.initialize` skips USB init there;
   - `CommonPrinterSettingScreen` hides the connection-type toggle when USB is
     unsupported and ignores a saved USB mode;
   - `fluttertoast` was dropped. `showPrinterToast` now renders a fade/slide
     toast from an `OverlayEntry` in the host's root overlay, with
     `PrinterOverlay.attach(context)` called by both settings screens;
   - new `bluetoothColor`/`bluetoothDarkColor` and `usbColor`/`usbDarkColor`
     config (plus `PrinterSdk.initialize` parameters) are threaded through the
     toggle, hero cards, status cards, action buttons and device tiles;
   - `patches/`, `example/pubspec_overrides.yaml` and the host shells are
     excluded from the published archive via `.pubignore`, and `patches/**` is
     excluded from the root analyzer config.

**Verification**

```bash
flutter pub get                 # 12 dependencies dropped
flutter analyze                 # No issues found!
flutter test                    # 15 tests pass
flutter build apk --debug       # app-debug.apk, 41.8s
#   grep -i "apply Kotlin Gradle Plugin" -> no match (warning gone)

dart pub publish --dry-run      # 1 warning (no homepage) + 1 hint (path override)

cd patches/posprinter_usb_android
flutter analyze                 # No issues found!
flutter test                    # 4 tests pass
dart pub publish --dry-run      # 1 warning (no homepage)

cd patches/posprinter_usb_android/example
flutter analyze && flutter test # clean / 1 test passes
flutter build apk --debug       # app-debug.apk, no KGP warning
```

The Kotlin sources really were recompiled by the new build script
(`build/posprinter_usb_android/tmp/kotlin-classes/.../FlutterPosPrinterPlatformPlugin.class`),
and Gradle's own problems report no longer lists `fluttertoast`,
`network_info_plus` or the old plugin path.

**Follow-up**

- Publish `patches/posprinter_usb_android` **before** `posprinter_thermal`, then
  `flutter pub get` and confirm `posprinter_usb_android` resolves from pub.dev.
- Hardware re-verification is still pending for USB (the plugin's Dart API is
  unchanged, but the package it comes from is not) and for iOS Bluetooth.
- Renaming the Android `namespace` and method-channel names away from
  `com.sersoluciones.flutter_pos_printer_platform` was deliberately **not** done:
  it is cosmetic, and MIT only requires the copyright notice (which is kept).
  Worth doing if the fork ever diverges materially.
- `android.builtInKotlin=false` was kept (the `flutter create` default). Setting
  it to `true` would clear Gradle's remaining `kgp:deprecation` advisories; see
  the note above.

### 2026-10-26 — Bluetooth auto-reconnect and screen rewrite (I23M01)

**Symptom**

- After a Flutter hot restart the Bluetooth printer was forgotten: the saved MAC
  was still in Hive, but nothing reconnected, so the screen showed
  `Not connected` until the user searched and tapped the printer again.
- A printer that dropped while the app was idle kept showing `Connected`.
- The Bluetooth screen used the old status-card/action-bar layout, captured
  `MediaQuery` once, and did not expose a reconnect banner or retry action.
- `pairedBluetooths` returns the built-in `InnerPrinter` many times on this
  Android build, so the device list was duplicated.

**Root cause**

- `BluetoothService` was a stateless bridge. It had no process-wide init, no
  saved-printer restore, no connection watchdog and no reconnect loop. Static
  fields (`bluetoothIsConnected`, `connectedPrinterName`) are reset by a hot
  restart, and the native plugin usually closes its socket when the engine
  detaches, so the link had to be opened again.
- The plugin exposes only a polling `connectionStatus` probe (it writes a single
  space to the socket); there is no connection event stream.

**Fix**

- Added `BluetoothService.init()` with a one-time lifecycle:
  - loads `macid` / `device_name` from Hive;
  - verifies whether the native socket survived (hot restart) before opening a
    second one;
  - otherwise starts the same backoff loop as USB
    (`PrinterSdkConfig.reconnectDelays` / `reconnectMaxAttempts`);
  - reconnects when the app returns to the foreground.
- Added `statusStream`, `connectionEvents`, `reconnectSaved()`,
  `ensureConnected()`, `isReconnecting` and `disconnect(clearSaved:)` mirroring
  `PrinterService`.
- Added `PrinterSdkConfig.bluetoothHealthCheckInterval` (default 15 s, `zero`
  disables). Documented that the plugin probe writes one space, hence the
  conservative interval.
- `printBytes()` now reconnects a stale link and retries once; jobs are
  serialized.
- Device discovery de-duplicates by MAC.
- `PrinterSdk.initialize()` starts the Bluetooth service; `PrinterSdk.dispose()`
  stops it.
- Rewrote `BluetoothPrinterSettings` as a stateless-looking view over the
  service: hero card, status grid, non-blocking reconnect banner, saved-printer
  state, Search / Test print / Disconnect actions, and a live device list.
  `MediaQuery` is read during build and host footer updates are coalesced into
  post-frame callbacks.
- The connection-type toggle now calls `disconnect(clearSaved: false)` when
  leaving Bluetooth, so switching back reconnects automatically.
- Moved `PrinterConnectionEvent` to
  `lib/common_printer_service/printer_connection_event.dart`; the USB service
  re-exports it.

**Verification (I23M01, Android 13, wireless ADB)**

```text
flutter analyze lib test   -> No issues found
flutter test               -> 12 tests passed (2 new Bluetooth reconnect tests)
flutter build apk --debug  -> app-debug.apk
```

Automated coverage added in `test/bluetooth_reconnect_test.dart`. It fakes the
plugin's `MethodChannel('groons.web.app/print')`, restores a saved printer,
drops the link, and asserts the backoff loop starts, keeps retrying, then
reconnects and emits `PrinterConnectionEventType.reconnected` once the printer
answers again. This covers the "printer service comes back" leg deterministically
on CI, without hardware.

On-device results:

- Cold start with saved `InnerPrinter` (00:11:22:33:44:55) → auto-connected
  (`result status connect: true`) without tapping anything.
- Machine-protocol `app.restart` (hot restart) → auto-connected again; the UI
  showed `Connected` with the same PID.
- `am force-stop com.imin.printerservice` (closes the virtual Bluetooth socket)
  → watchdog noticed within one interval, showed the reconnect banner, marked
  the printer `Saved`, and kept retrying with the configured backoff.
- Test print → reached the built-in printer (`PrintPortWriteT` in logcat) with
  the success toast.
- Device list showed 4 unique entries instead of 20 duplicate `InnerPrinter`
  rows.
- After a device reboot (wireless ADB re-enabled) the app auto-connected again
  on cold start, and the screen rendered the new hero card, status grid,
  deduplicated list and footer without layout overflow.

**Follow-up**

- Do **not** use `am crash com.imin.printerservice` to simulate a dropped link:
  the package runs as uid 1000 (system), and crashing it took `system_server`
  down with it, rebooting the device and dropping wireless ADB. Use
  `am force-stop` (needs a reboot to restore the service) or the automated
  channel test instead.
- Consider replacing `print_bluetooth_thermal` with a plugin that exposes a
  connection event stream and a non-destructive status check.
- `svc bluetooth disable` does **not** drop this device's `InnerPrinter`: it is
  a virtual printer served by `com.imin.printerservice` over a `LocalSocket`,
  not a real BR/EDR printer. Use the printer service for link-loss tests.

### 2026-10-26 — USB reconnect, Disconnect action and cold-start layout

**Symptom**

- The USB settings screen had no way to disconnect once connected.
- Unplugging the printer and plugging it back in did not reliably reconnect.
- After a cold launch the header and footer rendered, but the USB body stayed
  blank until the app was backgrounded or hot-reloaded.

**Root cause**

- The vendor plugin resolved the permission request before Android granted it,
  missed attach/detach broadcasts and could leave stale endpoints after a
  detach. Writes larger than the USB packet size were also truncated.
- The USB body used a large `SingleChildScrollView` whose first layout
  intermittently stalled on this Android 14 device, leaving a blank body until
  the app was backgrounded or hot-reloaded. The screen also captured
  `MediaQuery` once, so its breakpoints could stay stale.
- Status callbacks rebuilt the host scaffold immediately, including while the
  child was laying out.

**Fix**

- Build against the vendored `1.2.4` fork via `dependency_overrides`:
  explicit `RECEIVER_NOT_EXPORTED`/mutable `PendingIntent`, a permission
  handshake that completes only on grant/deny, `USBStatus.attached`, immediate
  reconnect on replug, chunked writes and `closeConnectionIfExists()` on
  disconnect.
- Tapping a discovered USB device connects; **Disconnect** appears only while
  connected and clears auto-reconnect. Scan and Test print remain available.
- Use a `ListView` for the USB body, read `MediaQuery` during build, restore
  saved settings synchronously when storage is ready, and coalesce host footer
  notifications into post-frame callbacks.

**Verification**

```bash
flutter analyze lib test        # No issues found
flutter test                    # 10 tests pass
flutter build apk --debug       # app-debug.apk
```

On `23043RP34I` (Android 14, USB VID `8137` / PID `8214`):

- five consecutive force-stop/start cycles rendered the full USB screen;
- Disconnect logged native `method call close`, cleared the saved printer and
  updated the footer;
- tapping the listed device reconnected and the footer returned to
  `USB Printer P is connected and ready to print.`;
- test print logged `Printing bytes` followed by `Return code: 21`;
- a real unplug/replug logged `USB detached`, reconnect attempts, `USB
  attached`, immediate `connectPrinter` and a `reconnected` toast.

**Follow-up**

- Repeat the physical unplug/replug check after the next build (the reconnect
  logic itself is unchanged).
- Test Bluetooth printing on hardware and verify release builds.

### 2026-10-26 — Flutter 3.47 Gradle plugin-apply migration

**Symptom**

```text
Script '.../flutter_tools/gradle/app_plugin_loader.gradle' line: 9
You are applying Flutter's app_plugin_loader Gradle plugin imperatively ...
```

**Root cause**

Flutter 3.47 removed the imperative `apply from:` entry points. The main app
already used `android/settings.gradle.kts` with `dev.flutter.flutter-plugin-loader`,
but the vendored patch example still had the old Groovy settings and
`app/build.gradle` that applied `app_plugin_loader.gradle` and `flutter.gradle`.

**Fix**

Migrated `patches/flutter_pos_printer_platform_image_3-1.2.4/example/android`
to the declarative plugin DSL:

- `settings.gradle.kts` with `dev.flutter.flutter-plugin-loader`, AGP `9.0.1`
  and Kotlin `2.3.20`;
- `build.gradle.kts` without `buildscript` classpaths;
- `app/build.gradle.kts` with a `plugins {}` block and no `apply from:`;
- Gradle wrapper `9.1.0`, Java/JVM target 17, namespace instead of the manifest
  `package` attribute.

The main `android/` directory needed no change — it was already migrated.

**Verification**

```bash
cd patches/flutter_pos_printer_platform_image_3-1.2.4/example/android
./gradlew help   # BUILD SUCCESSFUL with Gradle 9.1.0

grep -R "app_plugin_loader.gradle" android   # no matches
```

**Note**

The first local `flutter build apk --debug` after the Flutter upgrade also
failed with `No space left on device` (1.1 GB free on the data volume). The
automatic retry succeeded, but free disk space before the next device run.

### 2026-10-26 — USB connection loss / reconnect rewritten

**Symptom**

After a USB cable pull the old `PrinterService` only updated its state while a
scan was active. The settings screen showed a stale `Connected` state, scanning
called `disconnect()`, `connectSaved()` printed a test receipt, and reconnect
required app-specific kiosk-mode code (unpin/repin) plus a `GetX` dialog.

**Root cause**

`stateUSB` was subscribed inside `scan()` instead of for the process lifetime;
`_waitForConnected()` listened to a broadcast stream after `connect()` had
already emitted the event; and the saved printer was cleared on every manual
disconnect. Connection ownership was split between the service, the screen and
a host-app watcher.

**Fix**

- `PrinterService.init()` now owns a single process-wide `stateUSB`
  subscription.
- Unexpected `connected → none` transitions emit
  `PrinterConnectionEventType.disconnected` and start a configurable backoff
  (`PrinterSdkConfig.reconnectDelays` / `reconnectMaxAttempts`). Reconnects use
  the persisted printer directly, with no scan and no test print.
- `scan()` no longer resets/disconnects; `printBytes()` serializes jobs and
  retries once after reconnecting.
- Manual `disconnect()` stops the loop; `clearSaved: false` keeps the record.
- `PrinterSdk.initialize()` calls `PrinterService.init()` so detach detection
  exists before the settings screen is opened.
- Rewrote `PrinterSettingScreen` as a stateless view over the service: status
  stream + `connectionEvents`, non-modal reconnect banner, retry button, and no
  kiosk-mode dependency.
- Removed the app-specific watcher requirement. Host apps that still want a
  dialog can listen to `PrinterService.connectionEvents`; nothing needs to
  unpin kiosk mode.

**Files**

`lib/common_printer_service/usb_printer_service/printer_services/printer_service.dart`,
`.../printer_setting_screen.dart`, `lib/common_printer_service/printer_sdk_config.dart`,
`lib/common_printer_service/printer_sdk.dart`, `README.md`, `CHANGELOG.md`.

**Verification**

```text
flutter analyze lib test  -> No issues found
flutter test              -> 10 tests passed
```

Hardware verification (cable pull → banner → auto reconnect → retry print) still
needs a real Android device.

### 2026-10-23 — Android build blocked by `permission_handler` / SDK 37

**Symptom**

```text
The plugin permission_handler_android requires Android SDK version 37 or higher.
...
Failed to find target with hash string 'android-37' in: .../Android/sdk
```

**Root cause**

`permission_handler` 13.0.2 resolves `permission_handler_android` 14.1.0, whose
`android/build.gradle.kts` declares `compileSdk = 37`. Android publishes API 37
only as `android-37.0` (new minor-version SDK naming); AGP 9.0.1 still looks up
the hash string `android-37`, so dependency resolution fails. There is no
`platforms;android-37` package to install.

**Fix**

Downgraded to the 12.x line, whose Android implementation compiles against SDK
35:

```yaml
permission_handler: ^12.0.3
```

The app's own `compileSdk` stays at `flutter.compileSdkVersion` (36). Setting
`compileSdk = 37` in `android/app/build.gradle.kts` does **not** help and
introduces the same hash-string failure.

### 2026-10-23 — `flutter_pos_printer_platform_image_3` 1.2.4 does not compile

**Symptom**

```text
e: .../USBPrinterService.kt:41:25 Unresolved reference 'connectDevice'.
e: .../USBPrinterService.kt:43:31 Unresolved reference 'TAG'.
e: .../USBPrinterService.kt:48:23 Unresolved reference 'TAG'.
> Execution failed for task ':flutter_pos_printer_platform_image_3:compileDebugKotlin'.
```

**Root cause**

Upstream 1.2.4 calls `connectDevice()` and `TAG` inside the USB permission
`BroadcastReceiver`. Neither symbol exists in that class (only `openConnection()`
and `LOG_TAG` do). 1.2.3 compiles.

**Fix**

```yaml
flutter_pos_printer_platform_image_3: 1.2.3
```

Trade-off: 1.2.3 marks USB as connected on permission grant without opening the
connection. Printing still calls `openConnection()`, so the practical impact is
limited to status reporting. Report the 1.2.4 regression upstream.

### 2026-10-23 — AAR metadata rejects plugins with old `compileSdk`

**Symptom**

```text
Dependency 'androidx.annotation:annotation-experimental:1.4.0' requires ...
compile against version 34 or later.
:network_info_plus is currently compiled against android-33.
```

(Equivalent errors for `flutter_pos_printer_platform_image_3`, compiled
against 31.)

**Root cause**

Plugins hardcode an old `compileSdkVersion` in their own Gradle files while
their AndroidX dependencies require 34+. The host app's `compileSdk` does not
change a plugin module's `compileSdk`.

**Fix**

`android/build.gradle.kts` now raises the `compileSdk` of every plugin module
below 36 to 36 in `afterEvaluate`, leaving `targetSdk` untouched:

```kotlin
subprojects {
    if (name == "app") return@subprojects
    afterEvaluate {
        val androidExtension = extensions.findByName("android") ?: return@afterEvaluate
        val desiredCompileSdk = 36
        when (androidExtension) {
            is com.android.build.api.dsl.LibraryExtension -> { /* compileSdk = 36 */ }
            is com.android.build.gradle.BaseExtension -> { /* compileSdkVersion(36) */ }
        }
    }
}
```

Note: the existing `evaluationDependsOn(":app")` in the same file eagerly
evaluates `:app`, so the subproject must skip it before calling
`afterEvaluate`.

**Important for consumers:** this override lives in this repository's Android
shell. A host app that depends on the published package will need the same
workaround until the plugins are fixed. If that becomes a blocker, replace the
USB plugin with a better-maintained package.

### Resolved 2026-10-27 — the "plugins that apply KGP" warning

The warning listed `flutter_pos_printer_platform_image_3`, `fluttertoast` and
`network_info_plus`. All three are gone: the USB plugin was migrated to built-in
Kotlin, `fluttertoast` was removed from the dependency graph, and
`network_info_plus` left the graph with the unused network transport it belonged
to. Verified with a clean `flutter build apk --debug` (see the session log).

Gradle's own problems report still shows an advisory
(`The 'org.jetbrains.kotlin.android' plugin in project ':x' is no longer
required`) for `:app`, `:jni`, `:jni_flutter`, `:permission_handler_android`,
`:posprinter_usb_android` and `:print_bluetooth_thermal`. That is a different
signal: none of those declares KGP any more; the plugin is auto-applied by
Flutter because `android.builtInKotlin=false` (still the `flutter create`
default). Setting that property to `true` removes the advisories, but it is a
separate app-level migration and is not required to clear the warning above.

---

## Commands

```bash
# Dependencies
flutter pub get

# Quality gates
flutter analyze
flutter test

# The Android USB plugin is a separate package
cd patches/posprinter_usb_android
flutter analyze && flutter test && dart pub publish --dry-run
cd example && flutter analyze && flutter test && flutter build apk --debug
cd ..

# Local path override for the plugin (edit both when it moves)
#   ./pubspec_overrides.yaml
#   ./example/pubspec_overrides.yaml

# Debug build (same path the failing `flutter run` used)
flutter build apk --debug

# Run on a device/emulator
flutter run -d <device-id>

# Release checks before publishing
flutter build apk --release
flutter build appbundle --no-tree-shake-icons
dart pub publish --dry-run
```

`Taskfile.yml` also exposes `task apk`, `task appbundle`, `task deployA`, etc.
Note that `task get` runs `flutter clean` first, which makes the next build
noticeably slower.

---

## Open issues / next steps

1. **Remaining hardware coverage** — Bluetooth reconnect (cold start, hot
   restart, link loss + recovery) and USB connect/print/replug are verified on
   `I23M01` and `23043RP34I`. Still unverified: iOS, Windows Bluetooth, and the
   Android 11-and-below permission branch.
2. **Verify release builds** — debug builds pass; confirm `flutter build apk
   --release` and `flutter build appbundle --no-tree-shake-icons`.
3. **Maintain the USB plugin** — the Android USB transport is forked under
   `patches/posprinter_usb_android` with the Kotlin/USB lifecycle fixes, and
   released as its own package. Keep this checkout in sync with the published
   version and report the upstream regressions if a release appears.
4. **Watch `permission_handler` upstream** — remove the 12.x pin when the SDK 37
   resolution issue is fixed.
5. ~~**Track the KGP warning**~~ — resolved 2026-10-27. No plugin in the graph
   declares KGP any more. Remaining: Gradle's `kgp:deprecation` advisories, which
   would need `android.builtInKotlin=true` (an app-level migration).
6. **Publish the plugin first** — `patches/posprinter_usb_android` is a normal
   dependency now. Publish it, then this package; `pubspec_overrides.yaml` keeps
   local development working either way.
7. **Re-verify on hardware** — USB connect/print/replug against the new package,
   and iOS Bluetooth (the toggle now hides USB there).
8. **Publish readiness** — set real `homepage`/`repository`/`issue_tracker`,
   update `CHANGELOG.md`, run `dart pub publish --dry-run`.

---

## Session log template

```markdown
### YYYY-MM-DD — Short title

**Symptom**
What failed, with the relevant log line.

**Root cause**
Why it failed (package version, Gradle behavior, platform limitation, ...).

**Fix**
Files changed and why. Include before/after commands or configuration.

**Verification**
Exact commands run and their result.

**Follow-up**
Anything to revisit, remove, or report upstream.
```
