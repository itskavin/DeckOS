import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator, CupertinoIcons;
import 'package:flutter/material.dart';

import 'usage_bars.dart' show CapsuleBar;

/// Tipos de botão de informação (dynamicType) desenhados por [InfoDeckButton].
const infoTypes = {
  'clock',
  'weather',
  'now_playing',
  'command',
  'url',
  'notifications',
  'ai_usage',
};

/// Botão que mostra uma informação ao vivo: relógio, clima, o que está tocando, a saída
/// de um comando ou um valor de uma URL. O relógio é calculado aqui; o resto vem do PC
/// (ReceiveInfoState / ReceiveNowPlaying). O toque executa a ação do botão, se houver.
class InfoDeckButton extends StatefulWidget {
  final DeckButton button;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Color? color;

  const InfoDeckButton({
    super.key,
    required this.button,
    required this.onTap,
    required this.onLongPress,
    this.color,
  });

  @override
  State<InfoDeckButton> createState() => _InfoDeckButtonState();
}

class _InfoDeckButtonState extends State<InfoDeckButton> {
  Timer? _clock;

  String get _type => widget.button.dynamicType ?? '';
  Map<String, String> get _params => widget.button.dynamicParameters ?? const {};

  @override
  void initState() {
    super.initState();
    if (_type == 'clock') {
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DeckTile(
      color: widget.color,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: switch (_type) {
        'clock' => _buildClock(),
        'now_playing' => Watch((_) => _buildNowPlaying(Injector.get<SignalRService>()
            .stateOf('ReceiveNowPlaying'))),
        _ => Watch((_) {
            final all = Injector.get<SignalRService>().stateOf('ReceiveInfoState');
            final v = all[widget.button.id];
            return _buildValue(v is Map ? Map<String, dynamic>.from(v) : null);
          }),
      },
    );
  }

  String? get _label =>
      (widget.button.label?.isNotEmpty ?? false) ? widget.button.label : null;

  Widget _small(String text, {double alpha = 0.7, int maxLines = 1}) => Builder(
        builder: (context) => Text(
          text,
          textAlign: TextAlign.center,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: DeckTile.foregroundOf(context).withValues(alpha: alpha),
          ),
        ),
      );

