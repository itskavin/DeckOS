import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'usage_bars.dart' show DeckRing;

/// Botão de timer/cronômetro/pomodoro/contador. O PC manda o estado só quando algo
/// muda; aqui o tempo anda sozinho a partir do instante em que o estado chegou.
class TimerDeckButton extends StatefulWidget {
  final DeckButton button;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Color? color;
  final Color? activeColor;

  const TimerDeckButton({
    super.key,
    required this.button,
    required this.onTap,
    required this.onLongPress,
    this.color,
    this.activeColor,
  });

  static const stateEvent = 'ReceiveTimerState';

  @override
  State<TimerDeckButton> createState() => _TimerDeckButtonState();
}

class _TimerDeckButtonState extends State<TimerDeckButton> {
  Timer? _ticker;
  bool _wasFinished = false;
  String? _lastPhase;
  bool _seen = false;

  Map<String, String> get _params =>
      widget.button.action?.parameters ?? const {};

  /// Timer exibido: o do próprio botão ou o de outro ("zerar" ao lado do relógio).
  String get _timerId {
    final target = _params['target'];
    return (target == null || target.isEmpty || target == 'self')
        ? widget.button.id
        : target;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Liga o relógio local só enquanto algo está correndo.
  void _syncTicker(bool running) {
    if (running && _ticker == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } else if (!running && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  /// Vibra quando uma contagem termina ou o pomodoro troca de fase.
  void _alertOnTransition(Map<String, dynamic> t) {
    final finished = t['finished'] == true;
    final phase = t['phase'] as String?;
    final changedPhase =
        _lastPhase != null && phase != null && phase != _lastPhase;
    // Na primeira leitura só registra: abrir o deck com um timer já terminado não vibra.
    if (_seen && ((finished && !_wasFinished) || changedPhase)) {
      ThemeController.instance.alertFeedback();
    }
    _wasFinished = finished;
    _lastPhase = t['mode'] == 'pomodoro' ? phase : null;
    _seen = true;
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final all = Injector.get<SignalRService>().stateOf(
        TimerDeckButton.stateEvent,
      );
      final receivedAt =
          (all['_receivedAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      final raw = all[_timerId];
      final t = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};

      final running = t['running'] == true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _syncTicker(running);
          _alertOnTransition(t);
        }
      });

      return _render(t, receivedAt);
    });
  }

  Widget _render(Map<String, dynamic> t, int receivedAt) {
    final mode = (t['mode'] as String?) ?? _params['mode'] ?? 'countdown';
    final running = t['running'] == true;
    final finished = t['finished'] == true;
    var elapsed = (t['elapsedMs'] as num?)?.toInt() ?? 0;
    if (running) {
      elapsed += DateTime.now().millisecondsSinceEpoch - receivedAt;
    }
    final duration =
        (t['durationMs'] as num?)?.toInt() ??
        ((double.tryParse(_params['durationMin'] ?? '') ?? 5) * 60000).round();

    String big;
    String small;
    double? progress;
    IconData icon;
    switch (mode) {
      case 'counter':
        big = '${(t['count'] as num?)?.toInt() ?? 0}';
        small = tr('Contador');
        icon = CupertinoIcons.plus_circle_fill;
        break;
      case 'stopwatch':
        big = _clock(elapsed, roundUp: false);
        small = running
            ? tr('Cronômetro')
            : (elapsed > 0 ? tr('Pausado') : tr('Cronômetro'));
        icon = CupertinoIcons.stopwatch_fill;
        break;
      case 'pomodoro':
        final remaining = (duration - elapsed).clamp(0, duration);
        big = _clock(remaining);
        final cycles = (t['cycles'] as num?)?.toInt() ?? 0;
        small = '${t['phase'] == 'break' ? tr('Pausa') : tr('Foco')} · $cycles';
        progress = duration > 0 ? elapsed / duration : null;
        icon = t['phase'] == 'break' ? CupertinoIcons.moon_fill : CupertinoIcons.scope;
        break;
      default:
        final remaining = (duration - elapsed).clamp(0, duration);
        big = _clock(remaining);
        small = finished ? tr('Fim!') : (running ? tr('Timer') : tr('Pausado'));
        if (!running && !finished && elapsed == 0) small = tr('Timer');
        progress = duration > 0 ? elapsed / duration : null;
        icon = CupertinoIcons.hourglass_bottomhalf_fill;
    }

    final op = (_params['operation'] ?? 'toggle').toLowerCase();
    final label = (widget.button.label?.isNotEmpty ?? false)
        ? widget.button.label!
        : switch (op) {
            'reset' => tr('Zerar'),
            'skip' => tr('Pular'),
            'decrement' => '−',
            _ => small,
          };

    return DeckTile(
      color: widget.color,
      active: finished,
      activeColor: widget.activeColor,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: LayoutBuilder(
        builder: (context, c) {
          final fg = DeckTile.foregroundOf(context);
          final side = c.maxWidth < c.maxHeight ? c.maxWidth : c.maxHeight;
          // FittedBox: num botão pequeno o conjunto encolhe em vez de cortar o rótulo.
          final face = FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(op == 'reset' ? CupertinoIcons.arrow_counterclockwise : icon,
                    size: 16, color: fg.withValues(alpha: 0.7)),
                Text(
                  big,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.6,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: fg.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          );
          if (progress == null) {
            return Padding(padding: const EdgeInsets.all(4), child: face);
          }
          // Contagem: anel fino que vai se fechando, como o timer do iPhone.
          return Center(
            child: SizedBox.square(
              dimension: side,
              child: DeckRing(
                value: 1 - progress.clamp(0.0, 1.0),
                color: finished ? fg : DeckTileColors.orange,
                stroke: (side * 0.05).clamp(3.0, 6.0),
                child: Padding(padding: EdgeInsets.all(side * 0.16), child: face),
              ),
            ),
          );
        },
      ),
    );
  }

  /// mm:ss, ou h:mm:ss a partir de uma hora. Arredonda para cima numa contagem
  /// regressiva não mostrar 00:00 com tempo sobrando.
  static String _clock(int ms, {bool roundUp = true}) {
    final total = roundUp ? (ms / 1000).ceil() : ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }
}
