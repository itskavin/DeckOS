import 'dart:convert';
import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../buttons/button_icons.dart';
import '../buttons/colors.dart';
import 'connected_clients.dart';
import 'grid_placement.dart';
import 'slot_ops.dart';

/// Ação do menu de uma página.
enum PageMenuAction { rename, pageGrid, settings, duplicate, share, delete }

/// Uma linha da lista de páginas: o perfil e o recuo (pasta dentro de outra página).
typedef PageEntry = ({DeckProfile profile, int depth});

/// Páginas na ordem da lista, com as pastas (perfis abertos por um botão "Abrir perfil"
/// de outra página) logo abaixo da página de cima que as abre, recuadas num só nível
/// (a pasta de uma pasta fica junto da página-raiz).
List<PageEntry> pageTree(List<DeckProfile> profiles) {
  final ids = {for (final p in profiles) p.id};
  final parentOf = <String, String>{};
  for (final p in profiles) {
    for (final b in p.buttons) {
      if (b.action?.type != 'open_profile') continue;
      final target = b.action!.parameters['profileId'];
      if (target == null || target == p.id || !ids.contains(target)) continue;
      parentOf.putIfAbsent(target, () => p.id);
    }
  }
  // Sobe pelos pais até a página de cima. Ciclo sem entrada (um abre o outro) não tem
  // raiz: vira página, para não sumir da lista.
  String? rootOf(String id) {
    final seen = {id};
    var cur = id;
    while (parentOf.containsKey(cur)) {
      cur = parentOf[cur]!;
      if (!seen.add(cur)) return null;
    }
    return cur == id ? null : cur;
  }

  final rootFor = <String, String>{};
  for (final id in parentOf.keys) {
    final root = rootOf(id);
    if (root != null) rootFor[id] = root;
  }
  final out = <PageEntry>[];
  for (final p in profiles) {
    if (rootFor.containsKey(p.id)) continue;
    out.add((profile: p, depth: 0));
    for (final child in profiles) {
      if (rootFor[child.id] == p.id) out.add((profile: child, depth: 1));
    }
  }
  return out;
}

/// Só as páginas de cima, na ordem da lista: é o que o deck do celular desliza e o que os
/// pontinhos contam. Pasta só abre pelo botão dela.
List<DeckProfile> topLevelPages(List<DeckProfile> profiles) => [
      for (final e in pageTree(profiles))
        if (e.depth == 0) e.profile,
    ];

/// A página de cima que contém [profile]: ele mesmo, ou a página que abre a pasta.
/// Null se [profile] não está na lista.
DeckProfile? topLevelPageOf(List<DeckProfile> profiles, DeckProfile profile) {
  DeckProfile? page;
  for (final e in pageTree(profiles)) {
    if (e.depth == 0) page = e.profile;
    if (e.profile.id == profile.id) return page;
  }
  return null;
}

/// Barra lateral do configurador no PC: estado do celular conectado, PC controlado e páginas.
class DesktopSidebar extends StatefulWidget {
  final List<DeckProfile> profiles;
  final DeckProfile? current;
  final int rows;
  final int columns;

  final String? pcName;
  final PlatformInfo? platform;
  final bool connected;
  final ConnectedClientsState clients;
  final String? version;

  final ValueChanged<DeckProfile> onSelect;
  final void Function(DeckProfile profile, String name) onRename;
  final void Function(DeckProfile profile, PageMenuAction action) onMenu;
  final void Function(int from, int to) onReorder;
  final VoidCallback onNewPage;
  final VoidCallback? onLayoutTap;

  /// Ferramentas (integrações, automações, aparência, backup).
  final List<({IconData icon, String label, VoidCallback onTap})> tools;
  final VoidCallback onAbout;
  final VoidCallback onHelp;

  const DesktopSidebar({
    super.key,
    required this.profiles,
    required this.current,
    required this.rows,
    required this.columns,
    required this.pcName,
    required this.platform,
    required this.connected,
    this.clients = const ConnectedClientsState.unknown(),
    required this.version,
    required this.onSelect,
    required this.onRename,
    required this.onMenu,
    required this.onReorder,
    required this.onNewPage,
    this.onLayoutTap,
    required this.tools,
    required this.onAbout,
    required this.onHelp,
  });

  @override
  State<DesktopSidebar> createState() => DesktopSidebarState();
}

class DesktopSidebarState extends State<DesktopSidebar> {
  String? _renaming;

  /// Abre o nome da página para editar ali mesmo.
  void startRename(String profileId) => setState(() => _renaming = profileId);

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final entries = pageTree(widget.profiles);
    // Só as páginas de cima têm número: pasta não conta.
    final number = <String, int>{};
    for (final e in entries) {
      if (e.depth == 0) number[e.profile.id] = number.length + 1;
    }

