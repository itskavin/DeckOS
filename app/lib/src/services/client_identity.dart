import 'package:deckos/core/web_mode.dart';
import 'package:deckos/src/connection/usb_route.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;

/// Metadados mínimos deste cliente enviados no handshake SignalR (`RegisterClient`) para
/// o configurador web mostrar qual aparelho está conectado, sem serial, IMEI, chave ou
/// dados pessoais, e sem travar o startup.
class ClientIdentity {
  ClientIdentity._();

  static const _channel = MethodChannel('deckos/device_info');
  static Future<({String? name, String? model})>? _deviceInfoFuture;

  /// Gancho para testes: substitui a leitura de nome/modelo do aparelho.
  @visibleForTesting
  static Future<({String? name, String? model})> Function()? deviceInfoOverride;

  /// Gancho para testes: sobrescreve role/platform/transport se necessário.
  @visibleForTesting
  static void resetForTest() {
    _deviceInfoFuture = null;
    deviceInfoOverride = null;
  }

  /// Papel deste cliente na sessão.
  static String get role {
    if (WebMode.configurator) return 'configurator';
    if (kIsWeb) return 'web_deck';
    return 'mobile';
  }

  /// Plataforma grossa deste cliente.
  static String get platform {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.windows => 'windows',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'linux',
    };
  }

  /// Transporte conhecido a partir da URL conectada.
  static String transportFor(String baseUrl) {
    if (kIsWeb) return WebMode.onPcLoopback ? 'local' : 'wifi';
    return UsbRoute.isUsb(baseUrl) ? 'usb' : 'wifi';
  }

  /// Monta um rótulo legível e mínimo a partir de fabricante + modelo (sem duplicar marca).
  static String? formatDisplayName(String? manufacturer, String? model) {
    final mfg = _sanitize(manufacturer);
    final mdl = _sanitize(model);
    if (mfg == null && mdl == null) return null;
    if (mfg == null) return mdl;
    if (mdl == null) return _capitalize(mfg);
    if (mdl.toLowerCase().startsWith(mfg.toLowerCase())) return mdl;
    return '${_capitalize(mfg)} $mdl';
  }

  static String? _sanitize(String? raw) {
    if (raw == null) return null;
    final clean = raw.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    if (clean.isEmpty || clean.toLowerCase() == 'unknown') return null;
    return clean.length > 64 ? clean.substring(0, 64).trim() : clean;
  }

  static String _capitalize(String s) {
    if (s.isEmpty) return s;
    final isAllLower = s == s.toLowerCase();
    return isAllLower ? s[0].toUpperCase() + s.substring(1) : s;
  }

  static Future<({String? name, String? model})> _resolveDeviceInfo() {
    final override = deviceInfoOverride;
    if (override != null) return override();
    return _deviceInfoFuture ??= _readPlatformDeviceInfo();
  }

  static Future<({String? name, String? model})> _readPlatformDeviceInfo() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return (name: null, model: null);
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('getDeviceInfo');
      if (raw == null) return (name: null, model: null);
      final manufacturer = raw['manufacturer'] as String?;
      final model = _sanitize(raw['model'] as String?);
      final name = formatDisplayName(manufacturer, model);
      return (name: name, model: model);
    } catch (_) {
      return (name: null, model: null);
    }
  }

  /// Payload do `RegisterClient` no contrato compartilhado com o servidor e a UI.
  static Future<Map<String, dynamic>> buildPayload(String baseUrl) async {
    final info = await _resolveDeviceInfo();
    return <String, dynamic>{
      'role': role,
      'name': info.name,
      'model': info.model,
      'platform': platform,
      'transport': transportFor(baseUrl),
    };
  }
}
