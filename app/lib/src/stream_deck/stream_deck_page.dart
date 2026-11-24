import 'dart:async';
import 'dart:math' as math;

import 'package:deckos/src/config/pc_switcher.dart';
import 'package:deckos/src/pages/splash/deck_demo.dart' show kDeckDemo;
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/layout/desktop_layout.dart';
import 'package:deckos/src/stream_deck/layout/desktop_sidebar.dart' show topLevelPageOf, topLevelPages;
import 'package:deckos/src/stream_deck/layout/slot_ops.dart';
import 'package:deckos/src/studio/companion_surface_page.dart';
import 'package:deckos/src/studio/tally_page.dart';
import 'package:deckos/src/stream_deck/layout/grid_placement.dart';
import 'package:deckos/src/stream_deck/widgets/connection_chip.dart';
import 'package:deckos/src/stream_deck/widgets/deck_layout_sheet.dart';
import 'package:deckos/src/stream_deck/actions/action_catalog.dart';
import 'package:deckos/src/stream_deck/deck_preloader.dart';
import 'package:deckos/src/stream_deck/stream_deck_controller.dart';
import 'package:deckos/src/ai_limits/ai_limits_settings_page.dart';
import 'package:deckos/src/ai_limits/ai_limits_tile.dart';
import 'package:deckos/src/ai_limits/ai_provider_style.dart';
import 'package:deckos/src/stream_deck/widgets/ai_limits_demo_tile.dart';
import 'package:deckos/src/stream_deck/widgets/dynamic_deck_button.dart';
import 'package:deckos/src/stream_deck/widgets/button_editor_dialog.dart';
import 'package:deckos/src/stream_deck/widgets/copy_move_dialog.dart';
import 'package:deckos/src/stream_deck/widgets/profile_settings_dialog.dart';
import 'package:deckos/core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show DeviceGestureSettings, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter/services.dart';
import 'package:collection/collection.dart';

/// Minimum touch slop (dp) for deck tiles and page swiping.
/// Keeps small fingertip drift within Flutter's standard tolerance even when the
/// platform supplies a smaller value. Real contact pressure is not measured here.
const double kDeckTouchSlop = kTouchSlop;

/// O deck no celular: foco total nas teclas. Arrastar para o lado troca de perfil; os
/// controles (barra superior, faixa inferior e abas) recolhem sozinhos após 5 s sem
/// interação e voltam ao tocar numa área livre, puxar do topo ou usar o teclado. No
/// configurador do PC vira o editor de três painéis.
class StreamDeckPage extends StatefulWidget {
  final VoidCallback onToggleFullscreen;
  final bool isFullscreen;
  final ValueChanged<bool>? onChromeVisibilityChanged;

  /// Altura da barra inferior de abas (retrato) para o rodapé do deck não sobrepô-la.
  final double bottomNavInset;

  /// Largura da faixa lateral de abas (deitado), já com a margem segura da esquerda:
  /// a barra do topo e o LED da conexão começam depois dela, não por baixo.
  final double leftNavInset;

  /// Tempo de inatividade para esconder todos os controles não essenciais.
  final Duration chromeTimeout;

  const StreamDeckPage({
    super.key,
    required this.onToggleFullscreen,
    required this.isFullscreen,
    this.onChromeVisibilityChanged,
    this.bottomNavInset = 0,
    this.leftNavInset = 0,
    this.chromeTimeout = const Duration(seconds: 5),
  });

  @override
  State<StreamDeckPage> createState() => _StreamDeckPageState();
}

enum _DeckOverflowAction { profile, fullscreen }

class _StreamDeckPageState extends State<StreamDeckPage> {
  final StreamDeckController controller = StreamDeckController();
  late PageController _pageController;
  void Function()? _deckSyncCleanup;
  final List<String> _navStack = []; // pilha de pastas (perfis) abertas
  DeckProfile? _rootProfile; // perfil-raiz antes de entrar em pastas
  int? _reportedCols; // última grade reportada ao PC (evita reenvio)
  int? _reportedRows;

  /// Grade desenhada agora (para achar casa livre ao copiar um botão).
  DeckGridFit? _grid;

  /// Deck no navegador: usa a grade do celular (guardada no PC) em vez de calcular a
  /// própria — senão o navegador e o celular brigariam pela grade.
  Map<String, int>? _sharedGrid;

  /// Modo de edição de layout: arrastar move/troca e tocar edita, sem disparar ações.
  /// As mudanças ficam num rascunho local até tocar em Salvar; Cancelar descarta tudo.
  bool _editMode = false;
  String? _editProfileId;
  List<DeckButton>? _editDraft;
  final List<List<DeckButton>> _editUndo = [];
  bool _editDirty = false;
  bool _savingEdit = false;
  bool _pendingProfileReload = false;

  /// Último layout compartilhado vindo do PC (para sincronizar celular e configurador).
  void Function()? _layoutSyncCleanup;
  ({int rows, int columns})? _lastSeenServerLayout;

  /// Grades enviadas por este próprio aparelho cujo eco do SignalR ainda pode chegar.
  final List<({int rows, int columns})> _pendingSentLayouts = [];

  /// Perfil em que o usuário estava antes de o app em foco trocar de perfil sozinho.
  String? _profileBeforeAuto;

  /// Página mudando por código (não pelo dedo).
  bool _jumping = false;

  /// Controles não essenciais (topo, rodapé e abas) à mostra. Somem sozinhos após
  /// [StreamDeckPage.chromeTimeout] sem interação.
  bool _chrome = kDeckDemo ? Uri.base.queryParameters['chrome'] == '1' : true;
  Timer? _chromeTimer;
  int _chromePauseCount = 0;
  bool _draggingTile = false;

  bool get _chromePaused => _editMode || _draggingTile || _chromePauseCount > 0;

  /// Aviso de "PC desconectado" fechado pelo usuário (volta se o erro mudar).
  String? _dismissedError;

  /// Último aviso de troca automática já aplicado ('' = nenhum ainda).
  String? _appliedAuto = '';
  void Function()? _autoProfileCleanup;
  void Function()? _reconnectCleanup;
  void Function()? _pageSyncCleanup;
  void Function()? _preloadCleanup;