    return GlassPanel(
      radius: AppleRadii.lg,
      padding: const EdgeInsets.all(AppleSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PhoneDeckCard(
            clients: widget.clients,
            serverConnected: widget.connected,
            rows: widget.rows,
            columns: widget.columns,
            onLayoutTap: widget.onLayoutTap,
          ),
          const SizedBox(height: AppleSpacing.xs),
          _HostPcRow(
            pcName: widget.pcName,
            platform: widget.platform,
            connected: widget.connected,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppleSpacing.xs, AppleSpacing.md, AppleSpacing.xs, AppleSpacing.xs),
            child: Text(
              tr('Páginas'),
              style: type.footnote.copyWith(
                color: c.secondaryLabel,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: entries.length + 1,
              proxyDecorator: (child, _, _) =>
                  Material(type: MaterialType.transparency, child: child),
              onReorderItem: (from, to) {
                if (from >= entries.length) return;
                to = to.clamp(0, entries.length - 1);
                final moved = entries[from].profile;
                final target = entries[to].profile;
                final a = widget.profiles.indexWhere((p) => p.id == moved.id);
                final b = widget.profiles.indexWhere((p) => p.id == target.id);
                if (a != -1 && b != -1) widget.onReorder(a, b);
              },
              itemBuilder: (context, i) {
                if (i == entries.length) {
                  return KeyedSubtree(
                    key: const ValueKey('new-page'),
                    child: _NewPageRow(onTap: widget.onNewPage),
                  );
                }
                final e = entries[i];
                return ReorderableDragStartListener(
                  key: ValueKey(e.profile.id),
                  index: i,
                  child: _PageRow(
                    profile: e.profile,
                    depth: e.depth,
                    number: number[e.profile.id] ?? i + 1,
                    rows: widget.rows,
                    columns: widget.columns,
                    selected: e.profile.id == widget.current?.id,
                    renaming: _renaming == e.profile.id,
                    onTap: () => widget.onSelect(e.profile),
                    onStartRename: () => startRename(e.profile.id),
                    onRename: (name) {
                      setState(() => _renaming = null);
                      final n = name.trim();
                      if (n.isNotEmpty && n != e.profile.name) {
                        widget.onRename(e.profile, n);
                      }
                    },
                    onMenu: (a) {
                      if (a == PageMenuAction.rename) {
                        startRename(e.profile.id);
                      } else {
                        widget.onMenu(e.profile, a);
                      }
                    },
                  ),
                );
              },
            ),
          ),
          Divider(height: AppleSpacing.md, thickness: 1, color: c.separator),
          for (final t in widget.tools)
            _FooterRow(icon: t.icon, label: t.label, onTap: t.onTap),
          Divider(height: AppleSpacing.md, thickness: 1, color: c.separator),
          _FooterRow(
            icon: Icons.info_outline_rounded,
            label: tr('Sobre o DeckOS'),
            trailing: widget.version == null ? null : 'v${widget.version}',
            onTap: widget.onAbout,
          ),
          _FooterRow(
            icon: Icons.help_outline_rounded,
            label: tr('Ajuda e sugestões'),
            onTap: widget.onHelp,
          ),
        ],
      ),
    );
  }
}

/// Cartão do celular/deck conectado — separado do PC controlado para nunca confundir os dois.
class _PhoneDeckCard extends StatelessWidget {
  final ConnectedClientsState clients;
  final bool serverConnected;
  final int rows;
  final int columns;
  final VoidCallback? onLayoutTap;

