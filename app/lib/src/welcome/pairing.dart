import 'package:deckos/core/core.dart';
import 'package:deckos/src/config/pc_switcher.dart';
import 'package:deckos/src/connection/constants.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pareamento a partir da tela de boas-vindas: o mesmo que a configuração faz (salva o
/// PC na lista, liga o cliente e o SignalR), sem passar por ela.

/// Dados de um QR "deckos://pair?ip=…&port=…&key=…". Null se o QR não for de
/// pareamento do DeckOS.
({String ip, String port, String key})? parsePairingQr(String raw) {
  final uri = Uri.tryParse(raw.trim());
  final ip = uri?.queryParameters['ip'];
  final key = uri?.queryParameters['key'];
  if (uri == null || uri.scheme != 'deckos' || ip == null || ip.isEmpty || key == null || key.isEmpty) {
    return null;
  }
  return (ip: ip, port: uri.queryParameters['port'] ?? Constants.defaultPort, key: key);
}

/// Pareia com o QR lido. False se o QR não é de pareamento.
Future<bool> pairWithQr(String raw) async {
  final data = parsePairingQr(raw);
  if (data == null) return false;
  await _connect(data.ip, data.port, data.key);
  return true;
}

/// Liga ao PC digitado ou achado na rede ("ip" ou "ip:porta"), com a chave que o
/// aparelho já tiver (pareamento anterior). False se o endereço está vazio.
Future<bool> connectToAddress(String address) async {
  var ip = address.trim().replaceAll('http://', '').replaceAll('https://', '');
  if (ip.endsWith('/')) ip = ip.substring(0, ip.length - 1);
  if (ip.isEmpty) return false;
  final colon = ip.indexOf(':');
  final host = colon < 0 ? ip : ip.substring(0, colon);
  final port = colon < 0 ? Constants.defaultPort : ip.substring(colon + 1);
  final prefs = await SharedPreferences.getInstance();
  await _connect(host, port, prefs.getString(Constants.apiKeyKey));
  return true;
}

Future<void> _connect(String ip, String port, String? key) async {
  final baseUrl = 'http://$ip:$port';
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(Constants.ipAddrKey, ip);
  await prefs.setString(Constants.portKey, port); // persiste a porta p/ o splash
  if (key != null) await prefs.setString(Constants.apiKeyKey, key);
  // Parear com outro PC acrescenta à lista; o mesmo IP atualiza a chave.
  final pc = await PcStore.upsert(ip: ip, port: port, apiKey: key);
  await fetchPcName(pc);

  final client = Injector.get<DeckOSClient>();
  client.setBaseUrl(baseUrl);
  client.setApiKey(key);
  await Injector.get<SignalRService>().updateUrl(baseUrl, apiKey: key);
}
