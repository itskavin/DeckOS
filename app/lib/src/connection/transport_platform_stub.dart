import 'package:dio/dio.dart';
import 'transport_policy.dart';

// Browsers enforce their own CA/hostname validation and cannot inspect peer certificates.
// A QR pin cannot be enforced in a browser: never claim that it is.
void configureDio(Dio dio, TransportPolicy policy) {
  if (policy.pin != null)
    throw UnsupportedError(
      'Use the native DeckOS app for certificate-pinned pairing.',
    );
}
