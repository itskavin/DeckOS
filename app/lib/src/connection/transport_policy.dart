import 'package:dio/dio.dart';
import 'transport_platform_stub.dart'
    if (dart.library.io) 'transport_platform_io.dart'
    as platform;

/// Immutable trust for one selected PC. Discovery never constructs this policy.
class TransportPolicy {
  final Uri endpoint;
  final String? pin;
  final Uri? forwardedEndpoint;
  TransportPolicy(String url, {this.pin, String? forwardedUrl})
    : endpoint = parseEndpoint(url),
      forwardedEndpoint = forwardedUrl == null
          ? null
          : parseEndpoint(forwardedUrl) {
    if (pin != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(pin!)) {
      throw const FormatException('Invalid certificate fingerprint');
    }
  }

  static Uri parseEndpoint(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException(
        'Use the secure pairing code shown on your PC. HTTP is no longer supported.',
      );
    }
    return uri.replace(path: '');
  }

  bool allows(Uri uri) {
    final scheme = uri.scheme == 'wss' ? 'https' : uri.scheme;
    bool same(Uri expected) =>
        scheme == expected.scheme &&
        uri.host == expected.host &&
        uri.port == expected.port &&
        uri.userInfo.isEmpty;
    return same(endpoint) ||
        (pin != null && forwardedEndpoint != null && same(forwardedEndpoint!));
  }

  Dio dio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: endpoint.origin,
        followRedirects: false,
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    platform.configureDio(dio, this);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          if (!allows(o.uri)) {
            return h.reject(
              DioException(
                requestOptions: o,
                error: 'Connection belongs to another PC. Re-pair securely.',
              ),
            );
          }
          h.next(o);
        },
      ),
    );
    return dio;
  }
}
