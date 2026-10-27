import 'dart:async';
import 'dart:io';

import 'package:posprinter_usb_android/posprinter_usb_android.dart';

/// Input model that identifies a USB printer by vendor and product id.
class UsbPrinterInput extends BasePrinterInput {
  UsbPrinterInput({this.name, this.vendorId, this.productId});

  final String? name;
  final String? vendorId;
  final String? productId;
}

/// Detail of a USB printer as reported by Android.
class UsbPrinterInfo {
  UsbPrinterInfo.android({
    required this.vendorId,
    required this.productId,
    required this.manufacturer,
    required this.product,
    required this.name,
    required this.deviceId,
  });

  final String vendorId;
  final String productId;
  final String manufacturer;
  final String product;
  final String name;
  final String deviceId;
}

/// USB host transport for Android printers.
///
/// On every other platform [discovery] yields nothing, [connect] returns
/// `false` and the USB state stream is empty.
class UsbPrinterConnector implements PrinterConnector<UsbPrinterInput> {
  UsbPrinterConnector._() : vendorId = '', productId = '', name = '' {
    if (Platform.isAndroid) {
      flutterPrinterEventChannelUSB.receiveBroadcastStream().listen((dynamic data) {
        if (data is int && data >= 0 && data < USBStatus.values.length) {
          _status = USBStatus.values[data];
          _statusStreamController.add(_status);
        }
      });
    }
  }

  static final UsbPrinterConnector _instance = UsbPrinterConnector._();

  /// Shared connector instance.
  static UsbPrinterConnector get instance => _instance;

  Stream<USBStatus> get _statusStream => _statusStreamController.stream;
  final StreamController<USBStatus> _statusStreamController =
      StreamController<USBStatus>.broadcast();

  String vendorId;
  String productId;
  String name;
  USBStatus _status = USBStatus.none;

  /// Last state reported by Android.
  USBStatus get status => _status;

  void setVendor(String vendorId) => this.vendorId = vendorId;
  void setProduct(String productId) => this.productId = productId;
  void setName(String name) => this.name = name;

  /// USB state changes reported by Android.
  Stream<USBStatus> get currentStatus async* {
    if (Platform.isAndroid) {
      yield* _statusStream;
    }
  }

  /// One-shot discovery used by the [discoverPrinters] helper.
  static DiscoverResult<UsbPrinterInfo> discoverPrinters() async {
    if (!Platform.isAndroid) return <PrinterDiscovered<UsbPrinterInfo>>[];

    final List<dynamic> results =
        await flutterPrinterChannel.invokeMethod('getList');
    return results
        .map(
          (dynamic r) => PrinterDiscovered<UsbPrinterInfo>(
            name: (r['product'] ?? r['name'] ?? 'unknown device') as String,
            detail: UsbPrinterInfo.android(
              vendorId: '${r['vendorId']}',
              productId: '${r['productId']}',
              manufacturer: '${r['manufacturer']}',
              product: '${r['product']}',
              name: '${r['name']}',
              deviceId: '${r['deviceId']}',
            ),
          ),
        )
        .toList();
  }

  /// Stream of the USB printers that are attached right now.
  Stream<PrinterDevice> discovery() async* {
    if (!Platform.isAndroid) return;

    final List<dynamic> results =
        await flutterPrinterChannel.invokeMethod('getList');
    for (final dynamic entry in results) {
      final Map<dynamic, dynamic> device = entry as Map<dynamic, dynamic>;
      // Some USB devices report a null product name.
      final String name =
          (device['product'] ?? device['name'] ?? 'unknown device') as String;
      yield PrinterDevice(
        name: name,
        vendorId: device['vendorId'] as String?,
        productId: device['productId'] as String?,
      );
    }
  }

  Future<bool> _connect({UsbPrinterInput? model}) async {
    if (!Platform.isAndroid) return false;

    final Map<String, dynamic> params = <String, dynamic>{
      'vendor': int.parse(model?.vendorId ?? vendorId),
      'product': int.parse(model?.productId ?? productId),
    };
    final dynamic result =
        await flutterPrinterChannel.invokeMethod('connectPrinter', params);
    return result == true;
  }

  Future<bool> _close() async {
    if (!Platform.isAndroid) return false;

    try {
      final dynamic result = await flutterPrinterChannel.invokeMethod('close');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> connect(UsbPrinterInput model) async {
    try {
      return await _connect(model: model);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> disconnect({int? delayMs}) async {
    try {
      return await _close();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> send(List<int> bytes) async {
    if (!Platform.isAndroid) return false;

    try {
      final Map<String, dynamic> params = <String, dynamic>{'bytes': bytes};
      final dynamic result =
          await flutterPrinterChannel.invokeMethod('printBytes', params);
      return result == true;
    } catch (_) {
      return false;
    }
  }
}
