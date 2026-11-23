import 'package:deckos/core/core.dart';

/// Tira acento e caixa: "Música" acha "musica".
String foldText(String s) {
  const from = 'áàâãäåçéèêëíìîïñóòôõöúùûüýÿ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyy';
  final lower = s.toLowerCase();
  final out = StringBuffer();
  for (final ch in lower.split('')) {
    final i = from.indexOf(ch);
    out.write(i == -1 ? ch : to[i]);
  }
  return out.toString();
}

/// Nota de [query] em [text] (maior = melhor), ou null se não bate. Começo do texto vale
/// mais, depois começo de palavra, depois trecho no meio, e por fim as letras em ordem
/// ("vsc" acha "Visual Studio Code").
int? fuzzyScore(String query, String text) {
  final q = foldText(query.trim());
  if (q.isEmpty) return 0;
  final t = foldText(text);
  if (t.startsWith(q)) return 1000 - t.length;
  final words = t.split(RegExp(r'[\s\-_.·/]+'));
  if (words.any((w) => w.startsWith(q))) return 800 - t.length;
  final i = t.indexOf(q);
  if (i != -1) return 600 - i;
  // Iniciais das palavras: "vsc" → Visual Studio Code.
  final initials = words.where((w) => w.isNotEmpty).map((w) => w[0]).join();
  if (initials.startsWith(q)) return 500 - t.length;
  // Letras em ordem, com pena pelos buracos.
  var pos = 0, gaps = 0;
  for (final ch in q.split('')) {
    if (ch == ' ') continue;
    final at = t.indexOf(ch, pos);
    if (at == -1) return null;
    gaps += at - pos;
    pos = at + 1;
  }
  return 300 - gaps;
}

/// Filtra e ordena pela nota de [fuzzyScore]; consulta vazia devolve a lista como está.
List<T> fuzzyFilter<T>(Iterable<T> items, String query, String Function(T) text) {
  if (query.trim().isEmpty) return items.toList();
  final scored = <(T, int)>[];
  for (final item in items) {
    final s = fuzzyScore(query, text(item));
    if (s != null) scored.add((item, s));
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (item, _) in scored) item];
}

/// Apps da biblioteca que batem com a busca, os melhores primeiro.
List<InstalledApp> filterApps(List<InstalledApp> apps, String query) =>
    fuzzyFilter(apps, query, (a) => a.name);
