import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'printer_sdk_config.dart';

/// Keys persisted by the SDK.
///
/// The Bluetooth and USB keys intentionally keep their historical names so
/// existing installations continue to find their saved printer after upgrading.
abstract final class PrinterStorageKeys {
  static const String bluetoothMac = 'macid';
  static const String bluetoothName = 'device_name';
  static const String usbVendorId = 'vendorId';
  static const String usbProductId = 'productId';
  static const String usbPrinterName = 'printerName';
  static const String paperSize = 'printer_paper_size';
  static const String connectionType = 'printer_connection_type';
}

/// Tiny, dependency-injected friendly wrapper around the Hive box used by the
/// SDK.
///
/// Host apps can either let the SDK open the box lazily or call
/// [PrinterSdk.initialize] once during startup. If Hive cannot be initialized,
/// every read returns its default and the SDK keeps working in-memory.
class PrinterStorage {
  PrinterStorage._();

  static Box<dynamic>? _box;
  static Future<Box<dynamic>?>? _opening;

  /// Bumped after every write so widgets can rebuild when persisted values
  /// change (for example, when a printer is connected).
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Whether the backing box is open and ready for synchronous reads.
  static bool get isReady => _box?.isOpen ?? false;

  /// Opens (or reuses) the configured Hive box.
  ///
  /// Safe to call multiple times and from multiple screens: concurrent calls
  /// share the same opening future. If the host already opened the box or
  /// initialized Hive, its configuration is left untouched.
  static Future<Box<dynamic>?> ensureInitialized() {
    final Box<dynamic>? box = _box;
    if (box != null && box.isOpen) return Future<Box<dynamic>?>.value(box);
    return _opening ??= _open().whenComplete(() {
      _opening = null;
    });
  }

  static Future<Box<dynamic>?> _open() async {
    final String boxName = PrinterSdkConfig.hiveBoxName;
    try {
      if (Hive.isBoxOpen(boxName)) {
        _box = Hive.box<dynamic>(boxName);
        return _box;
      }

      // Reuse an already initialized Hive (and its custom path) when present.
      // Hive's interface does not expose `homePath`, so read it dynamically to
      // avoid re-initializing (and overriding) a host app's custom path.
      final String? homePath =
          // ignore: avoid_dynamic_calls
          (Hive as dynamic).homePath as String?;
      if (homePath == null) {
        await Hive.initFlutter();
      }
      _box = await Hive.openBox<dynamic>(boxName);
    } catch (_) {
      // In-memory fallback: the SDK remains usable, it just forgets settings
      // between launches.
      _box = null;
    }
    return _box;
  }

  /// Reads a value, returning [defaultValue] when storage is unavailable.
  static T? read<T>(String key, {T? defaultValue}) {
    final Box<dynamic>? box = _box;
    if (box == null || !box.isOpen) return defaultValue;
    final dynamic value = box.get(key, defaultValue: defaultValue);
    return value is T ? value : defaultValue;
  }

  /// Reads a boolean with a sensible default.
  static bool readBool(String key, {bool defaultValue = false}) =>
      read<bool>(key, defaultValue: defaultValue) ?? defaultValue;

  /// Reads a string with a sensible default.
  static String readString(String key, {String defaultValue = ''}) =>
      read<String>(key, defaultValue: defaultValue) ?? defaultValue;

  /// Writes a value and notifies listeners.
  static Future<void> write(String key, Object? value) async {
    final Box<dynamic>? box = await ensureInitialized();
    if (box == null) return;
    await box.put(key, value);
    revision.value++;
  }

  /// Deletes a value and notifies listeners.
  static Future<void> delete(String key) async {
    final Box<dynamic>? box = await ensureInitialized();
    if (box == null) return;
    await box.delete(key);
    revision.value++;
  }

  /// Removes every key owned by the SDK.
  static Future<void> clear() async {
    final Box<dynamic>? box = await ensureInitialized();
    if (box == null) return;
    await box.deleteAll(<String>[
      PrinterStorageKeys.bluetoothMac,
      PrinterStorageKeys.bluetoothName,
      PrinterStorageKeys.usbVendorId,
      PrinterStorageKeys.usbProductId,
      PrinterStorageKeys.usbPrinterName,
      PrinterStorageKeys.paperSize,
      PrinterStorageKeys.connectionType,
    ]);
    revision.value++;
  }
}