  const _PhoneDeckCard({
    required this.clients,
    required this.serverConnected,
    required this.rows,
    required this.columns,
    this.onLayoutTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final phone = clients.primaryPhone;
    final extraCount = math.max(0, clients.phoneCount - 1);

    final Color dotColor;
    final String title;
    final String statusText;
    final IconData deviceIcon;

    if (!serverConnected) {
      dotColor = c.red;
      title = tr('Celular');
      statusText = tr('Status do celular indisponível');
      deviceIcon = Icons.smartphone_rounded;
    } else if (!clients.known) {
      dotColor = c.gray;
      title = tr('Celular');
      statusText = tr('Status do celular indisponível');
      deviceIcon = Icons.smartphone_rounded;
    } else if (phone == null) {
      dotColor = c.orange;
      title = tr('Nenhum celular conectado');
      statusText = tr('Abra o DeckOS no celular para conectar');
      deviceIcon = Icons.phonelink_off_rounded;
    } else {
      dotColor = c.green;
      title = phone.displayName;
      final meta = [
        if (phone.distinctModel != null) phone.distinctModel!,
        if (phone.metaSummary.isNotEmpty) phone.metaSummary,
      ].join(' · ');
      statusText = meta.isEmpty ? tr('Conectado') : meta;
      deviceIcon = phone.isWebDeck ? Icons.devices_rounded : Icons.smartphone_rounded;
    }

    final gridLabel = tr('grade {cols} × {rows}', {'cols': columns, 'rows': rows});

    final card = Container(
      key: const ValueKey('sidebar-phone-card'),
      padding: const EdgeInsets.all(AppleSpacing.sm),
      decoration: BoxDecoration(
        color: c.isDark ? c.tertiaryGroupedBackground : c.background,
        borderRadius: BorderRadius.circular(AppleRadii.md),
        border: Border.all(
          color: phone != null ? c.green.withValues(alpha: 0.35) : c.separator,
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: (phone != null ? c.green : c.gray).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppleRadii.sm),
              border: Border.all(
                color: (phone != null ? c.green : c.gray).withValues(alpha: 0.24),
                width: 1,
              ),
            ),
            child: Icon(
              deviceIcon,
              color: phone != null ? c.green : c.secondaryLabel,
              size: 20,
            ),
          ),
          const SizedBox(width: AppleSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.subheadline.copyWith(
                          color: c.label,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (extraCount > 0) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: c.accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '+$extraCount',
                          style: type.caption2.copyWith(
                            color: c.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    StatusDot(color: dotColor, size: 6, glow: false),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        statusText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.caption1.copyWith(color: c.secondaryLabel),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  gridLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.caption2.copyWith(
                    color: onLayoutTap != null ? c.accent : c.tertiaryLabel,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (onLayoutTap != null)
            Icon(Icons.chevron_right_rounded, size: 18, color: c.tertiaryLabel),
        ],
      ),
    );
    if (onLayoutTap == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: tr('Layout da grade'),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onLayoutTap,
          child: card,
        ),
      ),
    );
  }
}

/// Faixa discreta identificando o computador controlado pelo servidor do DeckOS.
class _HostPcRow extends StatelessWidget {
  final String? pcName;
  final PlatformInfo? platform;
  final bool connected;