  void _schedulePrewarm({bool network = true}) {
    if (WebMode.configurator) return;
    final list = controller.profiles.value;
    if (list.isEmpty) return;
    final current = _activeProfile(list);
    void run() {
      if (!mounted) return;
      DeckPreloader.instance.prewarm(
        profiles: list,
        current: current,
        network: network && !controller.offline.value,
      );
    }

    if (WidgetsBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      Future<void>.microtask(run);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => run());
    }
  }

  @override
  void initState() {
    super.initState();
    controller.loadProfiles();
    _loadSharedGrid();
    // Catálogo de ações: ícones padrão e estados ao vivo (timers, Windows).
    ActionCatalog.instance.load();
    loadPcName();

    // Sync ao vivo: recarrega os perfis quando o backend avisa que o deck mudou
    // (ex.: alguém editou no configurador web do PC).
    final signalR = Injector.get<SignalRService>();
    var lastSeen = signalR.deckUpdated.value;
    _deckSyncCleanup = effect(() {
      final v = signalR.deckUpdated.value;
      if (v != lastSeen) {
        lastSeen = v;
        if (_editMode) {
          _pendingProfileReload = true;
        } else {
          controller.loadProfiles();
        }
        if (WebMode.deck) _loadSharedGrid();
      }
    });

    // Grade compartilhada mudou ao vivo (ex.: ajustada no configurador do PC).
    final initialLay = signalR.deckLayout.value;
    _lastSeenServerLayout = (
      rows: initialLay['rows'] ?? 3,
      columns: initialLay['columns'] ?? 5,
    );
    _layoutSyncCleanup = effect(() {
      final lay = signalR.deckLayout.value;
      final r = lay['rows'], c = lay['columns'];
      if (r == null || c == null || r < 1 || c < 1) return;
      final incoming = (rows: r, columns: c);
      if (incoming == _lastSeenServerLayout) return;
      _lastSeenServerLayout = incoming;
      untracked(() {
        if (WebMode.deck) {
          if (mounted) setState(() => _sharedGrid = {'rows': r, 'columns': c});
        } else if (!kIsWeb) {
          // Ignora ecos das grades que este próprio aparelho acabou de enviar.
          final echoIdx = _pendingSentLayouts.indexOf(incoming);
          if (echoIdx != -1) {
            _pendingSentLayouts.removeAt(echoIdx);
            return;
          }
          if (_reportedRows == r && _reportedCols == c) return;
          _reportedRows = r;
          _reportedCols = c;
          ThemeController.instance.setCustomGrid(incoming);
        }
      });
    });

    final initialTop = topLevelPages(controller.profiles.value);
    final initialCur = controller.currentProfile.value;
    final initialPageIdx = initialCur == null
        ? 0
        : math.max(
            0,
            initialTop.indexWhere((p) =>
                p.id == (topLevelPageOf(controller.profiles.value, initialCur)?.id ?? initialCur.id)),
          );
    _pageController = PageController(initialPage: initialPageIdx);

    // Pré-carregamento limitado e não-bloqueante de dados/ícones das páginas após o 1º quadro.
    _preloadCleanup = effect(() {
      final list = controller.profiles.value;
      final offline = controller.offline.value;
      controller.currentProfile.value;
      if (list.isEmpty) return;
      untracked(() => _schedulePrewarm(network: !offline));
    });

    // A página acompanha o perfil atual quando ele muda por fora do arrastar (último
    // perfil aberto, troca automática pelo app em foco).
    _pageSyncCleanup = effect(() {
      final current = controller.currentProfile.value;
      final list = controller.profiles.value;
      if (current == null) return;
      // O deck desliza só as páginas de cima: uma pasta fica na página que a abre.
      final top = topLevelPages(list);
      final index = top.indexWhere((p) => p.id == (topLevelPageOf(list, current)?.id ?? current.id));
      untracked(() => _jumpToPage(index));
    });

    // Troca automática: o PC avisa qual perfil pertence ao app em foco. Também roda
    // quando os perfis chegam (o aviso pode vir antes), mas cada aviso só é aplicado
    // uma vez: recarregar o deck não puxa o usuário de volta.
    _autoProfileCleanup = effect(() {
      final auto = signalR.autoProfile.value;
      final enabled = ThemeController.instance.autoProfile.value;
      controller.profiles.value;
      if (!enabled || WebMode.configurator || _editMode || auto.isEmpty) return;
      final id = auto['profileId'] as String?;
      if (id == _appliedAuto) return;
      untracked(() {
        if (_applyAutoProfile(id)) _appliedAuto = id;
      });
    });

    // Reconectou (PC reiniciado, Wi-Fi voltou): o deck pode ter mudado enquanto a
    // conexão estava fora, e os avisos de mudança se perderam. Recarrega (evitando
    // repetir o carregamento inicial se o hub conectou logo após initState já ter lido).
    var wasConnected = signalR.connectionStatus.value == 'Connected';
    var sawDisconnect = false;
    _reconnectCleanup = effect(() {
      final connected = signalR.connectionStatus.value == 'Connected';
      if (!connected && wasConnected) {
        sawDisconnect = true;
      } else if (connected && !wasConnected) {
        final needsReload = sawDisconnect || controller.offline.value || !controller.hasLiveProfiles;
        sawDisconnect = false;
        untracked(() {
          if (needsReload) {
            if (!_editMode || !_editDirty) controller.loadProfiles();
            _loadSharedGrid();
          }
          _schedulePrewarm(network: true);
        });
      }
      wasConnected = connected;
    });

    if (_chrome && !kDeckDemo) {
      _scheduleChromeHide();
    }
  }

  Future<void> _loadSharedGrid() async {
    final grid = await Injector.get<DeckOSClient>().getLayout();
    if (grid == null || !mounted) return;
    final r = grid['rows'], c = grid['columns'];
    if (r == null || c == null || r < 1 || c < 1) return;
    if (WebMode.deck) {
      setState(() => _sharedGrid = grid);
      return;
    }
    if (!kIsWeb) {
      final tc = ThemeController.instance;
      final incoming = (rows: r, columns: c);
      _lastSeenServerLayout = incoming;
      // Se o PC tem uma grade diferente da última que este celular enviou, alguém
      // ajustou no configurador do PC (ou em outro aparelho): adota para manter em sincronia.
      final custom = tc.customGrid.value;
      final lastRep = tc.lastReportedGrid;
      if (custom != null && custom != incoming) {
        await tc.setCustomGrid(incoming);
      } else if (custom == null && lastRep != null && lastRep != incoming) {
        await tc.setCustomGrid(incoming);
      }
      _reportedRows = r;
      _reportedCols = c;
    }
  }

  void _jumpToPage(int index) {
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      if (_pageController.page?.round() != index) {
        // O jumpToPage dispara onPageChanged: marcado para não parecer um arrastar.
        _jumping = true;
        _pageController.jumpToPage(index);
        _jumping = false;
      }
    });
  }

  /// Toque num pontinho: desliza até a página com a mola (ou pula, sem animações).
  void _goToPage(int index) {
    if (!_pageController.hasClients) return;
    final d = AppleMotion.of(context, const Duration(milliseconds: 480));
    if (d == Duration.zero) {
      _pageController.jumpToPage(index);
    } else {
      _pageController.animateToPage(index, duration: d, curve: AppleMotion.smooth);
    }
  }

  /// Aplica um aviso de troca automática. False se os perfis ainda não chegaram.
  bool _applyAutoProfile(String? profileId) {
    final list = controller.profiles.value;
    if (list.isEmpty) return false;
    if (profileId != null) {
      final target = list.where((p) => p.id == profileId).firstOrNull;
      if (target == null) return true;
      final current = controller.currentProfile.value;
      if (current?.id == target.id && _navStack.isEmpty) return true;
      // Guarda para onde voltar só na primeira troca automática da sequência.
      _profileBeforeAuto ??= current?.id;
      setState(() {
        _navStack.clear();
        _rootProfile = null;
      });
      controller.currentProfile.value = target;
      return true;
    } else if (_profileBeforeAuto != null) {
      final back = list.where((p) => p.id == _profileBeforeAuto).firstOrNull;
      _profileBeforeAuto = null;
      if (back != null) {
        setState(() {
          _navStack.clear();
          _rootProfile = null;
        });
        controller.currentProfile.value = back;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _chromeTimer?.cancel();
    _layoutSyncCleanup?.call();
    _preloadCleanup?.call();
    _pageSyncCleanup?.call();
    _autoProfileCleanup?.call();
    _reconnectCleanup?.call();
    _deckSyncCleanup?.call();
    _pageController.dispose();
    super.dispose();
  }

  // ---- Controles flutuantes (5 s de inatividade) e modo de edição ----

  void _scheduleChromeHide() {
    _chromeTimer?.cancel();
    if (!_chrome || _chromePaused) return;
    _chromeTimer = Timer(widget.chromeTimeout, _autoHideChrome);
  }

  void _autoHideChrome() {
    if (!mounted) return;
    if (_chromePaused || ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _showChrome(false);
  }

  void _showChrome([bool show = true]) {
    _chromeTimer?.cancel();
    if (!show && _chromePaused) return;
    final changed = _chrome != show;
    if (changed) {
      setState(() => _chrome = show);
      widget.onChromeVisibilityChanged?.call(show);
    }
    if (show && !_chromePaused) {
      _scheduleChromeHide();
    }
  }

  /// Interação legítima enquanto os controles estão visíveis reinicia o contador de 5 s.
  void _touchChrome() {
    if (_chrome && !_chromePaused) _scheduleChromeHide();
  }

  void _pauseChrome() {
    _chromePauseCount++;
    _chromeTimer?.cancel();
  }

  void _resumeChrome() {
    if (_chromePauseCount > 0) _chromePauseCount--;
    if (_chrome && !_chromePaused) _scheduleChromeHide();
  }

  Future<T> _withChromePaused<T>(Future<T> Function() action) async {
    _pauseChrome();
    try {
      return await action();
    } finally {
      if (mounted) _resumeChrome();
    }
  }

  /// Toque em área livre (fundo, margens, vãos ou casa vazia): revela os controles
  /// escondidos ou recolhe imediatamente se já estiverem abertos fora da edição.
  void _handleUnusedAreaTap() {
    if (_editMode) return;
    _showChrome(!_chrome);
  }

  /// Perfil que está na tela agora (pasta aberta, se houver, senão a página atual).
  DeckProfile? _activeProfile(List<DeckProfile> profiles) =>
      _folderProfile(profiles) ?? controller.currentProfile.value;

  void _enterEditMode() {
    final profile = _activeProfile(controller.profiles.value);
    if (profile == null) return;
    setState(() {
      _editMode = true;
      _editProfileId = profile.id;
      _editDraft = List<DeckButton>.from(profile.buttons);
      _editUndo.clear();
      _editDirty = false;
    });
    _showChrome(true);
  }

  void _cancelEditMode() {
    final reload = _pendingProfileReload;
    setState(() {
      _editMode = false;
      _editProfileId = null;
      _editDraft = null;
      _editUndo.clear();
      _editDirty = false;
      _pendingProfileReload = false;
      _draggingTile = false;
    });
    // Sai da edição mantendo os controles visíveis pelo ciclo normal de 5 s.
    _showChrome(true);
    if (reload) controller.loadProfiles();
  }

  Future<void> _confirmCancelEditMode() async {
    if (!_editMode) return;
    if (!_editDirty) {
      _cancelEditMode();
      return;
    }
    final discard = await _withChromePaused(
      () => showAppleDialog<bool>(
        context: context,
        title: tr('Descartar alterações do layout?'),
        message: tr('Os botões voltam para a posição anterior. Nada foi salvo.'),
        actions: [
          AppleDialogAction(label: tr('Continuar editando'), value: false),
          AppleDialogAction(
            label: tr('Descartar'),
            value: true,
            isDestructive: true,
            isDefault: true,
          ),
        ],
      ),
    );
    if (discard == true && mounted) _cancelEditMode();
  }

  Future<void> _saveEditMode() async {
    if (!_editMode || _savingEdit) return;
    final profiles = controller.profiles.value;
    final target = profiles.firstWhereOrNull((p) => p.id == _editProfileId) ??
        _activeProfile(profiles);
    if (target == null || !_editDirty || _editDraft == null) {
      _cancelEditMode();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _savingEdit = true);
    final error = await controller.updateProfileFull(
      target.copyWith(buttons: List<DeckButton>.from(_editDraft!)),
      undoLabel: tr('Organizar layout'),
    );
    if (!mounted) return;
    setState(() => _savingEdit = false);
    if (error != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(error),
          duration: const Duration(seconds: 5),
        ));
      return;
    }
    _cancelEditMode();
  }

  void _undoEditStep() {
    if (!_editMode || _editUndo.isEmpty) return;
    ThemeController.instance.tapFeedback();
    setState(() {
      _editDraft = _editUndo.removeLast();
      _editDirty = _editUndo.isNotEmpty;
    });
  }

  void _applyDraftMove(DeckButton dragged, int toRow, int toCol, DeckGridFit g) {
    final current = _editDraft;
    if (current == null) return;
    final next = SlotOps.moveSafely(
      current,
      slotOf(dragged),
      (row: toRow, column: toCol),
      rows: g.rows,
      columns: g.cols,
    );
    if (next == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(tr('Não cabe ali sem sobrepor outro botão.')),
          duration: const Duration(seconds: 3),
        ));
      return;
    }
    ThemeController.instance.tapFeedback();
    setState(() {
      _editUndo.add(List<DeckButton>.from(current));
      _editDraft = next;
      _editDirty = true;
    });
  }

  Future<void> _openLayoutSheet() async {
    final profiles = controller.profiles.value;
    final active = _activeProfile(profiles);
    if (active == null) return;
    final tc = ThemeController.instance;
    final screen = MediaQuery.sizeOf(context);
    final currentGrid = _grid;
    final autoFit = DeckGridFit.compute(
      area: currentGrid?.area ?? screen,
      screen: screen,
      spacing: tc.settings.value.spacing,
      allowReflow: false,
    );
    // Se estamos editando, a prévia usa o rascunho atual para refletir posições novas.
    final previewProfile = (_editMode && _editProfileId == active.id && _editDraft != null)
        ? active.copyWith(buttons: _editDraft!)
        : active;
    final custom = tc.customGrid.value;
    final initialRows = custom?.rows ?? _sharedGrid?['rows'] ?? currentGrid?.deckRows ?? autoFit.deckRows;
    final initialCols = custom?.columns ?? _sharedGrid?['columns'] ?? currentGrid?.deckCols ?? autoFit.deckCols;

    final result = await _withChromePaused(
      () => DeckLayoutSheet.show(
        context,
        profile: previewProfile,
        allProfiles: profiles,
        initialRows: initialRows,
        initialColumns: initialCols,
        initialAutoGrid: !kIsWeb && custom == null,
        autoRows: autoFit.deckRows,
        autoColumns: autoFit.deckCols,
        allowAutoGrid: !kIsWeb,
        initialSettings: tc.settings.value,
      ),
    );
    if (result == null || !mounted) return;

    // 1. Preferências deste aparelho (espaçamento, tamanho dos ícones e nomes).
    await tc.update(tc.settings.value.copyWith(
      spacing: result.spacing,
      iconSize: result.iconSize,
      showLabels: () => result.showLabels,
    ));

    // 2. Grade compartilhada (PC + outros aparelhos).
    if (result.autoGrid && !kIsWeb) {
      final naturalRows = autoFit.deckRows;
      final naturalCols = autoFit.deckCols;
      await tc.setCustomGrid(null);
      _reportedRows = naturalRows;
      _reportedCols = naturalCols;
      _lastSeenServerLayout = (rows: naturalRows, columns: naturalCols);
      _rememberSentLayout(naturalRows, naturalCols);
      await tc.recordReportedGrid(naturalRows, naturalCols);
      try {
        await Injector.get<DeckOSClient>().saveLayout(naturalRows, naturalCols);
        Injector.get<SignalRService>().deckLayout.value = {
          'rows': naturalRows,
          'columns': naturalCols,
        };
      } catch (_) {}
    } else {
      if (!kIsWeb) {
        await tc.setCustomGrid((rows: result.rows, columns: result.columns));
      } else {
        setState(() => _sharedGrid = {'rows': result.rows, 'columns': result.columns});
      }
      _reportedRows = result.rows;
      _reportedCols = result.columns;
      _lastSeenServerLayout = (rows: result.rows, columns: result.columns);
      _rememberSentLayout(result.rows, result.columns);
      try {
        await Injector.get<DeckOSClient>().saveLayout(result.rows, result.columns);
        Injector.get<SignalRService>().deckLayout.value = {
          'rows': result.rows,
          'columns': result.columns,
        };
      } catch (_) {}
    }
  }

  DeckProfile? _folderProfile(List<DeckProfile> profiles) {
    if (_navStack.isEmpty) return null;
    return profiles.firstWhereOrNull((p) => p.id == _navStack.last);
  }

  /// Trata um gesto: abre pasta (open_profile), volta (back) ou executa a ação.
  void _handlePress(
    DeckButton b,
    List<DeckProfile> profiles, {
    String gesture = 'tap',
  }) {
    // Cartão da página "AI Limits Demo": toque abre a folha com detalhes ilustrativos.
    if (gesture == 'tap' &&
        b.dynamicType == aiLimitsDemoDynamicType &&
        b.action == null &&
        !b.toggle) {
      _withChromePaused(() => showAiLimitsDemoSheet(context, b));
      return;
    }
    // Cartão real de Limites de IA: toque abre detalhes/janelas/configuração sem disparar /press.
    if (gesture == 'tap' &&
        b.dynamicType == aiLimitsDynamicType &&
        b.action == null &&
        !b.toggle) {
      _withChromePaused(
        () => showAiLimitsDetailSheet(
          context,
          b,
          onEditTile: () => _editButton(b),
          onSettingsClosed: () => controller.loadProfiles(),
        ),
      );
      return;
    }
    // Botão de monitor ou de informação sem ação: só mostra, o toque não faz nada.
    if (gesture == 'tap' &&
        (b.dynamicType?.isNotEmpty ?? false) &&
        b.action == null &&
        !b.toggle) {
      return;
    }
    final action = b.actionFor(gesture);
    final type = action?.type;
    if (type == 'open_profile') {
      final targetId = action!.parameters['profileId'];
      final target = profiles.firstWhereOrNull((p) => p.id == targetId);
      if (target != null) {
        setState(() {
          _rootProfile ??= controller.currentProfile.value;
          _navStack.add(target.id);
          controller.currentProfile.value = target;
        });
      }
      return;
    }
    if (type == 'back') {
      _goBack(profiles);
      return;
    }
    // Telas do estúdio abrem aqui mesmo: quem sabe mostrar é o app.
    if (type == 'companion') {
      _withChromePaused(
        () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CompanionSurfacePage()),
        ),
      );
      return;
    }
    if (type == 'tally') {
      final op = action!.parameters['operation'] ?? 'open';
      if (op == 'open') {
        _withChromePaused(
          () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TallyPage(target: action.parameters['target']),
            ),
          ),
        );
        return;
      }
      // Só mostrar: o sinal manual muda no toque, os outros alvos só se observam.
      if (op == 'show' && action.parameters['target'] != tallyManualTarget) return;
    }
    // Dois estados vai ao PC mesmo sem ação: o toque alterna o estado lá.
    if (action == null && !(gesture == 'tap' && b.toggle)) return;
    final messenger = ScaffoldMessenger.of(context);
    if (controller.offline.value) {
      _offlineNotice(messenger);
      return;
    }
    final diagStart = kDebugMode && kDeckTouchDiagnosticsEnabled ? DateTime.now() : null;
    String? failureMessage;
    controller.executeButtonAction(b, gesture: gesture, onFailure: (message) => failureMessage = message).then((ok) {
      if (diagStart != null) {
        final ms = DateTime.now().difference(diagStart).inMilliseconds;
        debugPrint(
          '[DeckTouchDiag] dispatch gesture=$gesture type=${type ?? (b.toggle ? 'toggle' : 'none')} ok=$ok elapsedMs=$ms',
        );
      }
      if (!ok) _offlineNotice(messenger, message: failureMessage);
    });
  }

  void _offlineNotice(ScaffoldMessengerState messenger, {String? message}) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            message ?? tr('O PC não respondeu. Confira se o DeckOS está aberto nele.'),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  void _goBack(List<DeckProfile> profiles) {
    setState(() {
      if (_navStack.isNotEmpty) _navStack.removeLast();
      if (_navStack.isEmpty) {
        controller.currentProfile.value =
            _rootProfile ?? controller.currentProfile.value;
        _rootProfile = null;
      } else {
        final p = profiles.firstWhereOrNull((p) => p.id == _navStack.last);
        if (p != null) controller.currentProfile.value = p;
      }
    });
  }

  Future<void> _editButton(DeckButton button) async {
    // O diálogo já fechou quando a resposta do PC chega: o aviso usa o messenger da
    // página, não o context do diálogo.
    final messenger = ScaffoldMessenger.of(context);
    await _withChromePaused(
      () => showDialog(
        context: context,
        builder: (context) => ButtonEditorDialog(
          button: button,
          onCopyOrMove: button.id.isEmpty || _editMode
              ? null
              : () {
                  Navigator.of(context).pop();
                  _copyOrMove(button);
                },
          onSave: (b) async {
            // No modo de edição, a alteração entra no rascunho (permite Desfazer/Cancelar).
            if (_editMode && _editDraft != null) {
              final current = List<DeckButton>.from(_editDraft!);
              final next = List<DeckButton>.from(current);
              final index = next.indexWhere(
                (x) =>
                    (button.id.isNotEmpty && x.id == button.id) ||
                    (x.row == b.row && x.column == b.column),
              );
              if (index != -1) {
                if (b.id.isEmpty) {
                  next.removeAt(index);
                } else {
                  next[index] = b;
                }
              } else if (b.id.isNotEmpty) {
                next.add(b);
              }
              if (mounted) {
                setState(() {
                  _editUndo.add(current);
                  _editDraft = next;
                  _editDirty = true;
                });
              }
              return;
            }
            final refused = await controller.updateButton(b);
            // "Limpar botão" apaga na hora, mas dá para desfazer.
            if (refused == null && b.id.isEmpty && button.id.isNotEmpty) {
              messenger.showSnackBar(SnackBar(
                content: Text(tr('Botão removido.')),
                duration: const Duration(seconds: 6),
                // Com ação, o Flutter deixa o aviso na tela até alguém fechar; este some sozinho.
                persist: false,
                action: SnackBarAction(
                  label: tr('Desfazer'),
                  onPressed: () => controller.updateButton(button),
                ),
              ));
              return;
            }
            if (refused != null) {
              messenger.showSnackBar(
                SnackBar(
                  content: Text(refused),
                  duration: const Duration(seconds: 6),
                ),
              );
            }
          },
        ),
      ),
    );
  }

  /// A grade de quem define o deck (o celular), mesmo copiando pelo navegador.
  Future<void> _copyOrMove(DeckButton button) async {
    final shared = _sharedGrid;
    final profile = controller.currentProfile.value;
    await _withChromePaused(
      () => copyOrMoveButton(
        context,
        controller: controller,
        button: button,
        rows: shared?['rows'] ?? _grid?.deckRows ?? profile?.rows ?? 3,
        columns: shared?['columns'] ?? _grid?.deckCols ?? profile?.columns ?? 5,
      ),
    );
  }

  void _rememberSentLayout(int rows, int columns) {
    _pendingSentLayouts.add((rows: rows, columns: columns));
    if (_pendingSentLayouts.length > 6) {
      _pendingSentLayouts.removeAt(0);
    }
  }

  /// O celular reporta ao PC a grade automática natural da tela quando está no modo
  /// Automático (sem inflar com páginas maiores como o teclado). Com grade manual escolhida
  /// pelo usuário (ou pelo PC), nunca sobrescreve.
  void _maybeReportLayout(DeckGridFit naturalAutoFit) {
    if (kIsWeb) return;
    if (ThemeController.instance.customGrid.value != null) return;
    if (_reportedCols == naturalAutoFit.deckCols && _reportedRows == naturalAutoFit.deckRows) return;
    _reportedCols = naturalAutoFit.deckCols;
    _reportedRows = naturalAutoFit.deckRows;
    _lastSeenServerLayout = (rows: naturalAutoFit.deckRows, columns: naturalAutoFit.deckCols);
    _rememberSentLayout(naturalAutoFit.deckRows, naturalAutoFit.deckCols);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ThemeController.instance.recordReportedGrid(naturalAutoFit.deckRows, naturalAutoFit.deckCols);
      try {
        Injector.get<DeckOSClient>().saveLayout(naturalAutoFit.deckRows, naturalAutoFit.deckCols);
      } catch (_) {}
    });
  }

  /// Grade cols×rows, centralizada. Botões grandes ocupam várias casas. Com o celular em
  /// pé (ou num navegador pequeno) os botões são reorganizados em ordem de leitura na
  /// grade que cabe, com rolagem se passarem da tela.
  Widget _buildButtonGrid(
    DeckProfile profile,
    List<DeckProfile> profiles,
    DeckGridFit g,
  ) {
    final editingThis = _editMode && _editProfileId == profile.id && _editDraft != null;
    final sourceButtons = editingThis ? _editDraft! : profile.buttons;
    final reflow = g.reflow;
    final buttons = reflow ? reflowButtons(sourceButtons, g.cols) : sourceButtons;
    // Na grade reorganizada a posição não é a salva: editar usa o botão original.
    final original = {for (final b in sourceButtons) b.id: b};
    var rows = g.rows;
    if (reflow) {
      for (final b in buttons) {
        if (b.row + b.rowSpan > rows) rows = b.row + b.rowSpan;
      }
    }
    final layout = GridLayout.of(buttons, rows, g.cols);
    // Fora do modo de edição as casas vazias não aparecem: centraliza só a área ocupada
    // (um deck de 5 botões numa grade de 10 colunas não fica colado à esquerda).
    var usedCols = g.cols, usedRows = rows;
    if (!editingThis && layout.placements.isNotEmpty) {
      usedCols = 0;
      usedRows = 0;
      for (final p in layout.placements) {
        if (p.column + p.columnSpan > usedCols) usedCols = p.column + p.columnSpan;
        if (p.row + p.rowSpan > usedRows) usedRows = p.row + p.rowSpan;
      }
    }
    final cell = reflow ? g.cellFor(usedRows) : g.cell;
    final step = cell + g.spacing;
    double size(int span) => span * cell + (span - 1) * g.spacing;
    final scrolls = size(usedRows) > g.area.height + 0.5;
    final grid = SizedBox(
      width: size(usedCols),
      height: size(usedRows),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Casas vazias: só no modo de edição (ou num deck vazio) e nunca na grade
          // reorganizada, onde a casa não corresponde a uma posição salva.
          if (!reflow)
            for (var row = 0; row < rows; row++)
              for (var col = 0; col < g.cols; col++)
                if (layout.isFree(row, col))
                  Positioned(
                    left: col * step,
                    top: row * step,
                    width: cell,
                    height: cell,
                    child: _buildCell(
                      row,
                      col,
                      null,
                      profiles,
                      grid: g,
                      draftButtons: sourceButtons,
                      showEmpty: editingThis || sourceButtons.isEmpty,
                      movable: editingThis,
                      scrolls: scrolls,
                      tileWidth: cell,
                      tileHeight: cell,
                    ),
                  ),
          for (final p in layout.placements)
            Positioned(
              key: p.button.id.isNotEmpty ? ValueKey('deck-btn-${p.button.id}') : null,
              left: p.column * step,
              top: p.row * step,
              width: size(p.columnSpan),
              height: size(p.rowSpan),
              child: _buildCell(
                p.row,
                p.column,
                original[p.button.id] ?? p.button,
                profiles,
                grid: g,
                draftButtons: sourceButtons,
                movable: editingThis && !reflow,
                scrolls: scrolls,
                tileWidth: size(p.columnSpan),
                tileHeight: size(p.rowSpan),
              ),
            ),
        ],
      ),
    );
    if (!scrolls) return Center(child: grid);
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(vertical: g.spacing),
      child: Center(child: grid),
    );
  }

  Widget _buildCell(
    int row,
    int col,
    DeckButton? existing,
    List<DeckProfile> profiles, {
    required DeckGridFit grid,
    required List<DeckButton> draftButtons,
    bool showEmpty = true,
    bool movable = false,
    bool scrolls = false,
    required double tileWidth,
    required double tileHeight,
  }) {
    final cell = _buildCellContent(row, col, existing, profiles, showEmpty: showEmpty);
    return movable
        ? _movableCell(
            row,
            col,
            existing,
            cell,
            grid: grid,
            draftButtons: draftButtons,
            scrolls: scrolls,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
          )
        : cell;
  }

  /// Modo de edição: arrastar move ou troca (respeitando botões grandes e limites);
  /// destaque em azul indica destino livre/válido, vermelho indica bloqueado.
  Widget _movableCell(
    int row,
    int col,
    DeckButton? existing,
    Widget cell, {
    required DeckGridFit grid,
    required List<DeckButton> draftButtons,
    required bool scrolls,
    required double tileWidth,
    required double tileHeight,
  }) {
    final c = AppleColors.of(context);
    final side = math.min(tileWidth, tileHeight);
    final radius = AppleShapes.tileRadius(side);

    // Destaque sutil nos botões ocupados durante a edição para deixar claro que podem ser movidos.
    final Widget decoratedCell = existing == null
        ? cell
        : DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: ShapeDecoration(
              shape: AppleShapes.squircle(
                radius,
                side: BorderSide(
                  color: c.accent.withValues(alpha: 0.32),
                  width: 1.25,
                ),
              ),
            ),
            child: cell,
          );

    return DragTarget<DeckButton>(
      onWillAcceptWithDetails: (d) =>
          d.data.row != row || d.data.column != col,
      onAcceptWithDetails: (d) => _applyDraftMove(d.data, row, col, grid),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        final canDrop = hovering &&
            candidate.first != null &&
            SlotOps.canDrop(
              draftButtons,
              slotOf(candidate.first!),
              (row: row, column: col),
              rows: grid.rows,
              columns: grid.cols,
            );
        final target = !hovering
            ? decoratedCell
            : DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: ShapeDecoration(
                  shape: AppleShapes.squircle(
                    radius,
                    side: BorderSide(
                      color: canDrop ? c.accent : c.red,
                      width: 2.5,
                    ),
                  ),
                ),
                child: AnimatedScale(
                  scale: canDrop ? 1.04 : 0.97,
                  duration: AppleMotion.of(context, AppleMotion.fast),
                  curve: AppleMotion.snappy,
                  child: decoratedCell,
                ),
              );
        if (existing == null) return target;
        final feedback = SizedBox(
          width: tileWidth,
          height: tileHeight,
          child: Material(
            type: MaterialType.transparency,
            child: Transform.scale(
              scale: 1.06,
              child: Opacity(
                opacity: 0.92,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: AppleShapes.squircle(radius),
                    shadows: AppleShadows.floating(Theme.of(context).brightness),
                  ),
                  child: IgnorePointer(
                    child: DynamicDeckButton(
                      button: existing,
                      liveKeys: false,
                      onTap: () {},
                      onLongPress: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final ghost = Opacity(opacity: 0.25, child: decoratedCell);
        void startDrag() {
          _draggingTile = true;
          _chromeTimer?.cancel();
          ThemeController.instance.tapFeedback();
        }

        void endDrag() {
          _draggingTile = false;
          if (_chrome && !_chromePaused) _scheduleChromeHide();
        }

        // Com a grade cabendo na tela, arrastar é imediato; com rolagem, espera um toque
        // curto (160 ms) para não brigar com o scroll vertical.
        if (scrolls) {
          return LongPressDraggable<DeckButton>(
            data: existing,
            delay: const Duration(milliseconds: 160),
            hapticFeedbackOnStart: true,
            onDragStarted: startDrag,
            onDragEnd: (_) => endDrag(),
            onDraggableCanceled: (_, __) => endDrag(),
            onDragCompleted: endDrag,
            feedback: feedback,
            childWhenDragging: ghost,
            child: target,
          );
        }
        return Draggable<DeckButton>(
          data: existing,
          onDragStarted: startDrag,
          onDragEnd: (_) => endDrag(),
          onDraggableCanceled: (_, __) => endDrag(),
          onDragCompleted: endDrag,
          feedback: feedback,
          childWhenDragging: ghost,
          child: target,
        );
      },
    );
  }

  Widget _buildCellContent(
    int row,
    int col,
    DeckButton? existing,
    List<DeckProfile> profiles, {
    required bool showEmpty,
  }) {
    if (existing == null) {
      // Fora do modo de edição, casa vazia é só espaço: um toque sem querer no meio de
      // uma live não abre "Novo botão". Deck ainda vazio mostra os "+" para começar.
      if (!showEmpty) return const SizedBox.shrink();
      final novo = DeckButton(
        id: '',
        label: tr('Novo botão'),
        row: row,
        column: col,
        action: DeckAction(type: 'none'),
      );
      return Semantics(
        button: true,
        label: tr('Criar botão'),
        child: DeckEmptyTile(
          onTap: () => _editButton(novo),
          onLongPress: () => _editButton(novo),
        ),
      );
    }
    // Toque longo com ação própria executa a ação. Sem ela, editar só no modo de edição
    // (lápis na barra); fora dele, um aviso diz como editar.
    final hasLongPress = existing.longPressAction != null;
    final tile = DynamicDeckButton(
      button: existing,
      liveKeys: !_editMode,
      onTap: _editMode
          ? () => _editButton(existing)
          : () => _handlePress(existing, profiles),
      onLongPress: _editMode
          ? () => _editButton(existing)
          : hasLongPress
              ? () => _handlePress(existing, profiles, gesture: 'longPress')
              : _hintEditMode,
    );
    // Só botões com toque duplo pagam a espera (~300 ms) para diferenciar do simples.
    if (_editMode || existing.doubleTapAction == null) return tile;
    return GestureDetector(
      onDoubleTap: () => _handlePress(existing, profiles, gesture: 'doubleTap'),
      child: tile,
    );
  }

  void _hintEditMode() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        // A barra de cima (com o lápis) fica escondida: o atalho entra direto na edição.
        content: Text(tr('Para editar, toque em "Editar agora".')),
        // Com ação, o Flutter deixa o aviso na tela até alguém fechar; este some sozinho.
        persist: false,
        action: SnackBarAction(
          label: tr('Editar agora'),
          onPressed: _enterEditMode,
        ),
      ));
  }

  /// Maior coluna e linha ocupadas numa lista de botões: a grade nunca esconde um botão
  /// que já existe (incluindo botões grandes).
  static (int, int) _extentsOf(List<DeckButton> buttons) {
    final min = SlotOps.minGrid(buttons);
    return (min.columns, min.rows);
  }

  static bool _isAiUsageProfile(DeckProfile p) {
    if (p.id == aiLimitsDemoProfileId) return false;
    final id = p.id.trim().toLowerCase();
    final name = p.name.trim().toLowerCase();
    return id == 'ai_usage' ||
        id == 'ai_limits' ||
        name == 'ai usage' ||
        name == 'ai limits' ||
        name == 'uso de ia' ||
        name == 'limites de ia';
  }

  /// Grade compartilhada explícita (escolhida pelo usuário no celular ou no PC).
  Map<String, int>? _explicitSharedGrid(
    ({int rows, int columns})? customGrid,
  ) {
    if (WebMode.deck) return _sharedGrid;
    if (customGrid != null) {
      return {'rows': customGrid.rows, 'columns': customGrid.columns};
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Só o configurador web (PC) usa o layout de 3 painéis (perfis | grade | props).
    // No celular mostramos sempre a grade de blocos — deitado ou em pé.
    if (WebMode.configurator) {
      return SteamDeckDesktopLayout(
        controller: controller,
        onToggleFullscreen: widget.onToggleFullscreen,
        isFullscreen: widget.isFullscreen,
      );
    }

    final isLoading = controller.isLoading.watch(context);
    final error = controller.error.watch(context);
    final profiles = controller.profiles.watch(context);
    final currentProfile = controller.currentProfile.watch(context);
    final offline = controller.offline.watch(context);
    final customGrid = ThemeController.instance.customGrid.watch(context);
    final deck = DeckTheme.of(context);
    final folder = _folderProfile(profiles);
    final active = folder ?? currentProfile;
    final screen = MediaQuery.sizeOf(context);
    final isPortrait = screen.height > screen.width;
    // Só as páginas de cima deslizam e entram nos pontinhos; pasta abre pelo botão dela.
    final topPages = topLevelPages(profiles);
    final pageIndex = currentProfile == null
        ? 0
        : math.max(
            0,
            topPages.indexWhere((p) {
              final at = _rootProfile ?? currentProfile;
              return p.id == (topLevelPageOf(profiles, at)?.id ?? at.id);
            }),
          );

    // Primeiro uso: o deck ainda não tem nenhum botão em nenhum perfil.
    final firstRun = error == null &&
        currentProfile != null &&
        profiles.isNotEmpty &&
        profiles.every((p) => p.buttons.isEmpty);

    // Página dedicada de AI Usage vazia: oferece o atalho direto "Conectar uma fonte".
    final emptyAiUsagePage = !firstRun &&
        !_editMode &&
        active != null &&
        active.buttons.isEmpty &&
        _isAiUsageProfile(active);

    // Área segura + respiro equilibrado (acompanha o espaçamento escolhido). Fora do modo
    // de edição as margens ficam constantes para esconder/mostrar os controles sem pular
    // nenhuma tecla.
    final safe = MediaQuery.paddingOf(context);
    final textScale = (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.0);
    final sidePad = (isPortrait ? 16.0 : 20.0) * deck.spacing.marginScale;
    final editBarReserve = 50.0 + (textScale - 1.0) * 24.0;
    final topPad = (_editMode ? editBarReserve : 14.0) +
        (isPortrait ? 6.0 : 2.0) * deck.spacing.marginScale;
    final bottomPad = math.max(safe.bottom, AppleSpacing.xs) +
        _bottomStrip +
        4 +
        (_editMode ? widget.bottomNavInset : 0);
    final leftClearance = widget.leftNavInset > 0 ? widget.leftNavInset + 6.0 : 0.0;
    final insets = EdgeInsets.fromLTRB(
      math.max(math.max(safe.left, sidePad), leftClearance),
      math.max(safe.top, AppleSpacing.sm) + topPad,
      math.max(safe.right, sidePad),
      bottomPad,
    );

    final shared = _explicitSharedGrid(customGrid);

    Widget deckArea;
    if (profiles.isEmpty) {
      final c = AppleColors.of(context);
      deckArea = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleUnusedAreaTap,
        child: isLoading
            ? Center(
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: c.secondaryLabel,
                  ),
                ),
              )
            : error == null
                ? EmptyState(
                    icon: Icons.grid_view_rounded,
                    title: tr('Nenhum perfil encontrado'),
                    action: PrimaryButton(
                      label: tr('Atualizar'),
                      icon: Icons.refresh_rounded,
                      onPressed: controller.loadProfiles,
                    ),
                  )
                : EmptyState(
                    icon: Icons.wifi_off_rounded,
                    title: tr('Sem conexão'),
                    message: tr(
                        'O PC não respondeu e este aparelho ainda não tem um deck dele salvo. '
                        'Confira se o DeckOS está aberto nele e na mesma rede.'),
                    action: PrimaryButton(
                      label: tr('Tentar novamente'),
                      icon: Icons.refresh_rounded,
                      onPressed: controller.loadProfiles,
                    ),
                  ),
      );
    } else {
      deckArea = LayoutBuilder(
        builder: (context, constraints) {
          final area = insets.deflateSize(constraints.biggest);
          DeckGridFit fitFor(DeckProfile page) {
            final btns = (_editMode && _editProfileId == page.id && _editDraft != null)
                ? _editDraft!
                : page.buttons;
            final (minCols, minRows) = _extentsOf(btns);
            final hasAiLimits = btns.any((b) => b.dynamicType == aiLimitsDynamicType);
            return DeckGridFit.compute(
              area: area,
              screen: screen,
              shared: shared,
              minCols: minCols,
              minRows: minRows,
              spacing: deck.spacing,
              allowReflow: !_editMode,
              minCellHeight: hasAiLimits ? DeckGridFit.aiLimitsMinCell : DeckGridFit.minCell,
              preferTwoColPortrait: hasAiLimits,
            );
          }

          // Reporta a grade automática natural do aparelho (sem inflar ao visitar páginas
          // maiores como o teclado 5×3, evitando trocar o celular para grade manual).
          final naturalAutoFit = DeckGridFit.compute(
            area: area,
            screen: screen,
            spacing: deck.spacing,
            allowReflow: false,
          );
          final activeFit = active != null
              ? fitFor(active)
              : DeckGridFit.compute(
                  area: area,
                  screen: screen,
                  shared: shared,
                  spacing: deck.spacing,
                  allowReflow: !_editMode,
                );
          _maybeReportLayout(naturalAutoFit);
          _grid = activeFit;

          final reduce = AppleMotion.of(context, AppleMotion.slow) == Duration.zero;
          final folderOpen = folder != null;
          final pages = AnimatedScale(
            // Pasta aberta: o deck de trás cresce suavemente enquanto a pasta entra.
            scale: folderOpen ? 1.08 : 1,
            duration: AppleMotion.of(context, AppleMotion.slow),
            curve: AppleMotion.smooth,
            child: AnimatedOpacity(
              opacity: folderOpen ? 0 : 1,
              duration: AppleMotion.of(context, AppleMotion.normal),
              child: IgnorePointer(
                ignoring: folderOpen,
                child: PageView.builder(
                  controller: _pageController,
                  // Travado durante a edição para arrastar teclas na horizontal sem trocar de página.
                  physics: _editMode
                      ? const NeverScrollableScrollPhysics()
                      : const DeckPagePhysics(),
                  itemCount: topPages.length,
                  onPageChanged: (index) {
                    if (index >= 0 && index < topPages.length) {
                      controller.currentProfile.value = topPages[index];
                      if (!_jumping) {
                        controller.rememberProfile(topPages[index].id);
                        ThemeController.instance.tapFeedback();
                        _touchChrome();
                      }
                      // Mudou de página na mão: a troca automática não volta mais pra cá.
                      if (!_jumping) _profileBeforeAuto = null;
                    }
                  },
                  itemBuilder: (context, i) {
                    // Toque em áreas livres (fundo, margens, vãos ou células vazias) revela ou
                    // recolhe os controles sem interceptar toques ou gestos das teclas.
                    final pageKey = ValueKey('deck-page-${topPages[i].id}');
                    final page = GestureDetector(
                      key: reduce ? pageKey : null,
                      behavior: HitTestBehavior.opaque,
                      onTap: _handleUnusedAreaTap,
                      child: Padding(
                        padding: insets,
                        child: _buildButtonGrid(topPages[i], profiles, fitFor(topPages[i])),
                      ),
                    );
                    if (reduce) return page;
                    return _PageDepth(key: pageKey, controller: _pageController, index: i, child: page);
                  },
                ),
              ),
            ),
          );
          final media = MediaQuery.of(context);
          final deckTouchSlop = math.max(
            media.gestureSettings.touchSlop ?? 0,
            kDeckTouchSlop,
          );
          return MediaQuery(
            data: media.copyWith(
              gestureSettings: DeviceGestureSettings(touchSlop: deckTouchSlop),
            ),
            child: Stack(
              children: [
                Positioned.fill(child: pages),
                // Pasta aberta (perfil empilhado): entra com zoom a partir do centro.
                Positioned.fill(
                  child: AnimatedSwitcher(
                    duration: AppleMotion.of(context, AppleMotion.slow),
                    reverseDuration: AppleMotion.of(context, AppleMotion.normal),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: CurvedAnimation(parent: anim, curve: AppleMotion.easeOut),
                      child: ScaleTransition(
                        scale: Tween(begin: 0.82, end: 1.0)
                            .animate(CurvedAnimation(parent: anim, curve: AppleMotion.snappy)),
                        child: child,
                      ),
                    ),
                    child: folder == null
                        ? const SizedBox.shrink(key: ValueKey('no-folder'))
                        : KeyedSubtree(
                            key: ValueKey('folder-${folder.id}'),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _handleUnusedAreaTap,
                              child: Padding(
                                padding: insets,
                                child: _buildButtonGrid(folder, profiles, fitFor(folder)),
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    final showToast = error != null &&
        profiles.isNotEmpty &&
        _dismissedError != error &&
        !(kDeckDemo && Uri.base.queryParameters['toast'] == '0');
    final chromeVisible = _chrome || _editMode;
    final c = AppleColors.of(context);

    // Voltar do Android fecha o modo de edição (pedindo confirmação se houver rascunho)
    // ou fecha a pasta aberta antes de sair do app.
    return PopScope(
      canPop: !_editMode && _navStack.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_editMode) {
          _confirmCancelEditMode();
        } else {
          _goBack(profiles);
        }
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_editMode) {
              _confirmCancelEditMode();
            } else if (_navStack.isNotEmpty) {
              _goBack(profiles);
            } else {
              _showChrome(!_chrome);
            }
          },
          const SingleActivator(LogicalKeyboardKey.contextMenu): () => _showChrome(true),
          const SingleActivator(LogicalKeyboardKey.f10): () => _showChrome(true),
        },
        child: Focus(
          autofocus: true,
          canRequestFocus: true,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            // Interações legítimas enquanto os controles estão visíveis adiam o recolhimento.
            onPointerDown: (_) => _touchChrome(),
            child: Scaffold(
              backgroundColor: deck.background,
              body: Stack(
                children: [
                  Positioned.fill(
                    child: profiles.isEmpty ? Padding(padding: insets, child: deckArea) : deckArea,
                  ),
                  // Faixa inferior: LED da conexão à esquerda e pontinhos/pasta/edição no meio.
                  // Recolhe junto com os demais controles após 5 s sem interação.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: widget.bottomNavInset,
                    child: IgnorePointer(
                      ignoring: !chromeVisible,
                      child: AnimatedSlide(
                        offset: chromeVisible ? Offset.zero : const Offset(0, 1.2),
                        duration: AppleMotion.of(context, AppleMotion.slow),
                        curve: AppleMotion.smooth,
                        child: AnimatedOpacity(
                          key: const ValueKey('deck-bottom-strip'),
                          opacity: chromeVisible ? 1 : 0,
                          duration: AppleMotion.of(context, AppleMotion.normal),
                          child: SafeArea(
                            top: false,
                            bottom: widget.bottomNavInset == 0,
                            minimum: const EdgeInsets.symmetric(horizontal: AppleSpacing.sm),
                            child: SizedBox(
                              height: _bottomStrip,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                        left: widget.leftNavInset > 0
                                            ? math.max(
                                                0.0,
                                                leftClearance -
                                                    math.max(safe.left, AppleSpacing.sm),
                                              )
                                            : 0.0,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const DeckLinkDot(),
                                          if (isLoading && profiles.isNotEmpty) ...[
                                            const SizedBox(width: AppleSpacing.xs),
                                            SizedBox.square(
                                              dimension: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 1.8,
                                                color: c.secondaryLabel,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                  AnimatedSwitcher(
                                    duration: AppleMotion.of(context, AppleMotion.normal),
                                    child: _editMode
                                        ? _EditPill(
                                            key: const ValueKey('edit'),
                                            dirty: _editDirty,
                                            onDone: _saveEditMode,
                                          )
                                        : folder != null
                                            ? _FolderPill(
                                                key: ValueKey('folder-pill-${folder.id}'),
                                                name: folder.name,
                                                onBack: () => _goBack(profiles),
                                              )
                                            : topPages.length > 1
                                                ? _PageDotsPill(
                                                    key: const ValueKey('dots'),
                                                    count: topPages.length,
                                                    index: pageIndex.clamp(
                                                        0, math.max(0, topPages.length - 1)),
                                                    onTap: _goToPage,
                                                  )
                                                : const SizedBox.shrink(
                                                    key: ValueKey('dots-empty'),
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
                  // Acabou de parear e o deck está vazio: diz os dois caminhos para o primeiro
                  // botão em vez de deixar só uma grade de "+".
                  if (firstRun && !_editMode)
                    Positioned(
                      bottom: widget.bottomNavInset + _bottomStrip + AppleSpacing.md,
                      left: math.max(AppleSpacing.md, leftClearance),
                      right: AppleSpacing.md,
                      child: SafeArea(
                        top: false,
                        left: widget.leftNavInset == 0,
                        bottom: widget.bottomNavInset == 0,
                        child: _EmptyDeckHint(onEdit: _enterEditMode),
                      ),
                    ),
                  // Página AI Usage vazia: atalho direto para conectar uma fonte real.
                  if (emptyAiUsagePage)
                    Positioned.fill(
                      child: SafeArea(
                        child: Center(
                          child: _EmptyAiUsageCard(
                            onConnect: () => _withChromePaused(() async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const AiLimitsSettingsPage(
                                    openWizardOnStart: true,
                                  ),
                                ),
                              );
                              if (mounted) controller.loadProfiles();
                            }),
                          ),
                        ),
                      ),
                    ),
                  // Zona discreta e invisível no topo: puxar para baixo, tocar ou acionar por
                  // leitor de tela revela os controles mesmo numa grade 100% preenchida.
                  if (!chromeVisible)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        bottom: false,
                        child: _EdgeRevealZone(onReveal: () => _showChrome(true)),
                      ),
                    ),
                  // Sem conexão: aviso flutuante no topo, com "tentar de novo".
                  Positioned(
                    top: 0,
                    left: math.max(AppleSpacing.md, leftClearance),
                    right: AppleSpacing.md,
                    child: SafeArea(
                      bottom: false,
                      left: widget.leftNavInset == 0,
                      child: Padding(
                        padding: const EdgeInsets.only(top: AppleSpacing.xl),
                        child: AnimatedSwitcher(
                          duration: AppleMotion.of(context, AppleMotion.normal),
                          transitionBuilder: (child, anim) => FadeTransition(
                            opacity: anim,
                            child: SlideTransition(
                              position: Tween(begin: const Offset(0, -0.4), end: Offset.zero)
                                  .animate(CurvedAnimation(parent: anim, curve: AppleMotion.smooth)),
                              child: child,
                            ),
                          ),
                          child: !showToast
                              ? const SizedBox.shrink()
                              : _OfflineToast(
                                  key: const ValueKey('toast'),
                                  offline: offline,
                                  onRetry: controller.loadProfiles,
                                  onClose: () => setState(() => _dismissedError = error),
                                ),
                        ),
                      ),
                    ),
                  ),
                  // Barra superior flutuante: largura média centrada na tela (sem deslocar
                  // pelo trilho lateral, garantindo folga em ambos os lados).
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      ignoring: !chromeVisible,
                      child: _positionTopChrome(
                        context: context,
                        safe: safe,
                        screen: screen,
                        textScale: textScale,
                        isPortrait: isPortrait,
                        child: AnimatedSlide(
                          offset: chromeVisible ? Offset.zero : const Offset(0, -1.15),
                          duration: AppleMotion.of(context, AppleMotion.slow),
                          curve: AppleMotion.smooth,
                          child: AnimatedOpacity(
                            key: const ValueKey('deck-top-chrome'),
                            opacity: chromeVisible ? 1 : 0,
                            duration: AppleMotion.of(context, AppleMotion.normal),
                            child: GestureDetector(
                              onVerticalDragEnd: (d) {
                                if ((d.primaryVelocity ?? 0) < 0 && !_editMode) _showChrome(false);
                              },
                              child: _buildChrome(profiles, currentProfile, folder),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _bottomStrip = 36.0;

  /// Posiciona e dimensiona a barra superior em largura média centrada na tela,
  /// respeitando recortes e o trilho lateral sem deslocar a barra para fora do centro.
  Widget _positionTopChrome({
    required BuildContext context,
    required EdgeInsets safe,
    required Size screen,
    required double textScale,
    required bool isPortrait,
    required Widget child,
  }) {
    final minLeft = widget.leftNavInset > 0
        ? widget.leftNavInset + 6.0
        : math.max(safe.left, 8.0);
    final minRight = math.max(safe.right, 8.0);
    final maxFullWidth = math.max(0.0, screen.width - minLeft - minRight);
    final maxCenteredWidth =
        math.max(0.0, screen.width - 2.0 * math.max(minLeft, minRight));
    final desiredWidth = isPortrait
        ? (screen.width * 0.86).clamp(300.0, 440.0) +
            math.max(0.0, textScale - 1.0) * 48.0
        : (screen.width * (_editMode ? 0.58 : 0.54)).clamp(380.0, 560.0) +
            math.max(0.0, textScale - 1.0) * 60.0;
    final pillWidth = math.min(desiredWidth, maxFullWidth);
    final fitsScreenCenter = pillWidth <= maxCenteredWidth + 0.5;

    final sized = SizedBox(width: pillWidth, child: child);
    if (fitsScreenCenter) {
      return Align(alignment: Alignment.topCenter, child: sized);
    }
    return Padding(
      padding: EdgeInsets.only(left: minLeft, right: minRight),
      child: Align(alignment: Alignment.topCenter, child: sized),
    );
  }

  Widget _buildChrome(
    List<DeckProfile> profiles,
    DeckProfile? currentProfile,
    DeckProfile? folder,
  ) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final status = Injector.get<SignalRService>().connectionStatus.watch(context);
    final link = DeckLink.of(status);
    const outerPad = EdgeInsets.only(top: 4);
    final barShadows = c.isDark
        ? [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.40),
              blurRadius: 14,
              spreadRadius: -2,
              offset: const Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ]
        : [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 12,
              spreadRadius: -2,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ];

    if (_editMode) {
      return SafeArea(
        bottom: false,
        left: false,
        right: false,
        child: Padding(
          padding: outerPad,
          child: FloatingPillSurface(
            key: const ValueKey('deck-top-pill'),
            radius: 22,
            borderColor: c.accent.withValues(alpha: c.isDark ? 0.45 : 0.35),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            shadows: barShadows,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 108),
                    child: TextButton(
                      style: TextButton.styleFrom(
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(44, 44),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _savingEdit ? null : _confirmCancelEditMode,
                      child: Text(
                        tr('Cancelar'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            folder?.name ?? currentProfile?.name ?? 'DeckOS',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: type.headline.copyWith(
                              fontSize: 14.5,
                              height: 1.15,
                              color: c.label,
                            ),
                          ),
                          Text(
                            tr('Modo de edição'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: type.caption2.copyWith(
                              fontSize: 11,
                              height: 1.15,
                              color: c.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _ChromeButton(
                    icon: Icons.undo_rounded,
                    tooltip: tr('Desfazer'),
                    onPressed: _editUndo.isNotEmpty && !_savingEdit ? _undoEditStep : null,
                  ),
                  _ChromeButton(
                    icon: Icons.grid_view_rounded,
                    tooltip: tr('Layout da grade'),
                    onPressed: _savingEdit ? null : _openLayoutSheet,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 2, right: 2),
                    child: _EditPillSaveButton(
                      label: _editDirty ? tr('Salvar') : tr('OK'),
                      loading: _savingEdit,
                      onPressed: _saveEditMode,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      bottom: false,
      left: false,
      right: false,
      child: Padding(
        padding: outerPad,
        child: FloatingPillSurface(
          key: const ValueKey('deck-top-pill'),
          radius: 22,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          shadows: barShadows,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              children: [
                if (folder != null)
                  _ChromeButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: tr('Voltar'),
                    onPressed: () => _goBack(profiles),
                  )
                else
                  const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    button: true,
                    label: '${folder?.name ?? currentProfile?.name ?? 'DeckOS'}, ${link.text}',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _withChromePaused(() => showConnectionDetails(context)),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                folder?.name ?? currentProfile?.name ?? 'DeckOS',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: type.headline.copyWith(
                                  fontSize: 14.5,
                                  height: 1.15,
                                  color: c.label,
                                ),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  StatusDot(color: link.color(c), size: 6, glow: false),
                                  const SizedBox(width: 5),
                                  Flexible(
                                    child: Text(
                                      link.text,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: type.caption2.copyWith(
                                        fontSize: 11,
                                        height: 1.15,
                                        color: c.secondaryLabel,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const PcMenuButton(),
                if ((folder ?? currentProfile) != null &&
                    (_isAiUsageProfile(folder ?? currentProfile!) ||
                        (folder ?? currentProfile!)
                            .buttons
                            .any((b) => b.dynamicType == aiLimitsDynamicType)))
                  _ChromeButton(
                    icon: Icons.add_circle_outline_rounded,
                    tooltip: tr('Conectar contas de IA'),
                    onPressed: () => _withChromePaused(() async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AiLimitsSettingsPage(),
                        ),
                      );
                      if (mounted) controller.loadProfiles();
                    }),
                  ),
                _ChromeButton(
                  icon: Icons.grid_view_rounded,
                  tooltip: tr('Layout da grade'),
                  onPressed: (folder ?? currentProfile) == null ? null : _openLayoutSheet,
                ),
                _ChromeButton(
                  icon: Icons.edit_rounded,
                  tooltip: tr('Editar layout'),
                  onPressed: (folder ?? currentProfile) == null ? null : _enterEditMode,
                ),
                _ChromeButton(
                  icon: Icons.settings_outlined,
                  tooltip: tr('Configurações'),
                  onPressed: () => _withChromePaused(() => Navigator.of(context).pushNamed('/config')),
                ),
                PopupMenuButton<_DeckOverflowAction>(
                  tooltip: tr('Mais opções'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  icon: Icon(Icons.more_horiz_rounded, size: 20, color: c.label),
                  onOpened: _pauseChrome,
                  onCanceled: _resumeChrome,
                  onSelected: (action) {
                    _resumeChrome();
                    switch (action) {
                      case _DeckOverflowAction.profile:
                        if (currentProfile != null) {
                          _withChromePaused(
                            () => ProfileSettingsDialog.show(
                              context,
                              currentProfile,
                              controller.updateProfileFull,
                            ),
                          );
                        }
                      case _DeckOverflowAction.fullscreen:
                        widget.onToggleFullscreen();
                    }
                  },
                  itemBuilder: (context) => [
                    if (currentProfile != null)
                      PopupMenuItem(
                        value: _DeckOverflowAction.profile,
                        child: Row(
                          children: [
                            Icon(Icons.tune_rounded, size: 18, color: c.secondaryLabel),
                            const SizedBox(width: 10),
                            Text(tr('Perfil')),
                          ],
                        ),
                      ),
                    PopupMenuItem(
                      value: _DeckOverflowAction.fullscreen,
                      child: Row(
                        children: [
                          Icon(
                            widget.isFullscreen
                                ? Icons.fullscreen_exit_rounded
                                : Icons.fullscreen_rounded,
                            size: 18,
                            color: c.secondaryLabel,
                          ),
                          const SizedBox(width: 10),
                          Text(widget.isFullscreen ? tr('Sair da tela cheia') : tr('Tela cheia')),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Quanto cabe e de que tamanho: a grade do deck ([deckCols]×[deckRows], a que o PC
/// conhece) e a grade desenhada agora ([cols]×[rows]), que só difere quando os botões
/// são reorganizados em ordem de leitura ([reflow]): celular em pé, navegador pequeno.
@immutable
class DeckGridFit {
  const DeckGridFit({
    required this.cols,
    required this.rows,
    required this.cell,
    required this.spacing,
    required this.area,
    required this.deckCols,
    required this.deckRows,
    this.reflow = false,
    this.comfortMinCell = minCell,
  });

  final int cols;
  final int rows;

  /// Lado de uma tecla.
  final double cell;
  final double spacing;

  /// Espaço disponível para a grade.
  final Size area;
  final int deckCols;
  final int deckRows;
  final bool reflow;

  /// Altura mínima confortável de uma célula antes de rolar a página.
  final double comfortMinCell;

  /// Menor tecla que ainda é confortável de tocar.
  static const minCell = 72.0;

  /// Altura mínima confortável para páginas com cartões de Limites de IA (evita
  /// cartões minúsculos espremidos no retrato ou em grades 4×4).
  static const aiLimitsMinCell = 136.0;

  /// Tecla-alvo do deck deitado. Grande como as dos prints: duas fileiras num celular.
  static const _target = 124.0;

  /// Tecla-alvo para contar colunas quando reorganiza (celular em pé).
  static const _reflowTarget = 96.0;

  /// Teto da tecla: num monitor grande ela não vira um outdoor.
  static const _maxCell = 240.0;

  /// Bordas que a grade deitada nunca usa: câmera, cantos e a faixa dos pontinhos.
  static const _sideReserve = 128.0;
  static const _vReserve = 72.0;

  static double spacingFor(
    Size screen, [
    DeckSpacing spacing = DeckSpacing.balanced,
  ]) =>
      spacing.minGapFor(screen);

  /// Vão padrão entre as teclas em fração da tecla (equilibrado).
  static const gapRatio = 0.145;

  /// Tecla e vão para [cols]×[rows] em [area]: o vão acompanha a tecla, nunca abaixo
  /// de [minGap].
  static (double, double) fitCell(
    Size area,
    int cols,
    int rows,
    double minGap, {
    double ratio = gapRatio,
  }) {
    var cell = math.min(
      area.width / (cols + ratio * (cols - 1)),
      area.height / (rows + ratio * (rows - 1)),
    );
    if (cell * ratio >= minGap) return (cell, cell * ratio);
    cell = math.min(
      (area.width - minGap * (cols - 1)) / cols,
      (area.height - minGap * (rows - 1)) / rows,
    );
    return (cell, minGap);
  }

  static int _fit(double extent, double target, double spacing) =>
      ((extent + spacing) / (target + spacing)).floor().clamp(1, 20);

  /// Calcula a grade para [area] numa tela [screen]. [shared] é a grade compartilhada do
  /// deck. [minCols]/[minRows]: a grade sempre cobre os botões que já existem. Sem
  /// [allowReflow] (modo de edição) a grade é sempre a do deck, mesmo com teclas
  /// pequenas: cada casa é uma posição salva.
  static DeckGridFit compute({
    required Size area,
    required Size screen,
    Map<String, int>? shared,
    int minCols = 1,
    int minRows = 1,
    DeckSpacing spacing = DeckSpacing.balanced,
    bool allowReflow = true,
    double minCellHeight = minCell,
    bool preferTwoColPortrait = false,
  }) {
    final sp = spacingFor(screen, spacing);
    final ratio = spacing.gapRatio;
    final comfortMin = math.max(minCell, minCellHeight);
    int dc, dr;
    final sc = shared?['columns'], sr = shared?['rows'];
    if (sc != null && sr != null && sc > 0 && sr > 0) {
      dc = sc;
      dr = sr;
    } else {
      // A grade é a do celular deitado, nas duas orientações. As fileiras enchem a altura
      // e as colunas saem de teclas quadradas do mesmo tamanho (4×2 num celular).
      final long = math.max(screen.width, screen.height) - _sideReserve;
      final short = math.min(screen.width, screen.height) - _vReserve;
      dr = _fit(short, _target, sp);
      final side = (short - sp * (dr - 1)) / dr;
      dc = _fit(long, side, sp);
    }
    dc = math.max(dc, minCols).clamp(1, 20);
    dr = math.max(dr, minRows).clamp(1, 20);

    final (cell, gap) = fitCell(area, dc, dr, sp, ratio: ratio);
    // Em pé com uma grade deitada (ou cartões largos de IA em 4 colunas), ou teclas
    // pequenas demais: reorganiza.
    final isTallPortrait = area.height > area.width * 1.15;
    final portrait = isTallPortrait && (dc > dr || (preferTwoColPortrait && dc > 2));
    if (!allowReflow || (!portrait && cell >= comfortMin)) {
      final c = cell.clamp(1.0, _maxCell);
      return DeckGridFit(
        cols: dc,
        rows: dr,
        cell: c,
        spacing: c < cell ? math.max(sp, c * ratio) : gap,
        area: area,
        deckCols: dc,
        deckRows: dr,
        comfortMinCell: comfortMin,
      );
    }
    // Colunas que cabem com teclas boas; em pé, no máximo as fileiras do deck (4×2
    // deitado vira 2×4 em pé). Páginas com cartões largos de IA usam 2 colunas em pé
    // para que cartões 2×1 ocupem toda a largura com ótima legibilidade.
    var cols = _fit(area.width, _reflowTarget, sp).clamp(1, dc);
    if (portrait && preferTwoColPortrait && dc >= 2) {
      cols = math.min(cols, 2);
    } else if (portrait && dr >= 2) {
      cols = math.min(cols, dr);
    }
    final g = math.max(sp, math.min((area.width - sp * (cols - 1)) / cols, _maxCell) * ratio);
    final w = math.min((area.width - g * (cols - 1)) / cols, _maxCell);
    final rows = math.max(1, ((area.height + g) / (w + g)).floor());
    return DeckGridFit(
      cols: cols,
      rows: rows,
      cell: math.max(1, w),
      spacing: g,
      area: area,
      deckCols: dc,
      deckRows: dr,
      reflow: true,
      comfortMinCell: comfortMin,
    );
  }

  /// Tecla para [usedRows] fileiras na grade reorganizada: encolhe para caber sem
  /// rolagem enquanto continuar boa de tocar; senão mantém e a página rola.
  double cellFor(int usedRows) {
    if (usedRows <= 0) return cell;
    final byHeight = (area.height - spacing * (usedRows - 1)) / usedRows;
    if (byHeight >= cell) return cell;
    return byHeight >= comfortMinCell ? byHeight : cell;
  }

  @override
  String toString() =>
      'DeckGridFit($cols×$rows, cell ${cell.toStringAsFixed(1)}, deck $deckCols×$deckRows${reflow ? ', reflow' : ''})';
}

/// Troca de página com mola: firme, sem quicar, como a tela inicial do iPhone.
class DeckPagePhysics extends PageScrollPhysics {
  const DeckPagePhysics({super.parent});

  @override
  DeckPagePhysics applyTo(ScrollPhysics? ancestor) =>
      DeckPagePhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: 1, stiffness: 240, ratio: 0.92);
}

/// Profundidade na troca de página: a que sai encolhe um pouco, apaga e anda mais
/// devagar que o dedo (paralaxe); a que entra faz o contrário.
///
/// A estrutura da árvore (Opacity -> Transform -> Transform -> child) permanece invariante
/// mesmo quando `t == 0` ou `t == 1`: alternar entre devolver `child!` e embrulhar em
/// `Opacity`/`Transform` desmontava e remontava toda a página (e seus sliders/estados)
/// duas vezes a cada arrasto. Em repouso (`opacity: 1`, `dx: 0`, `scale: 1`), o Flutter
/// pula a camada de composição e aplica matriz identidade sem custo visual.
class _PageDepth extends StatelessWidget {
  const _PageDepth({super.key, required this.controller, required this.index, required this.child});

  final PageController controller;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        var d = 0.0;
        final hasDims = controller.hasClients && controller.position.haveDimensions;
        if (hasDims) {
          d = (controller.page ?? index.toDouble()) - index;
        }
        final t = d.abs().clamp(0.0, 1.0);
        // Parada ao lado (|d| = 1) ou assentada (|d| = 0): identidade, mantendo a árvore
        // estável para não descartar e recriar os widgets da página.
        final atRest = !hasDims || t == 0 || t == 1;
        final opacity = atRest ? 1.0 : 1 - 0.45 * t;
        final dx = atRest ? 0.0 : d.sign * controller.position.viewportDimension * 0.12 * math.sin(math.pi * t);
        final scale = atRest ? 1.0 : 1 - 0.07 * t;
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(dx, 0),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
    );
  }
}

/// Zona invisível no topo para revelar os controles por toque, puxada ou leitor de tela.
class _EdgeRevealZone extends StatelessWidget {
  const _EdgeRevealZone({required this.onReveal});

  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tr('Mostrar controles'),
      child: GestureDetector(
        key: const ValueKey('deck-edge-reveal'),
        behavior: HitTestBehavior.opaque,
        onTap: onReveal,
        onVerticalDragUpdate: (d) {
          if (d.delta.dy > 2) onReveal();
        },
        child: const SizedBox(
          width: double.infinity,
          height: 14,
        ),
      ),
    );
  }
}

class _ChromeButton extends StatelessWidget {
  const _ChromeButton({required this.icon, required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return IconButton(
      icon: Icon(icon, size: 20),
      color: c.label,
      disabledColor: c.tertiaryLabel,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      style: IconButton.styleFrom(
        shape: const CircleBorder(),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
    );
  }
}

/// Botão compacto em cápsula para concluir/salvar o modo de edição na barra superior flutuante.
class _EditPillSaveButton extends StatelessWidget {
  const _EditPillSaveButton({
    required this.label,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final fg = c.onAccent;
    return Semantics(
      button: true,
      enabled: !loading,
      label: label,
      child: ApplePressable(
        onTap: loading ? null : onPressed,
        pressedScale: 0.96,
        haptic: false,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36, minWidth: 52),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.accent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: loading
              ? SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                )
              : Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.footnote.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Cápsula discreta atrás dos pontinhos de página para mantê-los nítidos sobre a grade.
class _PageDotsPill extends StatelessWidget {
  const _PageDotsPill({
    super.key,
    required this.count,
    required this.index,
    required this.onTap,
  });

  final int count;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final dark = c.isDark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? const Color(0xB8151519) : const Color(0xD9FFFFFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.08),
          width: 0.75,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: PageDots(
          count: count,
          index: index,
          onTap: onTap,
        ),
      ),
    );
  }
}

/// Aviso flutuante quando o PC não responde.
class _OfflineToast extends StatelessWidget {
  const _OfflineToast({
    super.key,
    required this.offline,
    required this.onRetry,
    required this.onClose,
  });

  final bool offline;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: GlassPanel(
          radius: AppleRadii.lg,
          padding: const EdgeInsets.fromLTRB(AppleSpacing.md, 6, 4, 6),
          child: Row(
            children: [
              const ConnectionStatusDot(link: DeckLink.offline, size: 8),
              const SizedBox(width: AppleSpacing.xs),
              Expanded(
                child: Text(
                  offline
                      ? tr('PC desconectado. Mostrando o último deck salvo neste aparelho.')
                      : tr('O PC não respondeu. Confira se o DeckOS está aberto nele.'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: type.footnote.copyWith(color: c.label),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 18),
                color: c.accent,
                tooltip: tr('Tentar novamente'),
                onPressed: onRetry,
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                color: c.secondaryLabel,
                tooltip: tr('Fechar'),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// No lugar dos pontinhos, dentro de uma pasta: o nome dela e a volta.
class _FolderPill extends StatelessWidget {
  const _FolderPill({super.key, required this.name, required this.onBack});

  final String name;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Semantics(
      button: true,
      label: tr('Voltar'),
      child: ApplePressable(
        onTap: onBack,
        pressedScale: 0.95,
        child: Container(
          height: 26,
          padding: const EdgeInsets.fromLTRB(6, 0, 10, 0),
          decoration: BoxDecoration(
            color: c.secondaryGroupedBackground,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: c.separator, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chevron_left_rounded, size: 15, color: c.secondaryLabel),
              const SizedBox(width: 2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.caption1.copyWith(
                    color: c.label,
                    fontWeight: FontWeight.w600,
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

/// No lugar dos pontinhos, editando: o que fazer e o atalho para concluir.
class _EditPill extends StatelessWidget {
  const _EditPill({super.key, required this.dirty, required this.onDone});

  final bool dirty;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      // Deixa folga para o LED da conexão à esquerda em telas estreitas (retrato).
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 28),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: c.accent.withValues(alpha: 0.35), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.open_with_rounded, size: 14, color: c.accent),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  tr('Arraste para mover · Toque para editar'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.caption1.copyWith(color: c.label),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDone,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    dirty ? tr('Salvar') : tr('OK'),
                    style: type.caption1.copyWith(
                      color: c.accent,
                      fontWeight: FontWeight.w700,
                    ),
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

/// Primeiro uso: o deck ainda não tem nenhum botão em nenhum perfil.
class _EmptyDeckHint extends StatelessWidget {
  final VoidCallback onEdit;

  const _EmptyDeckHint({required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: GlassPanel(
          radius: AppleRadii.lg,
          padding: const EdgeInsets.fromLTRB(
              AppleSpacing.md, AppleSpacing.sm, AppleSpacing.md, AppleSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.green.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppleRadii.sm),
                  border: Border.all(color: c.green.withValues(alpha: 0.28), width: 1),
                ),
                child: Icon(Icons.check_rounded, color: c.green, size: 20),
              ),
              const SizedBox(width: AppleSpacing.sm),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('Conectado! Agora, o primeiro botão'),
                        style: type.headline.copyWith(color: c.label)),
                    const SizedBox(height: 2),
                    Text(
                      tr('Toque num + para criar um botão aqui. Para atalhos e programas, monte '
                          'no PC: clique no ícone do DeckOS perto do relógio → "Abrir no '
                          'navegador". O que você criar lá aparece aqui na hora.'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: type.footnote.copyWith(color: c.secondaryLabel),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppleSpacing.sm),
              PrimaryButton(
                label: tr('Criar aqui no celular'),
                icon: Icons.add_rounded,
                compact: true,
                onPressed: onEdit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Página AI Usage vazia: atalho direto para conectar uma fonte real sem sair do deck.
class _EmptyAiUsageCard extends StatelessWidget {
  final VoidCallback onConnect;

  const _EmptyAiUsageCard({required this.onConnect});

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppleSpacing.lg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: GlassPanel(
          radius: AppleRadii.xl,
          padding: const EdgeInsets.all(AppleSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: c.orange.withValues(alpha: c.isDark ? 0.20 : 0.14),
                  borderRadius: BorderRadius.circular(AppleRadii.md),
                ),
                child: Icon(Icons.speed_rounded, color: c.orange, size: 26),
              ),
              const SizedBox(height: AppleSpacing.sm),
              Text(
                tr('Acompanhe seus limites de IA'),
                textAlign: TextAlign.center,
                style: type.headline.copyWith(color: c.label),
              ),
              const SizedBox(height: 6),
              Text(
                tr(
                  'Conecte seu CLIProxyAPI local, Codex app-server ou hook oficial do Claude Code para ver janelas reais em cartões móveis no deck.',
                ),
                textAlign: TextAlign.center,
                style: type.footnote.copyWith(color: c.secondaryLabel),
              ),
              const SizedBox(height: AppleSpacing.md),
              PrimaryButton(
                label: tr('Conectar uma fonte'),
                icon: Icons.add_rounded,
                onPressed: onConnect,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
