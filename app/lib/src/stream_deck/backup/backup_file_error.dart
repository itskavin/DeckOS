/// Erro ao ler o arquivo selecionado no seletor do navegador (ex.: sem permissão ou ilegível).
class BackupFileReadException implements Exception {
  final Object? cause;

  const BackupFileReadException([this.cause]);

  @override
  String toString() => 'BackupFileReadException($cause)';
}