  const _HostPcRow({
    required this.pcName,
    required this.platform,
    required this.connected,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final os = switch (platform?.os) {
      'macos' => 'macOS',
      'windows' => 'Windows',
      'linux' => 'Linux',
      _ => null,
    };
    final subtitle = [
      ?os,
      connected ? tr('Servidor ativo') : tr('Offline'),
    ].join(' · ');

    return Container(
      key: const ValueKey('sidebar-pc-card'),
      padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.sm, vertical: 8),
      decoration: BoxDecoration(
        color: c.tertiaryFill.withValues(alpha: c.isDark ? 0.55 : 0.7),
        borderRadius: BorderRadius.circular(AppleRadii.sm),
        border: Border.all(color: c.separator, width: 1),
      ),
      child: Row(
        children: [
          Icon(
            platform?.isMac ?? false ? Icons.laptop_mac_rounded : Icons.computer_rounded,
            size: 16,
            color: c.secondaryLabel,
          ),
          const SizedBox(width: AppleSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pcName ?? tr('Este computador'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.caption1.copyWith(
                    color: c.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.caption2.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
          ),
          StatusDot(color: connected ? c.green : c.red, size: 6, glow: false),
        ],
      ),
    );
  }
}

class _PageRow extends StatefulWidget {
  final DeckProfile profile;
  final int depth;
  final int number;
  final int rows;
  final int columns;
  final bool selected;
  final bool renaming;
  final VoidCallback onTap;
  final VoidCallback onStartRename;
  final ValueChanged<String> onRename;
  final ValueChanged<PageMenuAction> onMenu;

  const _PageRow({
    required this.profile,
    required this.depth,
    required this.number,
    required this.rows,
    required this.columns,
    required this.selected,
    required this.renaming,
    required this.onTap,
    required this.onStartRename,
    required this.onRename,
    required this.onMenu,
  });

  @override
  State<_PageRow> createState() => _PageRowState();
}

class _PageRowState extends State<_PageRow> {
  bool _hover = false;
  late final _name = TextEditingController(text: widget.profile.name);
  final _focus = FocusNode();

  @override
  void didUpdateWidget(_PageRow old) {
    super.didUpdateWidget(old);
    if (widget.renaming && !old.renaming) {
      _name.text = widget.profile.name;
      _name.selection = TextSelection(baseOffset: 0, extentOffset: _name.text.length);
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
    }
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && widget.renaming) widget.onRename(_name.text);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _showMenu(Offset global) async {
    final c = AppleColors.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    PopupMenuItem<PageMenuAction> item(PageMenuAction a, IconData icon, String label,
            {bool destructive = false}) =>
        PopupMenuItem(
          value: a,
          height: 36,
          child: Row(
            children: [
              Icon(icon, size: 17, color: destructive ? c.red : c.label),
              const SizedBox(width: AppleSpacing.sm),
              Text(label, style: TextStyle(color: destructive ? c.red : c.label)),
            ],
          ),
        );
    final picked = await showMenu<PageMenuAction>(
      context: context,
      position: RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size),
      color: c.tertiaryGroupedBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleRadii.md),
        side: BorderSide(color: c.separator, width: 1),
      ),
      items: [
        item(PageMenuAction.rename, Icons.edit_outlined, tr('Renomear')),
        item(PageMenuAction.pageGrid, Icons.grid_on_rounded, tr('Grade desta página')),
        item(PageMenuAction.settings, Icons.auto_awesome_outlined, tr('Troca automática…')),
        item(PageMenuAction.duplicate, Icons.content_copy_rounded, tr('Duplicar')),
        item(PageMenuAction.share, Icons.share_outlined, tr('Compartilhar')),
        const PopupMenuDivider(height: 8),
        item(PageMenuAction.delete, Icons.delete_outline_rounded, tr('Apagar página'),
            destructive: true),
      ],
    );
    if (picked != null) widget.onMenu(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final p = widget.profile;
    final pageGrid = p.customGrid;
    final baseRows = pageGrid?.rows ?? widget.rows;
    final baseCols = pageGrid?.columns ?? widget.columns;
    final min = SlotOps.minGrid(p.buttons);
    final effRows = math.max(baseRows, min.rows);
    final effCols = math.max(baseCols, min.columns);
    final total = effRows * effCols;
    final used = SlotOps.visibleCount(p.buttons, effRows, effCols);
    final isFolder = widget.depth > 0;
    final title = widget.renaming
        ? SizedBox(
            height: 24,
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape): () {
                  _name.text = p.name;
                  _focus.unfocus();
                },
              },
              child: TextField(
                controller: _name,
                focusNode: _focus,
                style: type.subheadline.copyWith(color: c.label, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: c.tertiaryFill,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: c.accent),
                  ),
                ),
                onSubmitted: widget.onRename,
              ),
            ),
          )
        : Text(p.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.subheadline.copyWith(color: c.label, fontWeight: FontWeight.w600));
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTap: widget.onStartRename,
        onSecondaryTapDown: (d) => _showMenu(d.globalPosition),
        child: AnimatedContainer(
          duration: AppleMotion.of(context, AppleMotion.fast),
          margin: EdgeInsets.only(left: widget.depth * 18.0, bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.xs, vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected
                ? c.fill
                : (_hover ? c.tertiaryFill : Colors.transparent),
            borderRadius: BorderRadius.circular(AppleRadii.sm),
          ),
          child: Row(
            children: [
              PageThumbnail(
                  profile: p, rows: baseRows, columns: baseCols, width: isFolder ? 44 : 56),
              const SizedBox(width: AppleSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (isFolder) ...[
                          Icon(Icons.folder_rounded, size: 13, color: c.secondaryLabel),
                          const SizedBox(width: 4),
                        ],
                        Expanded(child: title),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      [
                        isFolder
                            ? tr('Pasta · {used}/{total}', {'used': used, 'total': total})
                            : tr('Página {n} · {used}/{total}',
                                {'n': widget.number, 'used': used, 'total': total}),
                        if (pageGrid != null) '${pageGrid.columns}×${pageGrid.rows}',
                      ].join(' · '),
                      style: type.caption1.copyWith(color: c.secondaryLabel),
                    ),
                  ],
                ),
              ),
              if (_hover && !widget.renaming)
                Builder(
                  builder: (context) => GestureDetector(
                    onTapDown: (d) => _showMenu(d.globalPosition),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.more_horiz_rounded, size: 18, color: c.secondaryLabel),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Miniatura de uma página: a grade com a cor de cada botão.
class PageThumbnail extends StatelessWidget {
  final DeckProfile profile;
  final int rows;
  final int columns;
  final double width;

  const PageThumbnail({
    super.key,
    required this.profile,
    required this.rows,
    required this.columns,
    this.width = 56,
  });

  @override
  Widget build(BuildContext context) {
    final deck = DeckTheme.of(context);
    final height = width * 0.62;
    final min = SlotOps.minGrid(profile.buttons);
    final effRows = math.max(rows, min.rows);
    final effCols = math.max(columns, min.columns);
    final layout = GridLayout.of(profile.buttons, effRows, effCols);
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: ShapeDecoration(color: deck.background, shape: AppleShapes.squircle(6)),
      child: LayoutBuilder(builder: (context, c) {
        const gap = 1.5;
        final cell = math.max(
            1.0,
            math.min((c.maxWidth - gap * (effCols - 1)) / effCols,
                (c.maxHeight - gap * (effRows - 1)) / effRows));
        final step = cell + gap;
        double size(int span) => span * cell + (span - 1) * gap;
        return Center(
          child: SizedBox(
            width: size(effCols),
            height: size(effRows),
            child: Stack(
              children: [
                for (var r = 0; r < effRows; r++)
                  for (var col = 0; col < effCols; col++)
                    if (layout.isFree(r, col))
                      Positioned(
                        left: col * step,
                        top: r * step,
                        width: cell,
                        height: cell,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: deck.emptyTileColor,
                            shape: AppleShapes.squircle(cell * 0.28),
                          ),
                        ),
                      ),
                for (final pl in layout.placements)
                  Positioned(
                    left: pl.column * step,
                    top: pl.row * step,
                    width: size(pl.columnSpan),
                    height: size(pl.rowSpan),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: deck.tileColor,
                        shape: AppleShapes.squircle(cell * 0.28),
                      ),
                      child: Center(child: _art(pl.button, deck, cell)),
                    ),
                  ),
              ],
            ),
          ),
        );
      }),
    );
  }

  /// Miniatura do que a tecla mostra: o ícone do app, o glifo ou um ponto.
  static Widget _art(DeckButton b, DeckTheme deck, double cell) {
    final data = b.iconBase64;
    if (data != null && data.isNotEmpty) {
      try {
        final bytes = base64Decode(
            data.startsWith('data:') ? data.substring(data.indexOf(',') + 1) : data);
        return ClipRSuperellipse(
          borderRadius: BorderRadius.circular(cell * 0.16),
          child: Image.memory(bytes,
              width: cell * 0.72,
              height: cell * 0.72,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium),
        );
      } catch (_) {}
    }
    final color = parseHexColor(b.backgroundColor);
    final fg = color != null && HSLColor.fromColor(color).saturation >= 0.15
        ? color
        : deck.foreground;
    if (b.iconName?.isNotEmpty ?? false) {
      return Icon(buttonIconData(b.iconName!), size: cell * 0.5, color: fg);
    }
    return Container(
      width: cell * 0.3,
      height: cell * 0.3,
      decoration: ShapeDecoration(color: fg.withValues(alpha: 0.6), shape: const CircleBorder()),
    );
  }
}

