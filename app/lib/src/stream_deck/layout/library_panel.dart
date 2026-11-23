import 'package:deckos/core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../actions/action_catalog.dart';
import '../actions/action_schema.dart';
import 'app_icon.dart';
import 'fuzzy.dart';
import 'key_combo.dart';
import 'library_items.dart';

enum LibraryTab { apps, actions, shortcuts }

/// "Apps neste Mac" e o resto da biblioteca: apps do PC, o catálogo de ações e atalhos de
/// teclado. Cada item se arrasta para uma casa do espelho; clique duplo põe na primeira
/// casa livre.
class LibraryPanel extends StatefulWidget {
  final PlatformInfo? platform;

  /// Apps do PC; null = o PC não tem a lista (a aba some).
  final List<InstalledApp>? apps;
  final bool appsLoading;
  final ValueChanged<LibraryItem> onAdd;

  const LibraryPanel({
    super.key,
    required this.platform,
    required this.apps,
    required this.appsLoading,
    required this.onAdd,
  });

  /// Título da aba de apps conforme o sistema do PC.
  static String appsTitle(PlatformInfo? p) => switch (p?.os) {
        'macos' => tr('Apps neste Mac'),
        'windows' => tr('Apps neste PC'),
        _ => tr('Apps neste computador'),
      };

  @override
  State<LibraryPanel> createState() => _LibraryPanelState();
}

class _LibraryPanelState extends State<LibraryPanel> {
  LibraryTab? _tab;
  final _search = TextEditingController();
  String _query = '';

  bool get _hasApps => widget.apps != null || widget.appsLoading;

