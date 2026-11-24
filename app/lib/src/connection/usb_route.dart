import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'transport_policy.dart';

/// USB carries exactly the same certificate identity as the saved LAN endpoint.
class UsbRoute {
  UsbRoute._();
  static const usbBaseUrl = 'https://127.0.0.1:4788';
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool isUsb(String baseUrl) => baseUrl == usbBaseUrl;
  static Future<String> pick(
    String baseUrl, {
    String? apiKey,
    TransportPolicy? policy,
  }) async {
    if (!kIsWeb) TransportPolicy.parseEndpoint(baseUrl);
    if (!isSupported || policy == null || policy.pin == null || apiKey == null)
      return baseUrl;
    final probe = policy.dio();
    try {
      await probe.get(
        '$usbBaseUrl/api/StreamDeck/layout',
        options: Options(
          headers: {'X-API-KEY': apiKey},
          receiveTimeout: const Duration(seconds: 1),
        ),
      );
      return usbBaseUrl;
    } catch (_) {
      // The fallback is the SAME verified PC over TLS, never a discovered host or HTTP.
      return policy.endpoint.origin;
    } finally {
      probe.close(force: true);
    }
  }
}
