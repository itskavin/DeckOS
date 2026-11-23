import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/config/keep_awake.dart';
import 'package:deckos/src/config/settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const tallyEvent = 'ReceiveTallyState';
const tallyTargetPrefKey = 'tally_target';

/// Alvo do sinal manual: é o único que se liga e desliga por aqui.
const tallyManualTarget = 'manual/onair';

/// O que a tela de tally mostra. Sem conexão é [noSignal], nunca [idle]: quem está diante da
/// câmera não pode achar que está fora do ar só porque o Wi-Fi caiu.
enum TallyMode { program, preview, idle, noSignal }

/// Estado de um alvo, a partir do que o PC publicou.
TallyMode tallyModeOf(
  Map<String, dynamic> state,
  String? target, {
  required bool linked,
}) {
  if (!linked || target == null) return TallyMode.noSignal;
  final targets = state['targets'];
  if (targets is! Map) return TallyMode.noSignal;
  final entry = targets[target];
  if (entry is! Map) return TallyMode.noSignal;
  return switch (entry['state']) {
    'program' => TallyMode.program,
    'preview' => TallyMode.preview,
    'idle' => TallyMode.idle,
    _ => TallyMode.noSignal,
  };
}

/// Cores de transmissão: vermelho no ar, verde em preview. Sempre com texto, para quem não
/// distingue vermelho de verde.
const tallyProgramColor = Color(0xFFC62828);
const tallyPreviewColor = Color(0xFF1B7F3B);

/// Celular em tela cheia como luz de "no ar" ou tally de câmera. Cada aparelho acompanha o
/// próprio alvo, guardado nele.
class TallyPage extends StatefulWidget {
  /// Alvo do botão que abriu a tela. Sem ele, vale o último escolhido neste aparelho.
  final String? target;

  const TallyPage({super.key, this.target});

  @override
  State<TallyPage> createState() => _TallyPageState();
}

class _TallyPageState extends State<TallyPage> {
  String? _target;
  bool _ready = false;
  bool _chrome = false;
  Timer? _hideChrome;

  /// Aviso de erro no topo (o PC não respondeu ao ligar/desligar).
  String? _error;
  Timer? _hideError;

  SignalRService get _signalR => Injector.get<SignalRService>();

  @override
  void initState() {
    super.initState();
    _signalR.listenState(tallyEvent);
    _seed();
    _restoreTarget();
    _keepAwake(true);
  }

  @override
  void dispose() {
    _hideChrome?.cancel();
    _hideError?.cancel();
    _keepAwake(false);
    super.dispose();
  }

  void _keepAwake(bool on) {
    // Sem suporte no aparelho (navegador antigo): a tela segue, só pode apagar sozinha.
    // Ao sair, volta ao que o usuário escolheu em Ajustes (Manter a tela ligada).
    if (on) {
      WakelockPlus.toggle(enable: true).catchError((_) {});
    } else {
      KeepAwake.restore();
    }
  }

  Future<void> _seed() async {
    try {
      final state = await Injector.get<DeckOSClient>().getActionState(
        'tally',
      );
      if (state != null && mounted) _signalR.seedState(tallyEvent, state);
    } catch (_) {
      // Sem resposta: fica em "sem sinal" até o hub mandar o estado.
    }
  }

