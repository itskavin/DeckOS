import 'dart:io';
import 'package:http/io_client.dart';
import 'package:http/http.dart' as http;

/// Resolve once, reject every private/reserved result, then connect to that
/// address. HttpClient still performs normal CA and original-hostname TLS.
http.Client createBillingHttpClient() {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (uri.scheme != 'https' || proxyHost != null) {
      throw const SocketException('Billing requires direct HTTPS');
    }
    final addresses = await InternetAddress.lookup(
      uri.host,
    ).timeout(const Duration(seconds: 10));
    if (addresses.isEmpty || addresses.any((a) => !isPublicBillingAddress(a))) {
      throw const SocketException('Billing requires public DNS addresses');
    }
    return Socket.startConnect(addresses.first, uri.port);
  };
  return IOClient(client);
}

bool isPublicBillingAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return !(b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        b[0] >= 224 ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 &&
            (b[1] == 168 || b[1] == 0 || (b[1] == 88 && b[2] == 99))) ||
        (b[0] == 198 &&
            (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100))) ||
        (b[0] == 203 && b[1] == 0 && b[2] == 113));
  }
  // IPv6 global unicast only; reject special 2001::/23, documentation,
  // 6to4 and all IPv4-mapped/link-local/ULA/loopback forms.
  return (b[0] & 0xe0) == 0x20 &&
      !(b[0] == 0x20 && b[1] == 0x01 && b[2] < 2) &&
      !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) &&
      !(b[0] == 0x20 && b[1] == 0x02) &&
      !(b[0] == 0x3f && b[1] == 0xff);
}
