/// Um app instalado no PC (GET /api/apps): a biblioteca do configurador. Abrir usa a
/// ação "launch_app" com [path] (e [arguments], para apps da Store e .desktop).
class InstalledApp {
  final String id;
  final String name;
  final String path;
  final String? arguments;

  /// Caminho do ícone no PC (/api/apps/{id}/icon). Null = sem ícone.
  final String? iconUrl;

  const InstalledApp({
    required this.id,
    required this.name,
    required this.path,
    this.arguments,
    this.iconUrl,
  });

  factory InstalledApp.fromJson(Map<String, dynamic> j) {
    final id = '${j['id'] ?? ''}';
    return InstalledApp(
      id: id,
      name: '${j['name'] ?? ''}'.trim(),
      path: '${j['path'] ?? ''}',
      arguments: (j['arguments'] as String?)?.trim().isEmpty ?? true ? null : j['arguments'] as String,
      // Sem iconUrl (servidor que não manda o campo): o endereço padrão do ícone.
      iconUrl: j.containsKey('iconUrl')
          ? j['iconUrl'] as String?
          : (id.isEmpty ? null : '/api/apps/$id/icon'),
    );
  }
}
