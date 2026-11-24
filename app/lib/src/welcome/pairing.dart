import 'package:deckos/core/core.dart';
import 'package:deckos/src/config/pc_switcher.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/connection/transport_policy.dart';
import 'package:deckos/src/connection/usb_route.dart';
import 'package:deckos/src/services/signalr_service.dart';

class SecurePairingCode {
  final TransportPolicy policy;
  final String token;
  SecurePairingCode(this.policy, this.token);
}

SecurePairingCode? parsePairingQr(String raw) {
  try {
    final uri = Uri.parse(raw.trim());
    if (uri.scheme != 'deckos' ||
        uri.host != 'pair' || uri.path.isNotEmpty || uri.hasFragment ||
        uri.queryParameters['v'] != '2')
      return null;
    if (uri.queryParametersAll.values.any((v) => v.length != 1)) return null;
    final token = uri.queryParameters['token'] ?? '';
    final pin = uri.queryParameters['pin'];
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(token) || pin == null) return null;
    return SecurePairingCode(
      TransportPolicy(uri.queryParameters['endpoint'] ?? '', pin: pin),
      token,
    );
  } catch (_) {
    return null;
  }
}

String pairingFailure = '';
String pairingError(Object error) {
  if (error is DioException && error.response?.statusCode == 410) {
    return tr(
      'This pairing code expired or was already used. Open a new code on your PC.',
    );
  }
  return tr(
    'Cannot verify this PC. Update the PC companion, open a fresh pairing code on that PC, and try again. A changed certificate requires a new scan.',
  );
}

Future<bool> pairWithQr(String raw) async {
  final data = parsePairingQr(raw);
  if (data == null) {
    pairingFailure = tr(
      'Update the PC companion and use its secure pairing code (version 2). Existing profiles are kept.',
    );
    return false;
  }
  return _exchange(data);
}

/// Manual entry accepts the entire code copied from the physical PC. An HTTPS
/// endpoint with a #token= fragment may use normal system CA/hostname validation.
/// An address from discovery alone is never enough to establish trust.
Future<bool> connectToAddress(String address) async {
  final code = parsePairingQr(address);
  if (code != null) return _exchange(code);
  try {
    final uri = Uri.parse(address.trim());
    final token = Uri.splitQueryString(uri.fragment)['token'] ?? '';
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(token))
      throw const FormatException();
    final policy = TransportPolicy(uri.removeFragment().toString());
    return await _exchange(SecurePairingCode(policy, token));
  } catch (_) {
    pairingFailure = tr(
      'On your PC, open Pair device and scan or copy the complete secure pairing code. Finding an address does not verify its identity. Old PCs need the updated companion.',
    );
    return false;
  }
}

Future<bool> _exchange(SecurePairingCode code) async {
  final dio = code.policy.dio();
  try {
    final r = await dio.post(
      '/api/pairing/exchange',
      data: {'token': code.token, 'name': 'DeckOS app'},
    );
    final credential = (r.data as Map)['credential'] as String;
    final uri = code.policy.endpoint;
    final pc = await PcStore.upsert(
      ip: uri.host,
      port: uri.port.toString(),
      apiKey: credential,
      protocol: 'https',
      trustedPin: code.policy.pin,
    );
    await activatePc(pc);
    await fetchPcName(pc);
    pairingFailure = '';
    return true;
  } catch (error) {
    pairingFailure = pairingError(error);
    return false;
  } finally {
    dio.close(force: true);
  }
}

int _activationGeneration = 0;
Future<void> activatePc(SavedPc pc) async {
  final generation = ++_activationGeneration;
  final signalR = Injector.get<SignalRService>();
  await signalR.dispose();
  if (generation != _activationGeneration) return;
  final client = Injector.get<DeckOSClient>();
  client.setApiKey(null);
  if (pc.needsRepair) throw StateError(tr('Re-pair securely'));
  final policy = pc.policy;
  final route = await UsbRoute.pick(
    pc.baseUrl,
    apiKey: pc.apiKey,
    policy: policy,
  );
  if (generation != _activationGeneration || PcStore.currentId != pc.id) return;
  client.configureSecure(policy, pc.apiKey, route: route);
  await signalR.updateUrl(route, apiKey: pc.apiKey, policy: policy);
}
