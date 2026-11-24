import 'package:signalr_netcore/itransport.dart';
import 'package:signalr_netcore/web_socket_transport.dart';
import 'transport_policy.dart';

ITransport secureWebSocket(TransportPolicy policy, String? credential) {
  if (policy.pin != null)
    throw UnsupportedError('Browser cannot verify a certificate pin.');
  return WebSocketTransport(
    credential == null ? null : () async => credential,
    null,
    false,
    null,
  );
}
