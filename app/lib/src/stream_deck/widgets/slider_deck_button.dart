import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../buttons/colors.dart';

/// Tipos de botão controle deslizante (dynamicType).
const sliderTypes = {'volume_slider'};

/// Controle deslizante: arrasta o dedo para mudar um valor no PC — volume (do PC, do
/// microfone, de um app, de uma fonte do OBS, de uma pessoa no Discord), brilho (luzes,
/// monitor) ou a posição da música. Em pé quando o botão é mais alto que largo; deitado no
/// contrário. Um
/// botão grande (1×3, 3×1) dá mais precisão. O toque continua indo para [onTap] (editar,
/// no modo de edição) e o toque longo abre o editor.
class SliderDeckButton extends StatefulWidget {
  final DeckButton button;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// No configurador do PC o botão é arrastável para mudar de casa: aí o controle só mostra.
  final bool interactive;

  const SliderDeckButton({
    super.key,
    required this.button,
    required this.onTap,
    required this.onLongPress,
    this.interactive = true,
  });

  @override
  State<SliderDeckButton> createState() => _SliderDeckButtonState();
}

class _SliderDeckButtonState extends State<SliderDeckButton> {
  int? _volume;

  /// Fim da escala: 100, 200 (pessoa no Discord) ou a duração da faixa em segundos.
  int _max = 100;
  bool _mute = false;

  /// Nome que o PC devolve (lâmpada, faixa) e texto no lugar do número (posição "1:23").
  String? _serverLabel;
  String? _text;

  /// Mensagem do PC quando o alvo falhou (integração desconectada, luz fora da rede).
  String? _error;
  bool _dragging = false;
  Timer? _poll;
  Timer? _sendTimer;
  int? _pending;

  String get _target => widget.button.dynamicParameters?['target'] ?? 'output';
  String get _app => widget.button.dynamicParameters?['app'] ?? '';

  /// Parâmetros do alvo (sem o próprio alvo).
  Map<String, String> get _params =>
      Map.of(widget.button.dynamicParameters ?? const {})..remove('target');
  DeckOSClient get _client => Injector.get<DeckOSClient>();

