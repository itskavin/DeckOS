import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'transport_policy.dart';

/// Each HTTP client owns immutable endpoint trust, including every WebSocket reconnect.
/// Verify the established socket even for CA-valid certificates. A badCertificateCallback
/// alone does NOT enforce pinning because it is skipped for publicly trusted certificates.
HttpClient secureHttpClient(
  TransportPolicy policy, {
  SecurityContext? context,
}) {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 4);
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    if (!policy.allows(uri) || proxyHost != null)
      throw const HandshakeException('Unexpected PC endpoint');
    final task = await Socket.startConnect(uri.host, uri.port);
    final future = () async {
      final raw = await task.socket;
      try {
        final socket = await SecureSocket.secure(
          raw,
          host: uri.host,
          context: context ?? SecurityContext.defaultContext,
          onBadCertificate: (cert) =>
              policy.pin != null &&
              sha256.convert(cert.der).toString() == policy.pin,
        );
        if (policy.pin != null &&
            (socket.peerCertificate == null ||
                sha256.convert(socket.peerCertificate!.der).toString() !=
                    policy.pin)) {
          socket.destroy();
          throw const HandshakeException(
            'PC certificate changed. Verify a new pairing code on your PC.',
          );
        }
        final cert = socket.peerCertificate;
        if (cert == null ||
            DateTime.now().isBefore(cert.startValidity) ||
            DateTime.now().isAfter(cert.endValidity)) {
          socket.destroy();
          throw const HandshakeException(
            'PC certificate expired. Update and re-pair with your PC.',
          );
        }
        // HTTP cannot write auth headers until this future returns the verified socket.
        return socket;
      } catch (_) {
        raw.destroy();
        rethrow;
      }
    }();
    return ConnectionTask.fromSocket(future, task.cancel);
  };
  return client;
}

void configureDio(Dio dio, TransportPolicy policy) {
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => secureHttpClient(policy),
  );
}
