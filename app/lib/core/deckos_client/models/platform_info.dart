/// O que o PC é e sabe fazer (GET /api/platform). A interface esconde o que não está em
/// [capabilities] em vez de deixar o botão falhar no toque.
class PlatformInfo {
  /// "windows", "macos", "linux" ou "other".
  final String os;
  final String? osVersion;
  final String? machineName;
  final String? version;
  final Set<String> capabilities;

  /// Recursos que faltam por causa de uma ferramenta: capacidade → o que instalar.
  final Map<String, String> missing;

  const PlatformInfo({
    required this.os,
    this.osVersion,
    this.machineName,
    this.version,
    this.capabilities = const {},
    this.missing = const {},
  });

  bool get isMac => os == 'macos';
  bool get isWindows => os == 'windows';
  bool get isLinux => os == 'linux';

  bool has(String capability) => capabilities.contains(capability);

  factory PlatformInfo.fromJson(Map<String, dynamic> j) => PlatformInfo(
        os: '${j['os'] ?? 'other'}'.toLowerCase(),
        osVersion: j['osVersion'] as String?,
        machineName: j['machineName'] as String?,
        version: j['version'] as String?,
        capabilities: {
          for (final c in (j['capabilities'] as List? ?? const [])) '$c',
        },
        missing: {
          for (final m in (j['missing'] as List? ?? const []))
            if (m is Map && m['capability'] != null)
              '${m['capability']}': '${m['package'] ?? m['tool'] ?? ''}',
        },
      );
}