  @override
  void initState() {
    super.initState();
    _refresh();
    // O volume também muda por fora (teclas do PC, outro botão): relê de tempos em tempos.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_dragging) _refresh();
    });
  }

  @override
  void didUpdateWidget(SliderDeckButton old) {
    super.didUpdateWidget(old);
    if (old.button.dynamicParameters != widget.button.dynamicParameters) _refresh();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _sendTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    Map<String, dynamic>? state;
    String? error;
    try {
      state = await _client.getSlider(_target, _params);
    } catch (e) {
      error = '$e'.replaceFirst('Exception: ', '');
    }
    if (!mounted || _dragging) return;
    setState(() {
      _error = error;
      _volume = (state?['volume'] as num?)?.round();
      _max = ((state?['max'] as num?)?.round() ?? 100).clamp(1, 1 << 30);
      _mute = state?['mute'] == true;
      _serverLabel = state?['label'] as String?;
      _text = state?['text'] as String?;
    });
  }

  /// Manda no máximo ~12 vezes por segundo enquanto arrasta; o último valor sempre vai.
  void _send(int volume) {
    _pending = volume;
    if (_sendTimer?.isActive ?? false) return;
    _flush();
    _sendTimer = Timer(const Duration(milliseconds: 80), _flush);
  }

  void _flush() {
    final v = _pending;
    _pending = null;
    if (v != null) _client.setSlider(_target, _params, v);
  }

  void _update(Offset local, Size size, bool vertical) {
    final fraction = vertical
        ? 1 - local.dy / size.height
        : local.dx / size.width;
    final v = (fraction.clamp(0.0, 1.0) * _max).round();
    if (v == _volume) return;
    setState(() {
      _volume = v;
      // Posição da música: mostra o tempo enquanto arrasta.
      if (_target == 'media') _text = _clock(v);
    });
    _send(v);
  }

  static String _clock(int seconds) {
    final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  }

  static const _lights = {'tuya', 'homeassistant', 'hue', 'govee', 'keylight'};

  IconData get _icon {
    final off = _mute || _volume == 0;
    if (_lights.contains(_target)) return off ? CupertinoIcons.lightbulb : CupertinoIcons.lightbulb_fill;
    return switch (_target) {
      'input' => off ? CupertinoIcons.mic_slash_fill : CupertinoIcons.mic_fill,
      'monitor' => CupertinoIcons.sun_max_fill,
      'media' => CupertinoIcons.music_note,
      'discord_user' => off ? CupertinoIcons.speaker_slash_fill : CupertinoIcons.person_fill,
      _ => off ? CupertinoIcons.speaker_slash_fill : CupertinoIcons.speaker_3_fill,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = parseHexColor(widget.button.backgroundColor);
    final label = widget.button.label?.isNotEmpty == true
        ? widget.button.label!
        : switch (_target) {
            'input' => tr('Microfone'),
            'app' => _app,
            'monitor' => tr('Brilho'),
            'obs' => _params['inputName'] ?? 'OBS',
            _ when _serverLabel?.isNotEmpty == true => _serverLabel!,
            'media' => tr('Música'),
            _ when _lights.contains(_target) => tr('Luz'),
            _ => tr('Volume'),
          };
    return DeckTile(
      color: color,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final vertical = size.height > size.width;
        final fraction = ((_volume ?? 0) / _max).clamp(0.0, 1.0);
        final fg = DeckTile.foregroundOf(context);
        // Como os controles do Control Center: trilho translúcido e o nível em cor
        // sólida, com o texto invertido onde o nível cobre.
        final tint = color != null && HSLColor.fromColor(color).saturation >= 0.15 ? color : null;
        final fill = _mute
            ? fg.withValues(alpha: 0.35)
            : (tint ?? fg.withValues(alpha: 0.92));
        final onFill = AppleColors.onColor(Color.alphaBlend(fill, DeckTheme.of(context).tileColor));
        final inner = size.shortestSide;
        // Raio concêntrico com o da tecla (que tem 8% de respiro em volta).
        final radius = AppleShapes.tileRadius(inner / 0.84) - inner / 0.84 * 0.08;
        Widget labels(Color ink) => Center(
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_error != null ? CupertinoIcons.link : _icon, color: ink, size: 22),
                      const SizedBox(height: 2),
                      Text(
                        _volume == null ? '—' : (_text ?? '$_volume%'),
                        style: TextStyle(
                          color: ink,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: size.width - 12),
                        child: Text(_error ?? label,
                            maxLines: _error != null ? 2 : 1,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: ink.withValues(alpha: 0.75),
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ),
              ),
            );
        final content = ClipRSuperellipse(
          borderRadius: BorderRadius.circular(radius.clamp(4.0, 60.0)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: fg.withValues(alpha: 0.08)),
              TweenAnimationBuilder<double>(
                tween: Tween(end: fraction),
                // Arrastando, o nível segue o dedo sem atraso.
                duration: _dragging ? Duration.zero : AppleMotion.of(context, DeckTileMotion.normal),
                curve: AppleMotion.smooth,
                builder: (context, f, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRect(clipper: _LevelClip(f, vertical, filled: false), child: labels(fg)),
                    ClipRect(
                      clipper: _LevelClip(f, vertical, filled: true),
                      child: ColoredBox(color: fill, child: labels(onFill)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
        if (!widget.interactive) return content;
        void start(Offset p) {
          _dragging = true;
          _update(p, size, vertical);
        }

        void end() {
          _dragging = false;
          _sendTimer?.cancel();
          _flush();
        }

        // Só o eixo do controle: arrastar no outro sentido continua trocando de página.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: vertical ? (d) => start(d.localPosition) : null,
          onVerticalDragUpdate: vertical ? (d) => _update(d.localPosition, size, vertical) : null,
          onVerticalDragEnd: vertical ? (_) => end() : null,
          onHorizontalDragStart: vertical ? null : (d) => start(d.localPosition),
          onHorizontalDragUpdate: vertical ? null : (d) => _update(d.localPosition, size, vertical),
          onHorizontalDragEnd: vertical ? null : (_) => end(),
          child: content,
        );
      }),
    );
  }
}

/// Recorta a parte cheia ([filled]) ou vazia do controle no nível [fraction].
class _LevelClip extends CustomClipper<Rect> {
  _LevelClip(this.fraction, this.vertical, {required this.filled});

  final double fraction;
  final bool vertical;
  final bool filled;

  @override
  Rect getClip(Size size) {
    final f = fraction.clamp(0.0, 1.0);
    if (vertical) {
      final top = size.height * (1 - f);
      return filled
          ? Rect.fromLTRB(0, top, size.width, size.height)
          : Rect.fromLTRB(0, 0, size.width, top);
    }
    final right = size.width * f;
    return filled
        ? Rect.fromLTRB(0, 0, right, size.height)
        : Rect.fromLTRB(right, 0, size.width, size.height);
  }

  @override
  bool shouldReclip(_LevelClip old) =>
      old.fraction != fraction || old.vertical != vertical || old.filled != filled;
}