  Future<void> _restoreTarget() async {
    var target = widget.target;
    if (target == null || target.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      target = prefs.getString(tallyTargetPrefKey);
    }
    if (!mounted) return;
    setState(() {
      _target = target;
      _ready = true;
    });
    if (target == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickTarget());
    } else if (target == tallyManualTarget) {
      _showChrome();
    }
  }

  Future<void> _pickTarget() async {
    final picked = await showSettingsSheet<String>(
      context: context,
      title: tr('O que acompanhar'),
      builder: (_) => _TargetPicker(current: _target),
    );
    if (picked == null || !mounted) return;
    setState(() => _target = picked);
    if (picked == tallyManualTarget) _showChrome();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(tallyTargetPrefKey, picked);
  }

  void _toggleChrome() {
    if (_chrome) {
      _hideChrome?.cancel();
      setState(() => _chrome = false);
    } else {
      _showChrome();
    }
  }

  /// Os controles somem sozinhos: uma tela de corredor não fica com botão à vista, e um
  /// toque sem querer não liga o ON AIR (são dois toques: mostrar e apertar).
  void _showChrome() {
    _hideChrome?.cancel();
    setState(() => _chrome = true);
    _hideChrome = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _chrome = false);
    });
  }

  Future<void> _setManual(bool on) async {
    _showChrome();
    try {
      await Injector.get<DeckOSClient>().executeAction(
        DeckAction(
          type: 'tally',
          parameters: {'operation': on ? 'manual_on' : 'manual_off'},
        ),
      );
    } catch (_) {
      if (!mounted) return;
      _hideError?.cancel();
      setState(() => _error = tr('Não foi possível falar com o PC.'));
      _hideError = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _error = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fade = AppleMotion.of(context, const Duration(milliseconds: 90));
    final chromeFade = AppleMotion.of(context, AppleMotion.normal);
    return Watch((context) {
      final state = _signalR.stateOf(tallyEvent);
      final linked = _signalR.connectionStatus.value == 'Connected';
      final mode = tallyModeOf(state, _target, linked: linked);
      final targets = state['targets'];
      final entry = targets is Map ? targets[_target] : null;
      final label = entry is Map ? '${entry['label'] ?? ''}' : '';
      // Sem sinal não há como saber o estado, então não oferece ligar nem desligar.
      final canSwitch =
          _target == tallyManualTarget && mode != TallyMode.noSignal;
      final showTop = _chrome || _target == null;
      return Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleChrome,
          child: AnimatedContainer(
            duration: fade,
            color: switch (mode) {
              TallyMode.program => tallyProgramColor,
              TallyMode.preview => tallyPreviewColor,
              TallyMode.idle => const Color(0xFF0C0C0E),
              TallyMode.noSignal => const Color(0xFF3A3A3C),
            },
            child: SafeArea(
              child: Stack(
                children: [
                  if (_ready)
                    Positioned.fill(
                      child: _TallyFace(
                        mode: mode,
                        label: label,
                        hasTarget: _target != null,
                        hint: canSwitch && !_chrome
                            ? tr('Toque na tela para ligar ou desligar.')
                            : null,
                      ),
                    ),
                  if (_chrome && canSwitch)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: AppleSpacing.lg,
                      child: Center(
                        child: PrimaryButton(
                          color: Colors.white,
                          onPressed: () =>
                              _setManual(mode != TallyMode.program),
                          icon: mode == TallyMode.program
                              ? Icons.stop_rounded
                              : Icons.sensors_rounded,
                          label: mode == TallyMode.program
                              ? tr('Desligar o ON AIR')
                              : tr('Ligar o ON AIR'),
                        ),
                      ),
                    ),
                  Positioned(
                    top: AppleSpacing.xs,
                    left: AppleSpacing.sm,
                    right: AppleSpacing.sm,
                    child: IgnorePointer(
                      ignoring: !showTop,
                      child: AnimatedOpacity(
                        opacity: showTop ? 1 : 0,
                        duration: chromeFade,
                        child: Row(
                          children: [
                            _GlassButton(
                              tooltip: tr('Voltar'),
                              icon: Icons.arrow_back_rounded,
                              onTap: () => Navigator.of(context).maybePop(),
                            ),
                            const Spacer(),
                            _GlassButton(
                              icon: Icons.tune_rounded,
                              label: tr('Trocar'),
                              onTap: _pickTarget,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_error != null)
                    Positioned(
                      top: 64,
                      left: AppleSpacing.screen,
                      right: AppleSpacing.screen,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: Theme(
                            data: ThemeData(brightness: Brightness.dark),
                            child: AppleBanner(
                              tone: BannerTone.error,
                              message: _error!,
                              onDismiss: () => setState(() => _error = null),
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
      );
    });
  }
}

/// Botão de vidro sobre a cor do tally (voltar, trocar o alvo).
class _GlassButton extends StatelessWidget {
  final IconData icon;
  final String? label;
  final String? tooltip;
  final VoidCallback onTap;

  const _GlassButton({
    required this.icon,
    required this.onTap,
    this.label,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final type = AppleTextStyles.of(context);
    final child = ApplePressable(
      onTap: onTap,
      child: GlassPanel(
        radius: 22,
        color: Colors.black.withValues(alpha: 0.28),
        padding: EdgeInsets.symmetric(
          horizontal: label == null ? AppleSpacing.sm - 1 : AppleSpacing.md,
          vertical: AppleSpacing.sm - 1,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            if (label != null) ...[
              const SizedBox(width: AppleSpacing.xs - 2),
              Text(
                label!,
                style: type.subheadline.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return Semantics(
      button: true,
      label: label ?? tooltip,
      child: tooltip == null ? child : Tooltip(message: tooltip!, child: child),
    );
  }
}

class _TallyFace extends StatelessWidget {
  final TallyMode mode;
  final String label;
  final bool hasTarget;
  final String? hint;

  const _TallyFace({
    required this.mode,
    required this.label,
    required this.hasTarget,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final type = AppleTextStyles.of(context);
    final (title, detail) = switch (mode) {
      TallyMode.program => (tr('NO AR'), label),
      TallyMode.preview => (tr('PREVIEW'), label),
      TallyMode.idle => (tr('FORA DO AR'), label),
      TallyMode.noSignal => (
        tr('SEM SINAL'),
        hasTarget
            ? tr('Sem resposta do PC ou do programa. O estado é desconhecido.')
            : tr('Escolha o que acompanhar.'),
      ),
    };
    final fg = mode == TallyMode.idle
        ? Colors.white.withValues(alpha: 0.72)
        : Colors.white;
    return Semantics(
      liveRegion: true,
      label: detail.isEmpty ? title : '$title. $detail',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppleSpacing.xl,
          AppleSpacing.xxl + AppleSpacing.md,
          AppleSpacing.xl,
          72,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              flex: 3,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  title,
                  maxLines: 1,
                  style: type.largeTitle.copyWith(
                    color: fg,
                    fontSize: 200,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -4,
                    height: 1,
                  ),
                ),
              ),
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: AppleSpacing.md),
              Flexible(
                child: Text(
                  detail,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: type.title2.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (hint != null) ...[
              const SizedBox(height: AppleSpacing.xs),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: type.subheadline.copyWith(
                  color: fg.withValues(alpha: 0.8),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Lista do que está conectado agora, do PC.
class _TargetPicker extends StatefulWidget {
  final String? current;

  const _TargetPicker({this.current});

  @override
  State<_TargetPicker> createState() => _TargetPickerState();
}

class _TargetPickerState extends State<_TargetPicker> {
  List<Map<String, dynamic>>? _options;
  Object? _failed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = null);
    try {
      final list =
          await Injector.get<DeckOSClient>().getJson('/api/tally/targets')
              as List;
      if (!mounted) return;
      setState(
        () => _options = list
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );
    } catch (e) {
      if (mounted) setState(() => _failed = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final options = _options;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: _failed != null
          ? Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpacing.screen,
                AppleSpacing.xs,
                AppleSpacing.screen,
                AppleSpacing.xl,
              ),
              child: AppleBanner(
                tone: BannerTone.error,
                message: tr('Não foi possível falar com o PC.'),
                actionLabel: tr('Tentar de novo'),
                onAction: _load,
              ),
            )
          : options == null
          ? Padding(
              padding: const EdgeInsets.all(AppleSpacing.xl),
              child: Center(
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: c.secondaryLabel,
                  ),
                ),
              ),
            )
          : ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(top: AppleSpacing.xs),
              children: [
                InsetGroupedSection(
                  footer: tr('A lista traz só o que está conectado agora.'),
                  children: [
                    for (final o in options)
                      ListRow(
                        title: '${o['label']}',
                        trailing: '${o['value']}' == widget.current
                            ? Icon(
                                Icons.check_rounded,
                                size: 20,
                                color: c.accent,
                              )
                            : const SizedBox(width: 20),
                        onTap: () => Navigator.of(context).pop('${o['value']}'),
                      ),
                  ],
                ),
              ],
            ),
    );
  }
}
