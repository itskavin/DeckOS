import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:deckos/src/ai_limits/ai_limits_settings_page.dart';
import 'package:deckos/src/config/appearance_settings_page.dart';
import 'package:deckos/src/config/integrations_page.dart';
import 'package:deckos/src/config/triggers_page.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/actions/action_catalog.dart';
import 'package:deckos/src/stream_deck/backup/backup_buttons.dart';
import 'package:deckos/src/stream_deck/stream_deck_controller.dart';
import 'package:deckos/src/stream_deck/widgets/button_property_panel.dart';
import 'package:deckos/src/stream_deck/widgets/copy_move_dialog.dart';
import 'package:deckos/src/stream_deck/widgets/deck_layout_sheet.dart';
import 'package:deckos/src/stream_deck/widgets/profile_settings_dialog.dart';
import 'package:deckos/src/stream_deck/widgets/share_profile_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_icon.dart';
import 'command_palette.dart';
import 'connected_clients.dart';
import 'deck_mirror.dart';
import 'desktop_sidebar.dart';
import 'library_items.dart';
import 'library_panel.dart';
import 'slot_ops.dart';

/// Configurador no PC (navegador em localhost): barra lateral com as páginas, o espelho
/// ao vivo do celular, a biblioteca de apps/ações/atalhos e o inspetor do botão.
class SteamDeckDesktopLayout extends StatefulWidget {
  final StreamDeckController controller;
  final VoidCallback onToggleFullscreen;
  final bool isFullscreen;

  const SteamDeckDesktopLayout({
    super.key,
    required this.controller,
    required this.onToggleFullscreen,
    required this.isFullscreen,
  });

  /// Abaixo disto a barra lateral vira gaveta e tudo fica numa coluna.
  static const compactWidth = 900.0;

  /// A partir disto o inspetor fica ao lado; abaixo, por cima do conteúdo.
  static const sideInspectorWidth = 1240.0;

  @override
  State<SteamDeckDesktopLayout> createState() => _SteamDeckDesktopLayoutState();
}

class _SteamDeckDesktopLayoutState extends State<SteamDeckDesktopLayout> {
  StreamDeckController get _ctl => widget.controller;

  Set<Slot> _selection = {};
  Slot? _anchor;

  /// Botão aberto no inspetor (salvo, ou novo com id vazio).
  DeckButton? _editing;

  /// Como o botão está no inspetor agora (o espelho mostra enquanto se edita).
  DeckButton? _draft;

  bool? _landscape;
  bool _dragging = false;
  bool _editingTitle = false;
  final _title = TextEditingController();
  final _titleFocus = FocusNode();

  PlatformInfo? _platform;
  List<InstalledApp>? _apps;
  bool _appsLoading = true;
  String? _pcName;
  String? _version;
  ConnectedClientsState _fetchedClients = const ConnectedClientsState.unknown();
  void Function()? _reconnectClientsCleanup;

