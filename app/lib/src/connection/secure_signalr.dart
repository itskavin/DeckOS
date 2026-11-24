import 'package:dio/dio.dart';
import 'package:signalr_netcore/signalr_client.dart';
import 'package:signalr_netcore/ihub_protocol.dart';
import 'package:signalr_netcore/signalr_http_client.dart';
import 'transport_policy.dart';
import 'secure_websocket_stub.dart'
    if (dart.library.io) 'secure_websocket_io.dart'
    as platform;

class SecureSignalRHttpClient extends SignalRHttpClient {
  final Dio _dio;
  SecureSignalRHttpClient(TransportPolicy policy) : _dio = policy.dio();
  @override
  Future<SignalRHttpResponse> send(SignalRHttpRequest request) async {
    final response = await _dio.request<String>(
      request.url!,
      data: request.content,
      options: Options(
        method: request.method,
        headers: request.headers?.asMap,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    );
    return SignalRHttpResponse(
      response.statusCode!,
      statusText: response.statusMessage,
      content: response.data,
    );
  }
}

HttpConnectionOptions secureSignalROptions(
  TransportPolicy policy,
  String? credential,
) => HttpConnectionOptions(
  httpClient: SecureSignalRHttpClient(policy),
  transport: platform.secureWebSocket(policy, credential),
  headers: credential == null
      ? MessageHeaders()
      : (MessageHeaders()..setHeaderValue('X-API-KEY', credential)),
  logMessageContent: false,
);