class _NewPageRow extends StatefulWidget {
  final VoidCallback onTap;
  const _NewPageRow({required this.onTap});

  @override
  State<_NewPageRow> createState() => _NewPageRowState();
}

class _NewPageRowState extends State<_NewPageRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.xs, vertical: 7),
          child: Row(
            children: [
              CustomPaint(
                painter: _DashedSquircle(color: _hover ? c.accent : c.tertiaryLabel),
                child: SizedBox(
                  width: 56,
                  height: 34.7,
                  child: Icon(Icons.add_rounded,
                      size: 18, color: _hover ? c.accent : c.secondaryLabel),
                ),
              ),
              const SizedBox(width: AppleSpacing.sm),
              Text(tr('Nova página'),
                  style: type.subheadline.copyWith(color: _hover ? c.accent : c.secondaryLabel)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedSquircle extends CustomPainter {
  final Color color;
  _DashedSquircle({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + 4, m.length)), paint);
        d += 7;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedSquircle old) => old.color != color;
}

class _FooterRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  final VoidCallback onTap;

  const _FooterRow({required this.icon, required this.label, required this.onTap, this.trailing});

  @override
  State<_FooterRow> createState() => _FooterRowState();
}

class _FooterRowState extends State<_FooterRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.xs, vertical: 6),
          decoration: BoxDecoration(
            color: _hover ? c.tertiaryFill : Colors.transparent,
            borderRadius: BorderRadius.circular(AppleRadii.sm),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 17, color: c.secondaryLabel),
              const SizedBox(width: AppleSpacing.sm),
              Expanded(
                child: Text(widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.footnote.copyWith(color: c.label)),
              ),
              if (widget.trailing != null)
                Text(widget.trailing!, style: type.caption1.copyWith(color: c.tertiaryLabel)),
            ],
          ),
        ),
      ),
    );
  }
}
