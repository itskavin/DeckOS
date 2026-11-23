import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Conexão pelo cabo USB. Com a "Conexão USB" ligada no PC e a depuração USB no celular,
/// o PC faz o 127.0.0.1:4787 do celular cair nele (adb reverse). O app prefere esse
/// caminho quando ele existe: funciona sem Wi-Fi e tem menos atraso.
class UsbRoute {
  UsbRoute._();

  static const usbBaseUrl = 'http://127.0.0.1:4787';

  /// Último endereço de rede do PC, para voltar a ele quando o cabo sai.
  static String? _lanBaseUrl;

  /// Cliente leve reutilizado nos probes do cabo (evita recriar pool/socket a cada chamada).
  /// Loopback responde em poucos ms quando vivo e recusa imediatamente quando ausente;
  /// timeouts curtos evitam travar o startup quando um encaminhamento antigo pendurou.
  static final Dio _probeDio = Dio(BaseOptions(
    connectTimeout: const Duration(milliseconds: 350),
    receiveTimeout: const Duration(milliseconds: 1000),
  ));

  /// O adb reverse só existe no Android. No iPhone, no navegador e no desktop o
  /// 127.0.0.1:4787 não é o PC pelo cabo: lá vale sempre o endereço da rede.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// A conexão atual é pelo cabo?
  static bool isUsb(String baseUrl) => baseUrl == usbBaseUrl;

  /// Endereço a usar: o do cabo, se o PC do outro lado aceita esta chave (assim um cabo
  /// ligado em outro PC não troca o PC pareado); senão o da rede.
  static Future<String> pick(String baseUrl, {String? apiKey}) async {
    if (!isSupported) return baseUrl;
    final lan = isUsb(baseUrl) ? (_lanBaseUrl ?? baseUrl) : baseUrl;
    if (!isUsb(lan)) _lanBaseUrl = lan;
    if (apiKey == null || apiKey.isEmpty) return lan;
    try {
      await _probeDio.get(
        '$usbBaseUrl/api/StreamDeck/layout',
        options: Options(headers: {'X-API-Key': apiKey}),
      );
      return usbBaseUrl;
    } catch (_) {
      return lan;
    }
  }
}
