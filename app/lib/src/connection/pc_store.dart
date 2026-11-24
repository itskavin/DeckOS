import 'dart:convert';
import 'credential_store.dart';
import 'transport_policy.dart';

import 'package:deckos/src/connection/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Um PC pareado com este celular.
class SavedPc {
  final String id;
  final String name;
  final String ip;
  final String port;
  final String? apiKey;
  final String protocol;
  final String? trustedPin;

  const SavedPc({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    this.apiKey,
    this.protocol = 'http',
    this.trustedPin,
  });

  String get baseUrl =>
      Uri(scheme: protocol, host: ip, port: int.parse(port)).origin;
  bool get needsRepair => protocol != 'https' || apiKey == null;
  TransportPolicy get policy => TransportPolicy(
    baseUrl,
    pin: trustedPin,
    forwardedUrl: trustedPin == null ? null : 'https://127.0.0.1:4788',
  );

  SavedPc copyWith({String? name, String? apiKey}) => SavedPc(
    id: id,
    name: name ?? this.name,
    ip: ip,
    port: port,
    apiKey: apiKey ?? this.apiKey,
    protocol: protocol,
    trustedPin: trustedPin,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ip': ip,
    'port': port,
    'protocol': protocol,
    'trustedPin': trustedPin,
  };

  factory SavedPc.fromJson(Map<String, dynamic> j) => SavedPc(
    id: '${j['id']}',
    name: '${j['name'] ?? 'PC'}',
    ip: '${j['ip']}',
    port: '${j['port'] ?? Constants.defaultPort}',
    apiKey: j['apiKey'] as String?,
    protocol: j['protocol'] as String? ?? 'http',
    trustedPin: j['trustedPin'] as String?,
  );
}

/// PCs pareados e qual está em uso. O PC atual também fica nas chaves antigas
/// (IP, porta, chave), que o resto do app lê; o cache do deck é separado por PC.
class PcStore {
  static const _listKey = 'pcs';
  static const _currentKey = 'pc_current';

  /// Id do PC em uso, carregado na abertura do app ([load]).
  static String? currentId;

