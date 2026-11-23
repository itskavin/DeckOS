import 'package:deckos/core/core.dart';

/// O que o PC conectado contou de si: nome, sistema, versão do DeckOS e o que ele sabe
/// fazer (GET /api/platform). PC antigo só tem /api/system/info: aí [capabilities] fica
/// nulo e tudo aparece, como antes.
class PcInfo {
  final String? name;

  /// 'windows', 'macos', 'linux' ou nulo (PC antigo, que só roda no Windows).
  final String? os;
  final String? osVersion;
  final String? version;
  final Set<String>? capabilities;

  const PcInfo({
    this.name,
    this.os,
    this.osVersion,
    this.version,
    this.capabilities,
  });

  /// Último lido, para as telas não piscarem ao abrir de novo.
  static final current = signal<PcInfo?>(null);

  /// Sem a lista (PC antigo), assume que tem: era tudo Windows.
  bool has(String capability) => capabilities?.contains(capability) ?? true;

  bool get isWindows => os == null || os == 'windows';

  /// Nome do sistema para mostrar ("Windows", "macOS", "Linux").
  String? get osLabel => switch (os) {
    'windows' => 'Windows',
    'macos' => 'macOS',
    'linux' => 'Linux',
    null => null,
    final other => other,
  };

  factory PcInfo.fromJson(Map j) => PcInfo(
    name: (j['machineName'] ?? j['name']) as String?,
    os: j['os'] as String?,
    osVersion: j['osVersion'] as String?,
    version: j['version'] as String?,
    capabilities: j['capabilities'] is List
        ? {for (final c in j['capabilities'] as List) '$c'}
        : null,
  );

  static Future<PcInfo?> load() async {
    final client = Injector.get<DeckOSClient>();
    PcInfo? info;
    final PlatformInfo? p = await client.getPlatform();
    if (p != null) {
      info = PcInfo(
        name: p.machineName,
        os: p.os,
        osVersion: p.osVersion,
        version: p.version,
        capabilities: p.capabilities,
      );
    } else {
      try {
        info = PcInfo.fromJson(await client.getJson('/api/system/info') as Map);
      } catch (_) {}
    }
    if (info != null) current.value = info;
    return info;
  }
}