  Widget _big(String text, {int maxLines = 1}) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: maxLines,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.6,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      );

  // ---- Relógio ----

  static const _weekdays = ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'];

  Widget _buildClock() {
    final now = DateTime.now();
    final h24 = _params['format24'] != 'false';
    final seconds = _params['showSeconds'] == 'true';
    final date = _params['showDate'] != 'false';
    String two(int n) => n.toString().padLeft(2, '0');
    final hour = h24 ? now.hour : (now.hour % 12 == 0 ? 12 : now.hour % 12);
    var time = '${h24 ? two(hour) : hour}:${two(now.minute)}';
    if (seconds) time += ':${two(now.second)}';
    if (!h24) time += now.hour < 12 ? ' AM' : ' PM';
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_label != null) _small(_label!),
          _big(time),
          if (date)
            // A ordem de dia e mês vem do arquivo do idioma (inglês: mês/dia).
            _small('${tr(_weekdays[now.weekday - 1])}, ' +
                tr('{day}/{month}', {'day': two(now.day), 'month': two(now.month)})),
        ],
      ),
    );
  }

  // ---- Clima, comando e URL ----

  Widget _buildValue(Map<String, dynamic>? v) {
    if (v == null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CupertinoActivityIndicator(),
          if (_label != null) ...[const SizedBox(height: 6), _small(_label!)],
        ],
      );
    }
    final text = '${v['text'] ?? ''}';
    final sub = v['sub'] as String?;
    final error = v['error'] == true;
    if (_type == 'weather' && !error) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(weatherIcon(v['code'] as int?, v['isDay'] != false), size: 26),
          _big(text),
          _small(_label ?? sub ?? ''),
        ],
      );
    }
    if (_type == 'ai_usage' && !error && v['rows'] is List) {
      return _buildAiUsage((v['rows'] as List).whereType<Map>().toList());
    }
    if (_type == 'notifications' && !error) {
      final count = int.tryParse(text) ?? 0;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Badge(
            isLabelVisible: count > 0,
            label: Text(
              count > 99 ? '99+' : '$count',
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
            child: Icon(
                count > 0 ? CupertinoIcons.bell_fill : CupertinoIcons.bell,
                size: 28),
          ),
          const SizedBox(height: 4),
          _small(_label ?? sub ?? tr('Notificações')),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_label != null) _small(_label!),
          if (error) ...[
            const Icon(CupertinoIcons.exclamationmark_triangle_fill, size: 22, color: DeckTileColors.yellow),
            if (sub != null)
              Flexible(
                child: Builder(
                  builder: (context) => InfoValueText(
                    sub,
                    maxLines: 3,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: DeckTile.foregroundOf(context).withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
          ] else
            Flexible(
              child: text.length <= 8
                  ? _big(text)
                  : InfoValueText(
                      text,
                      maxLines: 3,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  // ---- Uso de IA ----

  /// Limites do plano (uma barra por janela, com a hora em que zera se couber) ou tokens de
  /// hoje e da semana. As linhas vêm do PC com chave e número; nome e formato são daqui.
  Widget _buildAiUsage(List<Map> rows) {
    final provider = _params['provider'] == 'codex' ? 'Codex' : 'Claude';
    final title = _label ?? provider;
    if (_params['show'] == 'tokens') {
      int count(String key) =>
          (rows.firstWhere((r) => r['key'] == key, orElse: () => const {})['count'] as num?)
              ?.toInt() ??
          0;
      return Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _small(title),
            _big(compactCount(count('today'))),
            _small(tr('hoje')),
            const SizedBox(height: 2),
            _small(tr('7 dias: {n}', {'n': compactCount(count('week_tokens'))}), alpha: 0.85),
          ],
        ),
      );
    }
    return LayoutBuilder(builder: (context, c) {
      final roomy = c.maxHeight >= 120;
      final fg = DeckTile.foregroundOf(context);
      Widget row(Map r) {
        final pct = (r['percent'] as num?)?.toDouble() ?? 0;
        final resets = DateTime.tryParse('${r['resetsAt'] ?? ''}')?.toLocal();
        final name = r['key'] == 'session' ? tr('5 horas') : tr('Semana');
        // Semana: compara com o ritmo que fecharia a semana em 100%.
        final pace = r['key'] == 'week' && resets != null ? WeekPace.of(pct, resets) : null;
        final paceColor = switch (pace?.status) {
          PaceStatus.high => DeckTileColors.orange,
          PaceStatus.low => DeckTileColors.blue,
          _ => DeckTileColors.green,
        };
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: fg.withValues(alpha: 0.75))),
                ),
                // Fora do ritmo, o número ganha a cor: laranja gastando rápido, azul sobrando.
                Text('${pct.round()}%',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: pace == null || pace.status == PaceStatus.onTrack ? null : paceColor)),
              ]),
              const SizedBox(height: 2),
              LayoutBuilder(builder: (context, bar) {
                return Stack(clipBehavior: Clip.none, children: [
                  CapsuleBar(value: pct / 100, color: usageColor(pct), height: 5),
                  // Marca onde o uso "deveria" estar agora para fechar a semana em 100%.
                  if (pace != null)
                    Positioned(
                      left: (bar.maxWidth * pace.expected / 100 - 1).clamp(0.0, bar.maxWidth - 2),
                      top: -2,
                      bottom: -2,
                      child: Container(width: 2, color: fg.withValues(alpha: 0.85)),
                    ),
                ]);
              }),
              if (roomy && pace != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Builder(
                    builder: (context) => FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(pace.label,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 10,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: paceColor,
                          )),
                    ),
                  ),
                ),
              if (roomy && resets != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: _small(tr('zera {quando}', {'quando': resetLabel(resets)}), alpha: 0.6),
                ),
            ],
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(CupertinoIcons.sparkles, size: 12),
              const SizedBox(width: 4),
              Flexible(child: _small(title, alpha: 0.85)),
            ]),
            const SizedBox(height: 2),
            if (rows.isEmpty) _small(tr('Sem dados'))
            else
              for (final r in rows) row(r),
          ],
        ),
      );
    });
  }

  // ---- Tocando agora ----

  Widget _buildNowPlaying(Map<String, dynamic> np) {
    final title = np['title'] as String?;
    final artist = np['artist'] as String?;
    var thumb = np['thumbnailBase64'] as String?;
    if (thumb != null && thumb.startsWith('data:')) {
      thumb = thumb.substring(thumb.indexOf(',') + 1);
    }
    if (title == null || title.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(CupertinoIcons.music_note, size: 28),
          const SizedBox(height: 4),
          _small(_label ?? tr('Nada tocando')),
        ],
      );
    }
    Widget? cover;
    if (thumb != null && thumb.isNotEmpty) {
      final bytes = LiquidGlassCache.decodeBase64(thumb);
      if (bytes != null) {
        cover = Image.memory(bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const Icon(CupertinoIcons.music_note));
      }
    }
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: LayoutBuilder(builder: (context, c) {
              // Botão grande (2×1) não é quadrado: a imagem não passa da altura disponível.
        final w = c.maxWidth.isFinite ? c.maxWidth * 0.62 : 48.0;
        final side = c.maxHeight.isFinite && c.maxHeight < w ? c.maxHeight : w;
              return ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: side,
                  height: side,
                  child: Stack(fit: StackFit.expand, children: [
                    cover ?? const Icon(CupertinoIcons.music_note, size: 28),
                    if (np['playing'] != true)
                      Container(
                        color: Colors.black45,
                        child: const Icon(CupertinoIcons.pause_fill, color: Colors.white),
                      ),
                  ]),
                ),
              );
            }),
          ),
          const SizedBox(height: 2),
          Text(title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
          if (artist != null && artist.isNotEmpty) _small(artist),
        ],
      ),
    );
  }
}