  final _sidebarKey = GlobalKey<DesktopSidebarState>();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Chave do inspetor. Muda com o botão: o painel guarda o formulário no próprio estado
  /// (lido só ao abrir), e reaproveitar a chave deixava o formulário do botão anterior.
  var _panelKey = GlobalKey<ButtonPropertyPanelState>();
  String? _panelFor;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus && _editingTitle) _commitTitle();
    });
    final signalR = Injector.get<SignalRService>();
    signalR.listenState('ReceiveConnectedClients');
    var wasConnected = signalR.connectionStatus.value == 'Connected';
    _reconnectClientsCleanup = effect(() {
      final nowConnected = signalR.connectionStatus.value == 'Connected';
      if (nowConnected && !wasConnected) {
        untracked(_loadConnectedClients);
      }
      wasConnected = nowConnected;
    });
    // Aberto pelo link de um perfil compartilhado (site → localhost:4787/?import=...).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      importSharedProfileFromUrl(context, (id) async {
        await _ctl.loadProfiles();
        final p = _ctl.profiles.value.where((p) => p.id == id).firstOrNull;
        if (p != null) _ctl.currentProfile.value = p;
      });
    });
    _loadPc();
  }

  @override
  void dispose() {
    _reconnectClientsCleanup?.call();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _title.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  Future<void> _loadConnectedClients() async {
    try {
      final resp = await Injector.get<DeckOSClient>().getJson('/api/system/clients');
      if (!mounted) return;
      setState(() => _fetchedClients = ConnectedClientsState.fromPayload(resp));
    } catch (_) {
      // Servidor antigo ou offline: mantém estado desconhecido sem inventar dispositivo.
    }
  }

  Future<void> _loadPc() async {
    final client = Injector.get<DeckOSClient>();
    final signalR = Injector.get<SignalRService>();
    ActionCatalog.instance.load();
    client.getPlatform().then((p) {
      if (mounted) setState(() => _platform = p);
    });
    client.getApps().then((apps) {
      if (mounted) {
        setState(() {
          _apps = apps;
          _appsLoading = false;
        });
      }
    });
    client.getJson('/api/system/info').then((info) {
      if (info is Map && mounted) {
        setState(() {
          _pcName = info['name'] as String?;
          _version = info['version'] as String?;
        });
      }
    }).catchError((_) {});
    _loadConnectedClients();
    // Sem o SignalR (ainda), a grade salva no PC vale até o celular reportar outra.
    final layout = await client.getLayout();
    if (layout != null && (DemoBackend.enabled || signalR.connectionStatus.value != 'Connected')) {
      signalR.deckLayout.value = layout;
    }
  }

  // ---- Estado derivado ----

  bool get _connected =>
      DemoBackend.enabled || Injector.get<SignalRService>().connectionStatus.value == 'Connected';

  ConnectedClientsState get _clientsState {
    if (!_connected) return const ConnectedClientsState.unknown();
    final live = Injector.get<SignalRService>().stateOf('ReceiveConnectedClients');
    if (live.containsKey('clients')) {
      return ConnectedClientsState.fromPayload(live);
    }
    return _fetchedClients;
  }

  ({int rows, int columns}) get _grid {
    final lay = Injector.get<SignalRService>().deckLayout.value;
    return (rows: lay['rows'] ?? 3, columns: lay['columns'] ?? 5);
  }

  ({int rows, int columns}) _gridFor(DeckProfile? profile) =>
      profile?.customGrid ?? _grid;

  bool _isLandscapeFor(DeckProfile? profile) {
    final g = _gridFor(profile);
    return _landscape ?? (g.columns >= g.rows);
  }

  GlobalKey<ButtonPropertyPanelState> _keyFor(DeckButton b) {
    final id = b.id.isEmpty ? 'novo:${b.row}:${b.column}' : b.id;
    if (id != _panelFor) {
      _panelFor = id;
      _panelKey = GlobalKey<ButtonPropertyPanelState>();
    }
    return _panelKey;
  }

  // ---- Teclado ----

  bool _typing() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    if (focus.debugLabel == 'shortcut-recorder') return true;
    final ctx = focus.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _onKey(KeyEvent e) {
    if (!mounted || e is KeyUpEvent) return false;
    // Com um diálogo ou outra tela por cima, os atalhos são dela.
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    // Gravando um atalho: toda tecla é do gravador.
    if (FocusManager.instance.primaryFocus?.debugLabel == 'shortcut-recorder') return false;
    final kb = HardwareKeyboard.instance;
    final mod = kb.isControlPressed || kb.isMetaPressed;
    final k = e.logicalKey;
    if (mod && k == LogicalKeyboardKey.keyK) {
      _openPalette();
      return true;
    }
    if (_typing()) return false;
    if (mod && k == LogicalKeyboardKey.keyZ) {
      kb.isShiftPressed ? _redo() : _undo();
      return true;
    }
    if (mod && k == LogicalKeyboardKey.keyY) {
      _redo();
      return true;
    }
    if (mod && k == LogicalKeyboardKey.keyA) {
      final p = _ctl.currentProfile.value;
      if (p == null) return false;
      setState(() {
        _selection = {for (final b in p.buttons) slotOf(b)};
        _closeInspector();
      });
      return true;
    }
    if ((k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) && _selection.isNotEmpty) {
      _removeSlots(_selection);
      return true;
    }
    if (k == LogicalKeyboardKey.escape && (_selection.isNotEmpty || _editing != null)) {
      _guardDirty(() => setState(() {
            _selection = {};
            _closeInspector();
          }));
      return true;
    }
    return false;
  }

  // ---- Edição ----

  void _closeInspector() {
    _editing = null;
    _draft = null;
  }

  void _toast(String text, {VoidCallback? undo}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      width: 420,
      duration: const Duration(seconds: 4),
      // Com ação, o Flutter deixa o aviso na tela até alguém fechar; este some sozinho.
      persist: false,
      action: undo == null ? null : SnackBarAction(label: tr('Desfazer'), onPressed: undo),
    ));
  }

  Future<void> _undo() async {
    final label = await _ctl.undo();
    if (!mounted) return;
    setState(() {
      _selection = {};
      _closeInspector();
    });
    if (label != null) _toast(tr('Desfeito: {action}', {'action': label}));
  }

  Future<void> _redo() async {
    final label = await _ctl.redo();
    if (!mounted) return;
    setState(() {
      _selection = {};
      _closeInspector();
    });
    if (label != null) _toast(tr('Refeito: {action}', {'action': label}));
  }

  void _onSlotTap(Slot slot, DeckButton? button) {
    final kb = HardwareKeyboard.instance;
    final additive = kb.isControlPressed || kb.isMetaPressed;
    final range = kb.isShiftPressed;
    final profile = _ctl.currentProfile.value;
    if (profile == null) return;

    if (button != null && additive) {
      setState(() {
        final next = {..._selection};
        if (!next.remove(slot)) next.add(slot);
        _selection = next;
        _anchor = slot;
        _closeInspector();
      });
      return;
    }
    if (button != null && range && _anchor != null) {
      final g = _gridFor(profile);
      int order(Slot s) => s.row * g.columns + s.column;
      final a = math.min(order(_anchor!), order(slot)), b = math.max(order(_anchor!), order(slot));
      setState(() {
        _selection = {
          for (final x in profile.buttons)
            if (order(slotOf(x)) >= a && order(slotOf(x)) <= b) slotOf(x),
        };
        _closeInspector();
      });
      return;
    }
    if (_editing != null && slotOf(_editing!) == slot && _selection.length == 1) return;
    _guardDirty(() => setState(() {
          _selection = {slot};
          _anchor = slot;
          _editing = button ?? DeckButton(id: '', row: slot.row, column: slot.column, label: '');
          _draft = null;
        }));
  }

  Future<void> _onDrop(DeckDrag data, Slot target) async {
    final profile = _ctl.currentProfile.value;
    if (profile == null) return;
    final g = _gridFor(profile);
    final min = SlotOps.minGrid(profile.buttons);
    final rows = math.max(g.rows, min.rows);
    final cols = math.max(g.columns, min.columns);
    switch (data) {
      case ButtonDrag(:final from, :final group):
        if (group.length > 1) {
          final next = SlotOps.moveGroup(
              profile.buttons, group, target.row - from.row, target.column - from.column, rows, cols);
          if (next == null) {
            _toast(tr('Os botões não cabem ali.'));
            return;
          }
          await _ctl.commitButtons(next, tr('Mover botões'));
          setState(() {
            _selection = {
              for (final s in group) (row: s.row + target.row - from.row, column: s.column + target.column - from.column),
            };
            _closeInspector();
          });
        } else {
          final next = SlotOps.moveSafely(profile.buttons, from, target, rows: rows, columns: cols);
          if (next == null) {
            _toast(tr('Não cabe ali sem sobrepor outro botão.'));
            return;
          }
          await _ctl.commitButtons(next, tr('Mover botão'));
          setState(() {
            _selection = {target};
            _closeInspector();
          });
        }
      case LibraryDrag(:final item):
        await _addItem(item, at: target);
    }
  }

  Future<void> _openLayoutSheet({
    DeckProfile? targetProfile,
    DeckGridScope? initialScope,
  }) async {
    final current = targetProfile ?? _ctl.currentProfile.value;
    if (current == null) return;
    final g = _grid;
    final tc = ThemeController.instance;
    final scope = initialScope ??
        (current.hasCustomGrid ? DeckGridScope.thisPage : DeckGridScope.allPages);
    final result = await DeckLayoutSheet.show(
      context,
      profile: current,
      allProfiles: _ctl.profiles.value,
      initialRows: g.rows,
      initialColumns: g.columns,
      initialAutoGrid: false,
      autoRows: 3,
      autoColumns: 5,
      allowAutoGrid: false,
      initialSettings: tc.settings.value,
      initialScope: scope,
      initialPageGrid: current.customGrid,
    );
    if (result == null || !mounted) return;
    await tc.update(tc.settings.value.copyWith(
      spacing: result.spacing,
      iconSize: result.iconSize,
      showLabels: () => result.showLabels,
    ));
    if (result.scope == DeckGridScope.thisPage) {
      final ({int rows, int columns})? nextOverride =
          result.resetPageGrid ? null : (rows: result.rows, columns: result.columns);
      var updated = current.withCustomGrid(nextOverride);
      if (result.updatedButtons != null) {
        updated = updated.copyWith(
          buttons: List<DeckButton>.from(result.updatedButtons!),
        );
      }
      final err = await _ctl.updateProfileFull(
        updated,
        undoLabel: tr('Grade desta página'),
      );
      if (mounted) {
        _toast(err ?? tr('Salvo. O celular já mostra.'));
      }
      return;
    }
    if (result.rows != g.rows || result.columns != g.columns) {
      try {
        await Injector.get<DeckOSClient>().saveLayout(result.rows, result.columns);
        Injector.get<SignalRService>().deckLayout.value = {
          'rows': result.rows,
          'columns': result.columns,
        };
        if (mounted) _toast(tr('Salvo. O celular já mostra.'));
      } catch (_) {
        if (mounted) _toast(tr('O PC não respondeu. Confira se o DeckOS está aberto nele.'));
      }
    }
  }

  /// Põe um item da biblioteca na casa [at], na casa vazia escolhida, ou na primeira livre.
  Future<void> _addItem(LibraryItem item, {Slot? at}) async {
    final profile = _ctl.currentProfile.value;
    if (profile == null) return;
    final g = _gridFor(profile);
    var slot = at;
    if (slot == null && _selection.length == 1 && SlotOps.at(profile.buttons, _selection.first) == null) {
      slot = _selection.first;
    }
    slot ??= SlotOps.firstEmpty(profile.buttons, g.rows, g.columns);
    if (slot == null) {
      _toast(tr('Esta página está cheia. Crie outra página ou libere uma casa.'));
      return;
    }
    var it = item;
    if (it.app != null) {
      it = LibraryItem.fromApp(it.app!, pngIcon: await AppIconCache.pngForButton(it.app!));
    }
    final button = it.buildAt(slot);
    final current = _ctl.currentProfile.value ?? profile;
    final replaced = SlotOps.at(current.buttons, slot);
    await _ctl.commitButtons(
        SlotOps.place(current.buttons, button, slot), tr('Adicionar "{name}"', {'name': it.title}));
    if (!mounted) return;
    setState(() {
      _selection = {slot!};
      _anchor = slot;
      _editing = it.needsSetup ? button : null;
      _draft = null;
    });
    if (replaced != null) {
      _toast(tr('"{old}" foi trocado por "{name}".', {'old': replaced.label ?? '', 'name': it.title}), undo: _undo);
    }
  }

  Future<void> _removeSlots(Set<Slot> slots) async {
    final profile = _ctl.currentProfile.value;
    if (profile == null) return;
    final removing = profile.buttons.where((b) => slots.contains(slotOf(b))).length;
    if (removing == 0) return;
    await _ctl.commitButtons(SlotOps.remove(profile.buttons, slots),
        removing == 1 ? tr('Remover botão') : tr('Remover botões'));
    if (!mounted) return;
    setState(() {
      _selection = {};
      _closeInspector();
    });
    _toast(
      removing == 1 ? tr('Botão removido.') : tr('{n} botões removidos.', {'n': removing}),
      undo: _undo,
    );
  }

  /// Antes de trocar de botão ou de página: com mudanças não salvas, pergunta.
  Future<void> _guardDirty(VoidCallback proceed) async {
    if (_editing == null || _panelKey.currentState?.isDirty != true) {
      proceed();
      return;
    }
    final discard = await showAppleDialog<bool>(
      context: context,
      title: tr('Descartar as alterações?'),
      message: tr('O botão tem mudanças que ainda não foram salvas.'),
      actions: [
        AppleDialogAction(label: tr('Continuar editando'), value: false),
        AppleDialogAction(label: tr('Descartar'), value: true, isDestructive: true, isDefault: true),
      ],
    );
    if (discard == true) proceed();
  }

  void _selectPage(DeckProfile p) {
    if (p.id == _ctl.currentProfile.value?.id) return;
    _guardDirty(() {
      _ctl.switchProfile(p.id);
      _ctl.rememberProfile(p.id);
      setState(() {
        _selection = {};
        _closeInspector();
        _editingTitle = false;
      });
    });
  }

  // ---- Páginas ----

  Future<void> _newPage() async {
    final n = _ctl.profiles.value.length + 1;
    final p = await _ctl.createProfile(tr('Página {n}', {'n': n}));
    if (!mounted) return;
    setState(() {
      _selection = {};
      _closeInspector();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _sidebarKey.currentState?.startRename(p.id));
  }

  void _rename(DeckProfile p, String name) =>
      _ctl.updateProfileFull(p.copyWith(name: name), undoLabel: tr('Renomear página'));

  Future<void> _pageMenu(DeckProfile p, PageMenuAction action) async {
    switch (action) {
      case PageMenuAction.rename:
        _sidebarKey.currentState?.startRename(p.id);
      case PageMenuAction.pageGrid:
        await _openLayoutSheet(
          targetProfile: p,
          initialScope: DeckGridScope.thisPage,
        );
      case PageMenuAction.settings:
        ProfileSettingsDialog.show(
            context, p, (np) => _ctl.updateProfileFull(np, undoLabel: tr('Editar página')));
      case PageMenuAction.duplicate:
        await _ctl.duplicateProfile(p, tr('{name} (cópia)', {'name': p.name}));
        if (mounted) setState(() => _closeInspector());
      case PageMenuAction.share:
        ShareProfileDialog.show(context, p);
      case PageMenuAction.delete:
        final ok = await showAppleDialog<bool>(
          context: context,
          title: tr('Apagar "{name}"?', {'name': p.name}),
          message: tr('Os botões desta página somem do celular. Não dá para desfazer.'),
          actions: [
            AppleDialogAction(label: tr('Cancelar'), value: false),
            AppleDialogAction(label: tr('Apagar'), value: true, isDestructive: true, isDefault: true),
          ],
        );
        if (ok == true) {
          await _ctl.deleteProfile(p.id);
          if (mounted) {
            setState(() {
              _selection = {};
              _closeInspector();
            });
          }
        }
    }
  }

  void _commitTitle() {
    final p = _ctl.currentProfile.value;
    setState(() => _editingTitle = false);
    final name = _title.text.trim();
    if (p != null && name.isNotEmpty && name != p.name) _rename(p, name);
  }

  // ---- Paleta e rodapé ----

  Future<void> _openPalette() async {
    final picked = await showCommandPalette(
      context,
      paletteEntries(
        pages: _ctl.profiles.value,
        apps: _apps ?? const [],
        actions: ActionCatalog.instance.schemas.value,
        platform: _platform,
        colors: AppleColors.of(context),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.page != null) _selectPage(picked.page!);
    if (picked.item != null) await _addItem(picked.item!);
  }

  void _about() {
    final os = switch (_platform?.os) {
      'macos' => 'macOS',
      'windows' => 'Windows',
      'linux' => 'Linux',
      _ => null,
    };
    showAppleDialog<void>(
      context: context,
      title: 'DeckOS',
      message: [
        if (_version != null) tr('Versão {version}', {'version': _version!}),
        if (_pcName != null) _pcName!,
        if (_platform?.osVersion != null) _platform!.osVersion! else ?os,
      ].join('\n'),
      actions: [AppleDialogAction(label: tr('OK'), value: null, isDefault: true)],
    );
  }

  void _help() => launchUrl(Uri.parse('https://github.com/itskavin/DeckOS/issues'),
      mode: LaunchMode.externalApplication);

  List<({IconData icon, String label, VoidCallback onTap})> get _tools => [
        (
          icon: Icons.speed_rounded,
          label: tr('Limites de IA'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiLimitsSettingsPage())),
        ),
        (
          icon: Icons.hub_outlined,
          label: tr('Integrações'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const IntegrationsPage())),
        ),
        (
          icon: Icons.bolt_rounded,
          label: tr('Automações'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TriggersPage())),
        ),
        (
          icon: Icons.palette_outlined,
          label: tr('Aparência'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AppearanceSettingsPage())),
        ),
        (
          icon: Icons.archive_outlined,
          label: tr('Backup'),
          onTap: () => showAppleSheet<void>(
                context: context,
                title: tr('Backup'),
                builder: (_) => Padding(
                  padding: const EdgeInsets.only(bottom: AppleSpacing.lg),
                  child: BackupButtons(onImported: _ctl.loadProfiles),
                ),
              ),
        ),
      ];

  // ---- Interface ----

  @override
  Widget build(BuildContext context) {
    final profiles = _ctl.profiles.watch(context);
    final current = _ctl.currentProfile.watch(context);
    final isLoading = _ctl.isLoading.watch(context);
    final signalR = Injector.get<SignalRService>();
    signalR.deckLayout.watch(context);
    signalR.connectionStatus.watch(context);
    signalR.actionStates.watch(context);
    _ctl.history.version.watch(context);

    final c = AppleColors.of(context);
    if (isLoading && profiles.isEmpty) {
      return Scaffold(
        backgroundColor: c.groupedBackground,
        body: Center(
          child: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: c.secondaryLabel),
          ),
        ),
      );
    }
    // Página apagada ou trocada por fora: o botão do inspetor pode não existir mais.
    if (_editing != null && _editing!.id.isNotEmpty && current != null &&
        !current.buttons.any((b) => b.id == _editing!.id)) {
      _closeInspector();
    }

    final windowBg = c.groupedBackground;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: windowBg,
      drawer: Drawer(
        width: 290,
        backgroundColor: windowBg,
        child: SafeArea(child: Padding(padding: const EdgeInsets.all(AppleSpacing.xs), child: _sidebar(profiles, current))),
      ),
      body: LayoutBuilder(builder: (context, box) {
        final compact = box.maxWidth < SteamDeckDesktopLayout.compactWidth;
        final sideInspector = box.maxWidth >= SteamDeckDesktopLayout.sideInspectorWidth;
        final inspectorOpen = _editing != null || _selection.length > 1;
        final main = _main(profiles, current, box, compact: compact);
        return Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!compact)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppleSpacing.sm, AppleSpacing.sm, 0, AppleSpacing.sm),
                    child: SizedBox(width: 272, child: _sidebar(profiles, current)),
                  ),
                Expanded(child: main),
                if (inspectorOpen && sideInspector)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, AppleSpacing.sm, AppleSpacing.sm, AppleSpacing.sm),
                    child: SizedBox(width: 372, child: _inspector(profiles, overlay: false)),
                  ),
              ],
            ),
            if (inspectorOpen && !sideInspector)
              Positioned(
                top: AppleSpacing.sm,
                bottom: AppleSpacing.sm,
                right: AppleSpacing.sm,
                width: math.min(400, box.maxWidth - AppleSpacing.sm * 2),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppleRadii.lg),
                    boxShadow: AppleShadows.floating(Theme.of(context).brightness),
                  ),
                  child: _inspector(profiles, overlay: true),
                ),
              ),
          ],
        );
      }),
    );
  }

  Widget _sidebar(List<DeckProfile> profiles, DeckProfile? current) {
    final g = _grid;
    return DesktopSidebar(
      key: _sidebarKey,
      profiles: profiles,
      current: current,
      rows: g.rows,
      columns: g.columns,
      pcName: _pcName ?? _platform?.machineName,
      platform: _platform,
      connected: _connected,
      clients: _clientsState,
      version: _version ?? _platform?.version,
      onSelect: (p) {
        if (_scaffoldKey.currentState?.isDrawerOpen ?? false) Navigator.of(context).pop();
        _selectPage(p);
      },
      onRename: _rename,
      onMenu: _pageMenu,
      onReorder: _ctl.reorderProfiles,
      onNewPage: _newPage,
      onLayoutTap: current == null ? null : _openLayoutSheet,
      tools: _tools,
      onAbout: _about,
      onHelp: _help,
    );
  }

  Widget _main(List<DeckProfile> profiles, DeckProfile? current, BoxConstraints box, {required bool compact}) {
    final c = AppleColors.of(context);
    if (current == null) {
      return Center(
        child: EmptyState(
          icon: Icons.grid_view_rounded,
          title: tr('Nenhuma página'),
          message: tr('Crie uma página para começar a montar o deck.'),
          action: PrimaryButton(label: tr('Nova página'), icon: Icons.add_rounded, onPressed: _newPage),
        ),
      );
    }
    final g = _gridFor(current);
    final landscape = _isLandscapeFor(current);
    // Os pontinhos contam só as páginas de cima; numa pasta, nenhum fica aceso.
    final topPages = topLevelPages(profiles);
    final pageIndex = topPages.indexWhere((p) => p.id == current.id);
    final mirrorH = (box.maxHeight * (compact ? 0.36 : 0.40)).clamp(190.0, landscape ? 380.0 : 460.0);
    final draft = _draft;
    final showDraft = draft != null &&
        (draft.id.isNotEmpty && current.buttons.any((b) => b.id == draft.id) ||
            (draft.label?.isNotEmpty ?? false) ||
            draft.iconName != null ||
            draft.iconBase64 != null ||
            draft.action != null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(current, compact: compact),
        Container(
          height: 1,
          color: c.separator,
          margin: const EdgeInsets.symmetric(horizontal: AppleSpacing.xl),
        ),
        const SizedBox(height: AppleSpacing.lg),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.xl),
          child: DeckMirror(
            profile: current,
            rows: g.rows,
            columns: g.columns,
            landscape: landscape,
            selection: _selection,
            draft: showDraft ? draft : null,
            pageIndex: pageIndex,
            pageCount: topPages.length,
            onPageTap: (i) => _selectPage(topPages[i]),
            maxHeight: mirrorH,
            onSlotTap: _onSlotTap,
            onDrop: _onDrop,
            onDragOut: (d) => _removeSlots(d.group),
            onDragging: (v) => setState(() => _dragging = v),
          ),
        ),
        const SizedBox(height: AppleSpacing.sm),
        _caption(landscape),
        Expanded(
          child: LibraryPanel(
            platform: _platform,
            apps: _apps,
            appsLoading: _appsLoading,
            onAdd: (item) => _addItem(item),
          ),
        ),
      ],
    );
  }

  Widget _caption(bool landscape) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final clients = _clientsState;
    final phone = clients.primaryPhone;
    final Widget child;
    if (_dragging) {
      child = Row(
        key: const ValueKey('drag'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline_rounded, size: 14, color: c.red),
          const SizedBox(width: 6),
          Text(tr('Solte fora do celular para remover'), style: type.caption1.copyWith(color: c.red)),
        ],
      );
    } else if (!_connected) {
      child = Row(
        key: const ValueKey('offline'),
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: c.red, size: 6, glow: false),
          const SizedBox(width: 6),
          Text(
            tr('Servidor offline · prévia local'),
            style: type.caption1.copyWith(color: c.secondaryLabel),
          ),
        ],
      );
    } else if (phone != null) {
      child = Row(
        key: const ValueKey('live-phone'),
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: c.green, size: 6, glow: false),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              landscape
                  ? tr('Espelhando {device} · deitado', {'device': phone.displayName})
                  : tr('Espelhando {device} · em pé (os botões seguem a ordem de leitura)',
                      {'device': phone.displayName}),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.caption1.copyWith(color: c.secondaryLabel),
            ),
          ),
        ],
      );
    } else if (clients.known) {
      child = Row(
        key: const ValueKey('no-phone'),
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: c.orange, size: 6, glow: false),
          const SizedBox(width: 6),
          Text(
            landscape
                ? tr('Nenhum celular conectado · prévia deitada')
                : tr('Nenhum celular conectado · prévia em pé'),
            style: type.caption1.copyWith(color: c.secondaryLabel),
          ),
        ],
      );
    } else {
      child = Row(
        key: const ValueKey('preview'),
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: c.gray, size: 6, glow: false),
          const SizedBox(width: 6),
          Text(
            landscape
                ? tr('Prévia do deck · deitado')
                : tr('Prévia do deck · em pé (os botões seguem a ordem de leitura)'),
            style: type.caption1.copyWith(color: c.secondaryLabel),
          ),
        ],
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.xl),
        child: AnimatedSwitcher(duration: AppleMotion.of(context, AppleMotion.fast), child: child),
      ),
    );
  }

  Widget _header(DeckProfile current, {required bool compact}) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final h = _ctl.history;
    final mac = _platform?.isMac ?? (defaultTargetPlatform == TargetPlatform.macOS);
    final cmd = mac ? '⌘' : 'Ctrl+';
    final clients = _clientsState;
    final phone = clients.primaryPhone;

    Widget iconButton(IconData icon, String tip, VoidCallback? onTap) => IconButton(
          tooltip: tip,
          onPressed: onTap,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          padding: EdgeInsets.zero,
          icon: Icon(
            icon,
            size: 19,
            color: onTap == null ? c.quaternaryLabel : c.secondaryLabel,
          ),
        );

    final title = _editingTitle
        ? TextField(
            controller: _title,
            focusNode: _titleFocus,
            style: type.largeTitle.copyWith(color: c.label),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              filled: false,
              contentPadding: EdgeInsets.zero,
            ),
            onSubmitted: (_) => _commitTitle(),
          )
        : MouseRegion(
            cursor: SystemMouseCursors.text,
            child: GestureDetector(
              onTap: () {
                _title.text = current.name;
                _title.selection = TextSelection(baseOffset: 0, extentOffset: current.name.length);
                setState(() => _editingTitle = true);
                WidgetsBinding.instance.addPostFrameCallback((_) => _titleFocus.requestFocus());
              },
              child: Tooltip(
                message: tr('Clique para renomear'),
                waitDuration: const Duration(milliseconds: 800),
                child: Text(current.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: type.largeTitle.copyWith(color: c.label)),
              ),
            ),
          );

    final Widget statusPill;
    if (!_connected) {
      statusPill = LivePill(label: tr('Offline'), color: c.gray);
    } else if (phone != null) {
      statusPill = LivePill(label: tr('Ao vivo'), color: c.green);
    } else if (clients.known) {
      statusPill = LivePill(label: tr('Sem celular'), color: c.orange);
    } else {
      statusPill = LivePill(label: tr('Servidor ativo'), color: c.green);
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? AppleSpacing.sm : AppleSpacing.xl, AppleSpacing.lg, AppleSpacing.lg, AppleSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (compact)
            Padding(
              padding: const EdgeInsets.only(right: AppleSpacing.xs, top: 4),
              child: iconButton(Icons.menu_rounded, tr('Páginas'), () => _scaffoldKey.currentState?.openDrawer()),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const SizedBox(height: 2),
                Text(
                  tr('Clique numa casa vazia para adicionar · Arraste da biblioteca para uma casa'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: type.subheadline.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppleSpacing.sm),
          Padding(
            padding: const EdgeInsets.only(top: AppleSpacing.xxs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                iconButton(Icons.undo_rounded,
                    h.canUndo ? tr('Desfazer {action} ({key})', {'action': h.undoLabel!, 'key': '${cmd}Z'}) : tr('Desfazer'),
                    h.canUndo ? _undo : null),
                iconButton(
                    Icons.redo_rounded,
                    h.canRedo
                        ? tr('Refazer {action} ({key})', {'action': h.redoLabel!, 'key': mac ? '⇧⌘Z' : 'Ctrl+Shift+Z'})
                        : tr('Refazer'),
                    h.canRedo ? _redo : null),
                const SizedBox(width: AppleSpacing.xs),
                iconButton(
                  Icons.grid_view_rounded,
                  tr('Layout da grade'),
                  _openLayoutSheet,
                ),
                const SizedBox(width: AppleSpacing.xs),
                SegmentedControl<bool>(
                  segments: {
                    true: Tooltip(
                        message: tr('Deitado'),
                        child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.stay_current_landscape_rounded, size: 16))),
                    false: Tooltip(
                        message: tr('Em pé'),
                        child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.stay_current_portrait_rounded, size: 16))),
                  },
                  value: _isLandscapeFor(current),
                  onChanged: (v) => setState(() => _landscape = v),
                ),
                const SizedBox(width: AppleSpacing.xs),
                if (!compact)
                  iconButton(Icons.search_rounded, tr('Buscar ({key})', {'key': '${cmd}K'}), _openPalette),
                iconButton(
                  widget.isFullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                  widget.isFullscreen ? tr('Sair da tela cheia') : tr('Tela cheia'),
                  widget.onToggleFullscreen,
                ),
                const SizedBox(width: AppleSpacing.xs),
                statusPill,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _inspector(List<DeckProfile> profiles, {required bool overlay}) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final glass = c.secondaryGroupedBackground.withValues(alpha: overlay ? 1.0 : (c.isDark ? 0.96 : 0.98));
    if (_selection.length > 1 || _editing == null) {
      final n = _selection.length;
      return GlassPanel(
        radius: AppleRadii.lg,
        color: glass,
        padding: const EdgeInsets.all(AppleSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('{n} botões selecionados', {'n': n}), style: type.title3.copyWith(color: c.label)),
            const SizedBox(height: AppleSpacing.xs),
            Text(
              tr('Arraste um deles para mover o grupo. Delete remove todos.'),
              style: type.subheadline.copyWith(color: c.secondaryLabel),
            ),
            const SizedBox(height: AppleSpacing.lg),
            PrimaryButton(
              label: tr('Remover {n} botões', {'n': n}),
              icon: Icons.delete_outline_rounded,
              color: c.red,
              expand: true,
              onPressed: () => _removeSlots(_selection),
            ),
            const SizedBox(height: AppleSpacing.sm),
            SecondaryButton(
              label: tr('Limpar seleção'),
              expand: true,
              onPressed: () => setState(() => _selection = {}),
            ),
          ],
        ),
      );
    }
    final selected = _editing!;
    return GlassPanel(
      radius: AppleRadii.lg,
      color: glass,
      child: ButtonPropertyPanel(
        key: _keyFor(selected),
        button: selected,
        profiles: profiles,
        onDraftChanged: (b) {
          if (mounted) setState(() => _draft = b);
        },
        onSave: (btn) async {
          if (btn.id.isEmpty) {
            await _removeSlots({slotOf(selected)});
            return;
          }
          final refused = await _ctl.updateButton(btn,
              undoLabel: selected.id.isEmpty
                  ? tr('Adicionar "{name}"', {'name': btn.label ?? ''})
                  : tr('Editar "{name}"', {'name': btn.label ?? ''}));
          if (!mounted) return;
          if (refused != null) {
            _toast(refused);
            return;
          }
          setState(() {
            _editing = btn;
            _draft = null;
          });
          _toast(tr('Salvo. O celular já mostra.'));
        },
        onCancel: () => _guardDirty(() => setState(() {
              _selection = {};
              _closeInspector();
            })),
        onCopyOrMove: () {
          final g = _grid;
          copyOrMoveButton(context, controller: _ctl, button: selected, rows: g.rows, columns: g.columns);
        },
      ),
    );
  }
}