  LibraryTab get _current {
    final t = _tab ?? (_hasApps ? LibraryTab.apps : LibraryTab.actions);
    return t == LibraryTab.apps && !_hasApps ? LibraryTab.actions : t;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _mac => widget.platform?.isMac ?? (defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Watch((context) {
      final schemas = ActionCatalog.instance.schemas.value;
      final tab = _current;
      final (title, count, body) = switch (tab) {
        LibraryTab.apps => _apps(),
        LibraryTab.actions => _actions(schemas),
        LibraryTab.shortcuts => _shortcuts(),
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppleSpacing.xl, AppleSpacing.md, AppleSpacing.xl, 0),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: AppleSpacing.sm,
              spacing: AppleSpacing.md,
              children: [
                SegmentedControl<LibraryTab>(
                  segments: {
                    if (_hasApps) LibraryTab.apps: _seg(tr('Apps')),
                    LibraryTab.actions: _seg(tr('Ações')),
                    LibraryTab.shortcuts: _seg(tr('Atalhos')),
                  },
                  value: tab,
                  onChanged: (t) => setState(() => _tab = t),
                ),
                SizedBox(
                  width: 260,
                  child: AppleSearchField(
                    controller: _search,
                    placeholder: tr('Buscar'),
                    onChanged: (v) => setState(() => _query = v),
                    trailing: Text('$count'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppleSpacing.xl, AppleSpacing.md, AppleSpacing.xl, AppleSpacing.xs),
            child: Text(
              title,
              style: type.footnote.copyWith(
                color: c.secondaryLabel,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: body),
        ],
      );
    });
  }

  Widget _seg(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.md, vertical: 2),
        child: Text(text),
      );

  // ---- Apps ----

  (String, int, Widget) _apps() {
    final title = LibraryPanel.appsTitle(widget.platform);
    final apps = widget.apps;
    if (apps == null) {
      final c = AppleColors.of(context);
      return (
        title,
        0,
        Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.secondaryLabel),
          ),
        ),
      );
    }
    final found = filterApps(apps, _query);
    if (found.isEmpty) {
      return (
        title,
        0,
        _empty(Icons.apps_rounded,
            apps.isEmpty ? tr('Nenhum app encontrado no PC') : tr('Nada com "{q}"', {'q': _query.trim()})),
      );
    }
    return (
      title,
      found.length,
      _grid(
        found.length,
        (i) {
          final app = found[i];
          return _LibraryTile(
            item: LibraryItem.fromApp(app),
            icon: AppIconView(app: app, size: 50),
            onAdd: widget.onAdd,
          );
        },
      ),
    );
  }

  // ---- Ações ----

  (String, int, Widget) _actions(List<ActionSchema> schemas) {
    final groups = groupActions(schemas, widget.platform);
    final filtered = <(String, List<ActionSchema>)>[
      for (final (cat, list) in groups)
        if (_query.trim().isEmpty)
          (cat, list)
        else
          (cat, fuzzyFilter(list, _query, (s) => '${s.title} $cat ${s.description ?? ''}')),
    ].where((g) => g.$2.isNotEmpty).toList();
    final total = filtered.fold<int>(0, (n, g) => n + g.$2.length);
    if (total == 0) {
      return (tr('Ações'), 0, _empty(Icons.bolt_rounded, tr('Nada com "{q}"', {'q': _query.trim()})));
    }
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return (
      tr('Ações'),
      total,
      CustomScrollView(
        slivers: [
          for (final (cat, list) in filtered) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(AppleSpacing.xl, AppleSpacing.sm, AppleSpacing.xl, AppleSpacing.xs),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Icon(categoryStyle(cat).$1, size: 15, color: systemColor(c, categoryStyle(cat).$2)),
                    const SizedBox(width: AppleSpacing.xs),
                    Text(cat, style: type.subheadline.copyWith(color: c.label, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(AppleSpacing.lg, 0, AppleSpacing.lg, AppleSpacing.md),
              sliver: SliverGrid(
                gridDelegate: _gridDelegate,
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final s = list[i];
                    final color = systemColor(c, categoryStyle(cat).$2);
                    return _LibraryTile(
                      item: LibraryItem.fromAction(s),
                      icon: _GlyphTile(icon: actionGlyph(s), color: color, size: 46),
                      onAdd: widget.onAdd,
                    );
                  },
                  childCount: list.length,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---- Atalhos ----

  List<(String, String)> get _presets => switch (widget.platform?.os) {
        'macos' => [
            (tr('Copiar'), '#c'),
            (tr('Colar'), '#v'),
            (tr('Desfazer'), '#z'),
            (tr('Captura de tela'), '#+4'),
            ('Spotlight', '# '),
            ('Mission Control', '^{UP}'),
            (tr('Trocar de app'), '#{TAB}'),
            (tr('Bloquear tela'), '^#q'),
          ],
        'linux' => [
            (tr('Copiar'), '^c'),
            (tr('Colar'), '^v'),
            (tr('Desfazer'), '^z'),
            (tr('Captura de tela'), '{PRTSC}'),
            (tr('Terminal'), '^%t'),
            (tr('Trocar de app'), '%{TAB}'),
            (tr('Bloquear tela'), '#l'),
          ],
        _ => [
            (tr('Copiar'), '^c'),
            (tr('Colar'), '^v'),
            (tr('Desfazer'), '^z'),
            (tr('Captura de tela'), '#+s'),
            (tr('Gerenciador de Tarefas'), '^+{ESC}'),
            (tr('Mostrar a área de trabalho'), '#d'),
            (tr('Trocar de app'), '%{TAB}'),
            (tr('Bloquear tela'), '#l'),
          ],
      };

  (String, int, Widget) _shortcuts() {
    final p = widget.platform;
    if (p != null && p.capabilities.isNotEmpty && !p.has('keyboard')) {
      final pkg = p.missing['keyboard'];
      return (
        tr('Atalhos'),
        0,
        _empty(
          Icons.keyboard_rounded,
          tr('Este computador ainda não envia teclas.'),
          message: pkg == null || pkg.isEmpty ? null : tr('Instale {package} no PC.', {'package': pkg}),
        ),
      );
    }
    final presets = fuzzyFilter(_presets, _query, (e) => e.$1);
    final c = AppleColors.of(context);
    return (
      tr('Atalhos'),
      presets.length,
      CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(AppleSpacing.xl, 0, AppleSpacing.xl, AppleSpacing.md),
            sliver: SliverToBoxAdapter(
              child: ShortcutRecorder(mac: _mac, onAdd: widget.onAdd),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(AppleSpacing.lg, 0, AppleSpacing.lg, AppleSpacing.md),
            sliver: SliverGrid(
              gridDelegate: _gridDelegate,
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final (label, keys) = presets[i];
                  final display = prettyKeys(keys, mac: _mac);
                  final nativeLock = keys == '#l' && (widget.platform == null || widget.platform!.has('power.lock'));
                  return _LibraryTile(
                    item: nativeLock ? LibraryItem.lockComputer(label) : LibraryItem.fromShortcut(keys, display, label: label),
                    icon: _KeycapTile(text: display, size: 46, color: c.gray),
                    onAdd: widget.onAdd,
                  );
                },
                childCount: presets.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Comum ----

  static const _gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 104,
    mainAxisExtent: 96,
    crossAxisSpacing: AppleSpacing.xxs,
    mainAxisSpacing: AppleSpacing.xxs,
  );

  Widget _grid(int count, Widget Function(int) item) => GridView.builder(
        padding: const EdgeInsets.fromLTRB(AppleSpacing.lg, 0, AppleSpacing.lg, AppleSpacing.lg),
        gridDelegate: _gridDelegate,
        itemCount: count,
        itemBuilder: (_, i) => item(i),
      );

  Widget _empty(IconData icon, String title, {String? message}) => Center(
        child: SingleChildScrollView(
          child: EmptyState(icon: icon, title: title, message: message),
        ),
      );
}

/// Um item da biblioteca: ícone e nome. Arrasta para uma casa; clique duplo adiciona.
class _LibraryTile extends StatefulWidget {
  final LibraryItem item;
  final Widget icon;
  final ValueChanged<LibraryItem> onAdd;

  const _LibraryTile({required this.item, required this.icon, required this.onAdd});

  @override
  State<_LibraryTile> createState() => _LibraryTileState();
}

class _LibraryTileState extends State<_LibraryTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    // A mesma tecla grafite do deck, com o ícone colorido dentro (no escuro, mais
    // funda que o painel, como nos prints).
    final dark = Theme.of(context).brightness == Brightness.dark;
    final well = Container(
      width: 62,
      height: 62,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: dark
            ? (_hover ? const Color(0xFF222224) : const Color(0xFF141415))
            : (_hover ? c.secondaryFill : c.tertiaryFill),
        shape: AppleShapes.squircle(
          AppleShapes.tileRadius(62),
          side: dark ? AppleShapes.hairline(const Color(0x1AFFFFFF)) : BorderSide.none,
        ),
      ),
      child: widget.icon,
    );
    final tile = MouseRegion(
      cursor: SystemMouseCursors.grab,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onDoubleTap: () => widget.onAdd(widget.item),
        child: Tooltip(
          message: widget.item.subtitle ?? widget.item.title,
          waitDuration: const Duration(milliseconds: 600),
          child: Column(
            children: [
              const SizedBox(height: AppleSpacing.xxs),
              AnimatedScale(
                scale: _hover ? 1.05 : 1,
                duration: AppleMotion.of(context, AppleMotion.fast),
                curve: AppleMotion.snappy,
                child: well,
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  widget.item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: type.caption1.copyWith(color: c.label),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Draggable<DeckDrag>(
      data: LibraryDrag(widget.item),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Transform.translate(
        offset: const Offset(-31, -31),
        child: Material(
          type: MaterialType.transparency,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: AppleShapes.squircle(AppleShapes.tileRadius(62)),
              shadows: AppleShadows.floating(Theme.of(context).brightness),
            ),
            child: well,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: tile),
      child: tile,
    );
  }
}

/// Glifo branco num squircle colorido, com o brilho das teclas do iOS.
class _GlyphTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _GlyphTile({required this.icon, required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(color, Colors.white, 0.2)!, color],
        ),
        shape: AppleShapes.squircle(AppleShapes.tileRadius(size)),
      ),
      child: Icon(icon, size: size * 0.5, color: AppleColors.onColor(color)),
    );
  }
}

/// Tecla de teclado com o atalho escrito (⌘C).
class _KeycapTile extends StatelessWidget {
  final String text;
  final double size;
  final Color color;

  const _KeycapTile({required this.text, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(
        color: c.isDark ? const Color(0xFF3A3A3C) : Colors.white,
        shape: AppleShapes.squircle(AppleShapes.tileRadius(size), side: AppleShapes.hairline(c.opaqueSeparator)),
        shadows: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), offset: const Offset(0, 1.5))],
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(text, style: TextStyle(color: c.label, fontWeight: FontWeight.w600, fontSize: 15)),
      ),
    );
  }
}

/// Grava um atalho: clique no campo e aperte as teclas. O resultado vira um item que se
/// arrasta para o deck (ou "Adicionar").
class ShortcutRecorder extends StatefulWidget {
  final bool mac;
  final ValueChanged<LibraryItem> onAdd;

  const ShortcutRecorder({super.key, required this.mac, required this.onAdd});

  @override
  State<ShortcutRecorder> createState() => _ShortcutRecorderState();
}

class _ShortcutRecorderState extends State<ShortcutRecorder> {
  final _focus = FocusNode(debugLabel: 'shortcut-recorder');
  KeyCombo? _combo;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.handled;
    if (KeyCombo.isModifier(e.logicalKey)) return KeyEventResult.handled;
    final kb = HardwareKeyboard.instance;
    final combo = KeyCombo(
      e.logicalKey,
      ctrl: kb.isControlPressed,
      shift: kb.isShiftPressed,
      alt: kb.isAltPressed,
      meta: kb.isMetaPressed,
    );
    if (combo.isValid) setState(() => _combo = combo);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final recording = _focus.hasFocus;
    final combo = _combo;
    final display = combo?.display(mac: widget.mac);
    final item = combo == null ? null : LibraryItem.fromShortcut(combo.sendKeys, display!);
    final field = Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: GestureDetector(
        onTap: () => _focus.requestFocus(),
        child: AnimatedContainer(
          duration: AppleMotion.of(context, AppleMotion.fast),
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.md),
          decoration: BoxDecoration(
            color: c.tertiaryFill,
            borderRadius: BorderRadius.circular(AppleRadii.md),
            border: Border.all(
              color: recording ? c.accent : c.separator,
              width: recording ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.keyboard_rounded, size: 20, color: recording ? c.accent : c.secondaryLabel),
              const SizedBox(width: AppleSpacing.sm),
              Expanded(
                child: display != null
                    ? Text(display, style: type.title3.copyWith(color: c.label, letterSpacing: 1))
                    : Text(
                        recording
                            ? tr('Aperte as teclas do atalho…')
                            : tr('Clique aqui e aperte um atalho para gravar'),
                        style: type.subheadline.copyWith(color: c.secondaryLabel),
                      ),
              ),
              if (recording && display != null)
                Text(tr('Gravando'), style: type.caption1.copyWith(color: c.accent)),
            ],
          ),
        ),
      ),
    );
    return Row(
      children: [
        Expanded(child: field),
        const SizedBox(width: AppleSpacing.sm),
        if (item != null)
          Draggable<DeckDrag>(
            data: LibraryDrag(item),
            feedback: Material(
              type: MaterialType.transparency,
              child: _KeycapTile(text: display!, size: 52, color: c.gray),
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: _KeycapTile(text: display, size: 52, color: c.gray),
            ),
          ),
        const SizedBox(width: AppleSpacing.sm),
        PrimaryButton(
          label: tr('Adicionar'),
          icon: Icons.add_rounded,
          compact: true,
          onPressed: item == null ? null : () => widget.onAdd(item),
        ),
      ],
    );
  }
}