/// Quebra um texto em até [maxLines] linhas respeitando limites de palavra, sem partir
/// uma palavra ao meio. Palavras maiores que [maxWidth] ficam inteiras na própria linha
/// para serem truncadas com reticências dentro da largura disponível.
List<String> packWordLines(
  String text, {
  required double maxWidth,
  required TextStyle style,
  required int maxLines,
  TextDirection textDirection = TextDirection.ltr,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final words = text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  if (maxLines <= 1 || words.length == 1 || !maxWidth.isFinite || maxWidth <= 0) {
    return [words.join(' ')];
  }

  double measure(String s) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = tp.width;
    tp.dispose();
    return width;
  }

  final lines = <String>[];
  var current = words.first;
  for (var i = 1; i < words.length; i++) {
    final word = words[i];
    final candidate = '$current $word';
    if (measure(candidate) <= maxWidth) {
      current = candidate;
      continue;
    }
    if (lines.length == maxLines - 1) {
      // Última linha: mantém o restante para o Text aplicar reticências no limite.
      current = '$current ${words.sublist(i).join(' ')}';
      break;
    }
    lines.add(current);
    current = word;
  }
  lines.add(current);
  return lines;
}

/// Texto de valor em botões de informação: quebra apenas entre palavras e usa reticências
/// dentro dos limites do botão, mantendo dígitos tabulares.
class InfoValueText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final int maxLines;

  const InfoValueText(
    this.text, {
    super.key,
    required this.style,
    this.maxLines = 3,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        var lineLimit = maxLines;
        if (constraints.hasBoundedHeight) {
          final metrics = TextPainter(
            text: TextSpan(text: 'Ag', style: effectiveStyle),
            textDirection: textDirection,
            textScaler: textScaler,
            maxLines: 1,
          )..layout();
          final lineHeight = metrics.height;
          metrics.dispose();
          if (lineHeight > 0) {
            final fitting = (constraints.maxHeight / lineHeight).floor();
            if (fitting < lineLimit) lineLimit = fitting;
          }
        }
        if (lineLimit <= 0) return const SizedBox.shrink();
        final lines = packWordLines(
          text,
          maxWidth: constraints.maxWidth,
          style: effectiveStyle,
          maxLines: lineLimit,
          textDirection: textDirection,
          textScaler: textScaler,
        );
        if (lines.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final line in lines)
              Text(
                line,
                textAlign: TextAlign.center,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
          ],
        );
      },
    );
  }
}

