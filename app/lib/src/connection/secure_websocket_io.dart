import 'dart:async';
import 'dart:io';
import 'package:signalr_netcore/itransport.dart';
import 'transport_platform_io.dart';
import 'transport_policy.dart';

ITransport secureWebSocket(
  TransportPolicy policy,
  String? credential, {
  SecurityContext? context,
}) => _PinnedWebSocket(policy, credential, context);

class _PinnedWebSocket implements ITransport {
  final TransportPolicy policy;
  final String? credential;
  final SecurityContext? context;
  WebSocket? _socket;
  HttpClient? _client;
  StreamSubscription<dynamic>? _subscription;
  _PinnedWebSocket(this.policy, this.credential, this.context);
  @override
  OnReceive? onReceive;
  @override
  OnClose? onClose;
  @override
  Future<void> connect(String? url, TransferFormat transferFormat) async {
    final uri = Uri.parse(url!);
    if (!policy.allows(uri))
      throw const HandshakeException('Unexpected PC endpoint');
    _client = secureHttpClient(policy, context: context);
    try {
      final socket = await WebSocket.connect(
        uri.replace(scheme: 'wss').toString(),
        headers: {if (credential != null) 'X-API-KEY': credential},
        customClient: _client,
      );
      _socket = socket;
      _subscription = socket.listen(
        (data) => onReceive?.call(data),
        onError: (_) {},
        onDone: () {
          _client?.close(force: true);
          onClose?.call();
        },
      );
    } catch (_) {
      _client?.close(force: true);
      rethrow;
    }
  }

  @override
  Future<void> send(Object data) async {
    final socket = _socket;
    if (socket == null) throw StateError('WebSocket disconnected');
    socket.add(data);
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
    _client?.close(force: true);
    _client = null;
    onClose?.call();
  }
}