  static Future<void> _queue = Future.value();
  static Future<T> _locked<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static Future<List<SavedPc>> load() => _locked(_load);
  static Future<List<SavedPc>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    var list = _decode(prefs.getString(_listKey));
    if (list.isEmpty) {
      // Versões antigas guardavam um PC só, direto nas chaves de conexão.
      final ip = prefs.getString(Constants.ipAddrKey);
      if (ip != null && ip.isNotEmpty) {
        final pc = SavedPc(
          id: prefs.getString(_currentKey) ?? _newId(),
          name: 'PC',
          ip: ip.contains(':') ? ip.substring(0, ip.indexOf(':')) : ip,
          port: prefs.getString(Constants.portKey) ?? Constants.defaultPort,
          apiKey: prefs.getString(Constants.apiKeyKey),
        );
        list = [pc];
        await prefs.setString(_currentKey, pc.id);
        // O deck guardado passa a ser o deste PC.
        for (final key in ['deck_cache', 'deck_last_profile']) {
          final v = prefs.getString(key);
          if (v != null) await prefs.setString(scoped(key, pc.id), v);
        }
      }
    }
    // Finish every vault write before removing any plaintext connection credentials.
    final secured = <SavedPc>[];
    for (final pc in list) {
      if (pc.apiKey != null)
        await CredentialStore.write(
          pc.id,
          jsonEncode({
            'credential': pc.apiKey,
            'endpoint': pc.baseUrl,
            'pin': pc.trustedPin,
          }),
        );
      final stored = await CredentialStore.read(pc.id);
      String? credential;
      if (stored != null) {
        final secret = jsonDecode(stored) as Map;
        if (secret['endpoint'] != pc.baseUrl ||
            secret['pin'] != pc.trustedPin) {
          secured.add(
            SavedPc(
              id: pc.id,
              name: pc.name,
              ip: pc.ip,
              port: pc.port,
              protocol: pc.protocol,
              trustedPin: pc.trustedPin,
            ),
          );
          continue;
        }
        credential = secret['credential'] as String?;
      }
      secured.add(pc.copyWith(apiKey: credential));
    }
    await _save(secured);
    await prefs.remove(Constants.apiKeyKey);
    list = secured;
    currentId =
        prefs.getString(_currentKey) ??
        (list.isNotEmpty ? list.first.id : null);
    return list;
  }

  static Future<SavedPc?> current() async {
    final list = await load();
    for (final pc in list) {
      if (pc.id == currentId) return pc;
    }
    return list.isEmpty ? null : list.first;
  }

  /// Guarda um PC (o mesmo IP e porta atualiza o existente) e o deixa em uso.
  static Future<SavedPc> upsert({
    required String ip,
    required String port,
    String? apiKey,
    String? name,
    String protocol = 'https',
    String? trustedPin,
  }) => _locked(() async {
    final list = await _load();
    final index = list.indexWhere(
      (p) => p.ip == ip && (p.port == port || p.needsRepair),
    );
    final SavedPc pc;
    if (index >= 0) {
      pc = SavedPc(
        id: list[index].id,
        name: name ?? list[index].name,
        ip: ip,
        port: port,
        apiKey: apiKey ?? list[index].apiKey,
        protocol: protocol,
        trustedPin: trustedPin,
      );
      list[index] = pc;
    } else {
      pc = SavedPc(
        id: _newId(),
        name: name ?? ip,
        ip: ip,
        port: port,
        apiKey: apiKey,
        protocol: protocol,
        trustedPin: trustedPin,
      );
      list.add(pc);
    }
    if (pc.apiKey != null)
      await CredentialStore.write(
        pc.id,
        jsonEncode({
          'credential': pc.apiKey,
          'endpoint': pc.baseUrl,
          'pin': pc.trustedPin,
        }),
      );
    await _save(list);
    await _select(pc);
    return pc;
  });

  static Future<void> rename(String id, String name) => _locked(() async {
    final list = await _load();
    await _save([
      for (final p in list) p.id == id ? p.copyWith(name: name) : p,
    ]);
  });

  static Future<void> remove(String id) => _locked(() async {
    final prefs = await SharedPreferences.getInstance();
    final list = (await _load()).where((p) => p.id != id).toList();
    await _save(list);
    await CredentialStore.delete(id);
    await prefs.remove(scoped('deck_cache', id));
    await prefs.remove(scoped('deck_last_profile', id));
    if (currentId == id) {
      if (list.isNotEmpty) {
        await _select(list.first);
      } else {
        currentId = null;
        await prefs.remove(_currentKey);
        await prefs.remove(Constants.ipAddrKey);
        await prefs.remove(Constants.apiKeyKey);
      }
    }
  });

  /// Passa a usar este PC: grava nas chaves de conexão que o app lê ao abrir.
  static Future<void> select(SavedPc pc) => _locked(() => _select(pc));
  static Future<void> _select(SavedPc pc) async {
    final prefs = await SharedPreferences.getInstance();
    currentId = pc.id;
    await prefs.setString(_currentKey, pc.id);
    await prefs.setString(Constants.ipAddrKey, pc.ip);
    await prefs.setString(Constants.portKey, pc.port);
    await prefs.remove(Constants.apiKeyKey);
  }

  /// Chave de preferência separada por PC (cache do deck, último perfil).
  static String scoped(String key, [String? pcId]) {
    final id = pcId ?? currentId;
    return id == null ? key : '${key}_$id';
  }

  static Future<void> _save(List<SavedPc> list) async =>
      (await SharedPreferences.getInstance()).setString(
        _listKey,
        _encode(list),
      );

  static String _encode(List<SavedPc> list) =>
      jsonEncode(list.map((p) => p.toJson()).toList());

  static List<SavedPc> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => SavedPc.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static int _seq = 0;

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';
}
