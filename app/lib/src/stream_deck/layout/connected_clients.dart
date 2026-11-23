import 'package:deckos/core/core.dart';
import 'package:flutter/foundation.dart';

/// Um cliente conectado ao hub do DeckOS (celular, deck no navegador ou configurador).
/// Segue exatamente o contrato de `ReceiveConnectedClients` e `GET /api/system/clients`.
@immutable
class ConnectedDeckClient {
  final String id;
  final String role;
  final String? name;
  final String? model;
  final String platform;
  final String transport;
  final bool connected;
  final DateTime? connectedAt;

  const ConnectedDeckClient({
    required this.id,
    required this.role,
    this.name,
    this.model,
    required this.platform,
    required this.transport,
    this.connected = true,
    this.connectedAt,
  });

  bool get isMobile => role == 'mobile' && connected;
  bool get isWebDeck => role == 'web_deck' && connected;
  bool get isPhoneDeck => isMobile || isWebDeck;

  /// Nome exibível honesto: nunca inventa marca nem usa o nome do PC.
  String get displayName {
    final cleanName = name?.trim();
    if (cleanName != null && cleanName.isNotEmpty) return cleanName;
    final cleanModel = model?.trim();
    if (cleanModel != null && cleanModel.isNotEmpty) return cleanModel;
    return isWebDeck ? tr('Navegador conectado') : tr('Celular conectado');
  }

  /// Modelo complementar quando difere do nome amigável (ex.: "AIN065").
  String? get distinctModel {
    final cleanModel = model?.trim();
    if (cleanModel == null || cleanModel.isEmpty) return null;
    final cleanName = name?.trim();
    if (cleanName == null || cleanName.isEmpty) return null;
    if (cleanName.toLowerCase().contains(cleanModel.toLowerCase())) return null;
    return cleanModel;
  }

  String? get platformLabel => switch (platform.toLowerCase()) {
        'android' => 'Android',
        'ios' => 'iOS',
        'web' => 'Web',
        'windows' => 'Windows',
        'macos' => 'macOS',
        'linux' => 'Linux',
        _ => null,
      };

  String? get transportLabel => switch (transport.toLowerCase()) {
        'usb' => 'USB',
        'wifi' => 'Wi-Fi',
        'local' => tr('Local'),
        _ => null,
      };

  /// Resumo curto de plataforma e conexão (ex.: "Android · USB" ou "iOS · Wi-Fi").
  String get metaSummary {
    final parts = <String>[
      if (platformLabel != null) platformLabel!,
      if (transportLabel != null) transportLabel!,
    ];
    return parts.join(' · ');
  }

  static ConnectedDeckClient? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString().trim() ?? '';
    final role = raw['role']?.toString().trim().toLowerCase() ?? '';
    if (id.isEmpty || role.isEmpty) return null;
    final name = _cleanString(raw['name']);
    final model = _cleanString(raw['model']);
    final platform = raw['platform']?.toString().trim().toLowerCase() ?? 'unknown';
    final transport = raw['transport']?.toString().trim().toLowerCase() ?? '';
    final connected = raw['connected'] != false;
    final connectedAtRaw = raw['connectedAt']?.toString();
    final connectedAt = connectedAtRaw == null ? null : DateTime.tryParse(connectedAtRaw);
    return ConnectedDeckClient(
      id: id,
      role: role,
      name: name,
      model: model,
      platform: platform,
      transport: transport,
      connected: connected,
      connectedAt: connectedAt,
    );
  }

  static String? _cleanString(dynamic v) {
    if (v is! String) return null;
    final trimmed = v.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Estado dos clientes conectados reportados pelo servidor do DeckOS.
@immutable
class ConnectedClientsState {
  /// True quando o servidor respondeu com a lista (mesmo vazia). False quando o
  /// servidor está offline ou é mais antigo e não expõe `/api/system/clients`.
  final bool known;
  final List<ConnectedDeckClient> clients;

  const ConnectedClientsState({
    required this.known,
    this.clients = const [],
  });

  const ConnectedClientsState.unknown()
      : known = false,
        clients = const [];

  /// Dispositivos que operam como deck (celular nativo primeiro, depois deck no navegador).
  List<ConnectedDeckClient> get phones {
    final mobile = <ConnectedDeckClient>[];
    final webDeck = <ConnectedDeckClient>[];
    for (final c in clients) {
      if (c.isMobile) {
        mobile.add(c);
      } else if (c.isWebDeck) {
        webDeck.add(c);
      }
    }
    return [...mobile, ...webDeck];
  }

  ConnectedDeckClient? get primaryPhone => phones.isEmpty ? null : phones.first;
  int get phoneCount => phones.length;

  /// Interpreta o payload `{ "clients": [...] }` vindo do SignalR ou REST.
  static ConnectedClientsState fromPayload(dynamic raw) {
    if (raw is! Map || raw['clients'] is! List) {
      return const ConnectedClientsState.unknown();
    }
    final list = <ConnectedDeckClient>[];
    for (final item in raw['clients'] as List) {
      final parsed = ConnectedDeckClient.tryParse(item);
      if (parsed != null) list.add(parsed);
    }
    return ConnectedClientsState(known: true, clients: list);
  }
}