/// Ícone do tempo pelo código WMO do Open-Meteo.
IconData weatherIcon(int? code, bool isDay) {
  if (code == null) return CupertinoIcons.thermometer;
  if (code == 0) return isDay ? CupertinoIcons.sun_max_fill : CupertinoIcons.moon_stars_fill;
  if (code <= 2) return isDay ? CupertinoIcons.cloud_sun_fill : CupertinoIcons.cloud_moon_fill;
  if (code == 3) return CupertinoIcons.cloud_fill;
  if (code == 45 || code == 48) return CupertinoIcons.cloud_fog_fill;
  if (code >= 51 && code <= 67) return CupertinoIcons.cloud_drizzle_fill;
  if (code >= 71 && code <= 77) return CupertinoIcons.snow;
  if (code >= 80 && code <= 82) return CupertinoIcons.cloud_heavyrain_fill;
  if (code == 85 || code == 86) return CupertinoIcons.snow;
  if (code >= 95) return CupertinoIcons.cloud_bolt_rain_fill;
  return CupertinoIcons.cloud_fill;
}

/// Cor da barra de uso: verde, laranja a partir de 60%, vermelho a partir de 85%.
Color usageColor(double pct) {
  // Cores de sistema do iOS (versão escura: o deck é preto por padrão).
  if (pct > 85) return DeckTileColors.red;
  if (pct > 60) return DeckTileColors.orange;
  return DeckTileColors.green;
}

/// 1234 → "1,2 mil"; 3456789 → "3,5 mi" (inglês: "3.5M"; espanhol: "3,5 M").
String compactCount(int n) {
  // As abreviações vêm do arquivo do idioma.
  String f(double v) {
    var t = v < 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(0);
    if (t.endsWith('.0')) t = t.substring(0, t.length - 2);
    return decimalText(t);
  }

  if (n >= 1000000000) return tr('{n} bi', {'n': f(n / 1e9)});
  if (n >= 1000000) return tr('{n} mi', {'n': f(n / 1e6)});
  if (n >= 1000) return tr('{n} mil', {'n': f(n / 1e3)});
  return '$n';
}

/// Quando um limite zera: só a hora se for hoje; senão o dia da semana e a hora.
String resetLabel(DateTime at, {DateTime? now}) {
  now ??= DateTime.now();
  // A Anthropic manda 20:39:59.9; mostra o minuto cheio.
  at = at.add(const Duration(seconds: 30));
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(at.hour)}:${two(at.minute)}';
  final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
  if (sameDay) return time;
  const days = ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'];
  return '${tr(days[at.weekday - 1])} $time';
}

enum PaceStatus { low, onTrack, high }

/// Ritmo do uso semanal: onde o uso estaria agora num ritmo constante que fecha a semana em
/// 100% ([expected]) e onde ele fecha se continuar como está ([projected]).
class WeekPace {
  final double expected;
  final double projected;
  final PaceStatus status;

  const WeekPace(this.expected, this.projected, this.status);

  static const week = Duration(days: 7);

  /// Nulo nas primeiras horas da semana, quando a projeção ainda não diz nada.
  static WeekPace? of(double used, DateTime resetsAt, {DateTime? now}) {
    now ??= DateTime.now();
    final left = resetsAt.difference(now);
    if (left.isNegative || left > week) return null;
    final elapsed = 1 - left.inSeconds / week.inSeconds;
    if (elapsed < 0.05) return null;
    final expected = elapsed * 100;
    final projected = used / elapsed;
    final status = projected > 110
        ? PaceStatus.high
        : projected < 85
            ? PaceStatus.low
            : PaceStatus.onTrack;
    return WeekPace(expected, projected, status);
  }

  /// "fecha em ~153%": onde a semana termina mantendo o ritmo de agora.
  String get label => tr('fecha em ~{p}%', {'p': '${projected.clamp(0, 999).round()}'});
}
