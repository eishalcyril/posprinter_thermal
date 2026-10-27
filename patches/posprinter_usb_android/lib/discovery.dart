import 'package:posprinter_usb_android/posprinter_usb_android.dart';

/// A printer found by a discovery pass, with its transport-specific detail.
class PrinterDiscovered<T> {
  PrinterDiscovered({required this.name, required this.detail});

  final String name;
  final T detail;
}

/// Result of a discovery mode: the printers it found.
typedef DiscoverResult<T> = Future<List<PrinterDiscovered<T>>>;

/// Runs every function in [modes] and returns all the printers they found.
///
/// Only USB discovery is implemented by this package, so the default is the
/// USB connector on its own.
Future<List<PrinterDiscovered<dynamic>>> discoverPrinters({
  List<DiscoverResult<dynamic> Function()> modes =
      const <DiscoverResult<dynamic> Function()>[
        UsbPrinterConnector.discoverPrinters,
      ],
}) async {
  final List<PrinterDiscovered<dynamic>> result =
      <PrinterDiscovered<dynamic>>[];
  await Future.wait(
    modes.map((DiscoverResult<dynamic> Function() mode) async {
      result.addAll(await mode());
    }),
  );
  return result;
}
