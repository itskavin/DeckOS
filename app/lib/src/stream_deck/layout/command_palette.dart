import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../actions/action_schema.dart';
import 'app_icon.dart';
import 'fuzzy.dart';
import 'library_items.dart';

/// Uma linha da paleta: ir para uma página ou pôr um item no deck.
class PaletteEntry {
  final String title;
  final String kind;
  final Widget icon;
  final DeckProfile? page;
  final LibraryItem? item;

  const PaletteEntry({required this.title, required this.kind, required this.icon, this.page, this.item});
}

/// Monta as linhas da paleta: páginas, apps do PC e ações que o PC executa.
List<PaletteEntry> paletteEntries({
  required List<DeckProfile> pages,
  required List<InstalledApp> apps,
  required List<ActionSchema> actions,
  required PlatformInfo? platform,
  required AppleColors colors,
}) {
  Widget glyph(IconData icon, Color color) => Container(
        width: 26,
        height: 26,
        decoration: ShapeDecoration(color: color, shape: AppleShapes.squircle(AppleRadii.xs)),
        child: Icon(icon, size: 15, color: AppleColors.onColor(color)),
      );
  return [
    for (final p in pages)
      PaletteEntry(
        title: p.name,
        kind: tr('Página'),
        icon: glyph(Icons.grid_view_rounded, colors.gray),
        page: p,
      ),
    for (final a in apps)
      PaletteEntry(
        title: a.name,
        kind: tr('App'),
        icon: AppIconView(app: a, size: 26),
        item: LibraryItem.fromApp(a),
      ),
    for (final s in actions)
      if (actionSupported(s.type, platform))
        PaletteEntry(
          title: s.title,
          kind: s.category,
          icon: glyph(actionGlyph(s), systemColor(colors, categoryStyle(s.category).$2)),
          item: LibraryItem.fromAction(s),
        ),
  ];
}

/// Abre a paleta (Ctrl/Cmd+K). Devolve a linha escolhida, ou null.
Future<PaletteEntry?> showCommandPalette(BuildContext context, List<PaletteEntry> entries) {
  return showGeneralDialog<PaletteEntry>(
    context: context,
    barrierDismissible: true,
    barrierLabel: tr('Fechar'),
    barrierColor: Colors.black.withValues(alpha: 0.25),
    transitionDuration: AppleMotion.of(context, AppleMotion.fast),
    pageBuilder: (context, _, _) => _CommandPalette(entries: entries),
    transitionBuilder: (context, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(
        scale: Tween(begin: 0.97, end: 1.0).animate(CurvedAnimation(parent: anim, curve: AppleMotion.smooth)),
        child: child,
      ),
    ),
  );
}

class _CommandPalette extends StatefulWidget {
  final List<PaletteEntry> entries;
  const _CommandPalette({required this.entries});

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  String _query = '';
  int _index = 0;
  final _scroll = ScrollController();

  List<PaletteEntry> get _results {
    if (_query.trim().isEmpty) {
      // Sem busca: as páginas primeiro, depois um pouco de tudo.
      return widget.entries.take(40).toList();
    }
    return fuzzyFilter(widget.entries, _query, (e) => e.title).take(40).toList();
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _index = (_index + delta) % count);
    const rowH = 44.0;
    final target = _index * rowH;
    if (_scroll.hasClients) {
      final pos = _scroll.position;
      if (target < pos.pixels) _scroll.jumpTo(target);
      if (target + rowH > pos.pixels + pos.viewportDimension) {
        _scroll.jumpTo(target + rowH - pos.viewportDimension);
      }
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final results = _results;
    if (_index >= results.length) _index = 0;
    return Align(
      alignment: const Alignment(0, -0.55),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 460),
        child: Padding(
          padding: const EdgeInsets.all(AppleSpacing.md),
          child: Material(
            type: MaterialType.transparency,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: AppleShapes.squircle(AppleRadii.xl),
                shadows: AppleShadows.floating(Theme.of(context).brightness),
              ),
              child: GlassPanel(
                radius: AppleRadii.lg,
                color: c.secondaryGroupedBackground.withValues(alpha: 0.96),
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1, results.length),
                    const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1, results.length),
                    const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(AppleSpacing.md, AppleSpacing.sm, AppleSpacing.md, AppleSpacing.xs),
                        child: TextField(
                          autofocus: true,
                          style: type.title3.copyWith(color: c.label, fontWeight: FontWeight.w400),
                          cursorColor: c.accent,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            hintText: tr('Buscar apps, ações e páginas'),
                            hintStyle: type.title3.copyWith(color: c.tertiaryLabel, fontWeight: FontWeight.w400),
                            prefixIcon: Icon(Icons.search_rounded, color: c.secondaryLabel),
                          ),
                          onChanged: (v) => setState(() {
                            _query = v;
                            _index = 0;
                          }),
                          onSubmitted: (_) {
                            if (results.isNotEmpty) Navigator.pop(context, results[_index]);
                          },
                        ),
                      ),
                      Container(height: 1, color: c.separator),
                      Flexible(
                        child: results.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(AppleSpacing.xl),
                                child: Text(tr('Nada com "{q}"', {'q': _query.trim()}),
                                    style: type.subheadline.copyWith(color: c.secondaryLabel)),
                              )
                            : ListView.builder(
                                controller: _scroll,
                                shrinkWrap: true,
                                padding: const EdgeInsets.all(AppleSpacing.xs),
                                itemExtent: 44,
                                itemCount: results.length,
                                itemBuilder: (context, i) {
                                  final e = results[i];
                                  final on = i == _index;
                                  return MouseRegion(
                                    onEnter: (_) => setState(() => _index = i),
                                    child: GestureDetector(
                                      onTap: () => Navigator.pop(context, e),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.sm),
                                        decoration: BoxDecoration(
                                          color: on ? c.accent : Colors.transparent,
                                          borderRadius: BorderRadius.circular(AppleRadii.sm),
                                        ),
                                        child: Row(
                                          children: [
                                            e.icon,
                                            const SizedBox(width: AppleSpacing.sm),
                                            Expanded(
                                              child: Text(e.title,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: type.body.copyWith(color: on ? c.onAccent : c.label)),
                                            ),
                                            Text(e.kind,
                                                style: type.footnote.copyWith(
                                                    color: on ? c.onAccent.withValues(alpha: 0.8) : c.secondaryLabel)),
                                            if (on) ...[
                                              const SizedBox(width: AppleSpacing.xs),
                                              Icon(Icons.keyboard_return_rounded, size: 15, color: c.onAccent),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
