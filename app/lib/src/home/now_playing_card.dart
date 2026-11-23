import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

/// "Tocando agora" no molde do cartão da tela de bloqueio do iPhone: capa grande, título
/// e artista, barra de tempo fina e os três controles. O fundo é a própria capa,
/// desfocada e escurecida.
class NowPlayingCard extends StatefulWidget {
  const NowPlayingCard({super.key, required this.session, required this.onCommand});

  final MediaSession session;
  final ValueChanged<String> onCommand;

  @override
  State<NowPlayingCard> createState() => _NowPlayingCardState();
}

class _NowPlayingCardState extends State<NowPlayingCard> {
  /// Palpite mostrado entre o toque e a chegada do estado real (o PC responde já com o
  /// estado aplicado; isto cobre só o tempo de rede). Vale enquanto o estado real for o
  /// mesmo de quando o palpite foi feito, ou até o timer de segurança.
  String? _guess;
  String? _statusWhenGuessed;
  Timer? _guessTimer;

  Uint8List? _art;
  String? _artSource;

  @override
  void didUpdateWidget(NowPlayingCard old) {
    super.didUpdateWidget(old);
    if (_guess != null && widget.session.playbackStatus != _statusWhenGuessed) _clearGuess();
  }

  @override
  void dispose() {
    _guessTimer?.cancel();
    super.dispose();
  }

  void _clearGuess() {
    _guessTimer?.cancel();
    _guess = null;
    _statusWhenGuessed = null;
  }

  bool get _playing =>
      (_guess ?? widget.session.playbackStatus ?? '').toLowerCase() == 'playing';

  void _playPause() {
    setState(() {
      _guessTimer?.cancel();
      _statusWhenGuessed = widget.session.playbackStatus;
      _guess = _playing ? 'Paused' : 'Playing';
      _guessTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(_clearGuess);
      });
    });
    widget.onCommand('playpause');
  }

  /// Capa decodificada uma vez por imagem (não a cada redesenho).
  Uint8List? get _artBytes {
    final raw = widget.session.thumbnailBase64;
    if (raw == _artSource) return _art;
    _artSource = raw;
    _art = null;
    if (raw != null && raw.isNotEmpty) {
      try {
        _art = base64Decode(raw.startsWith('data:') ? raw.substring(raw.indexOf(',') + 1) : raw);
      } catch (_) {}
    }
    return _art;
  }

  static String _clock(double seconds) {
    final s = seconds.isFinite ? seconds.round().clamp(0, 1 << 30) : 0;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final s = widget.session;
    final art = _artBytes;
    final dark = Theme.of(context).brightness == Brightness.dark || art != null;
    final ink = dark ? Colors.white : c.label;
    final soft = ink.withValues(alpha: 0.6);
    final hasTime = s.duration > 0;

    Widget cover({double size = 64}) => DecoratedBox(
          decoration: ShapeDecoration(
            shape: AppleShapes.squircle(AppleRadii.md),
            // Sombra só sobre a capa desfocada; no cartão claro ela vira uma mancha.
            shadows: art != null ? AppleShadows.floating(Brightness.dark) : null,
          ),
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(AppleRadii.md),
            child: SizedBox.square(
              dimension: size,
              child: art != null
                  ? Image.memory(art, fit: BoxFit.cover, gaplessPlayback: true)
                  : ColoredBox(
                      color: c.tertiaryFill,
                      child: Icon(Icons.music_note_rounded, color: soft, size: size * 0.45),
                    ),
            ),
          ),
        );

    Widget control(IconData icon, double size, VoidCallback? onTap, String label) => Semantics(
          button: true,
          label: label,
          child: Opacity(
            opacity: onTap == null ? 0.35 : 1,
            child: ApplePressable(
              onTap: onTap,
              pressedScale: 0.85,
              child: SizedBox(
                width: size + 24,
                height: size + 16,
                child: Icon(icon, size: size, color: ink),
              ),
            ),
          ),
        );

    final content = Padding(
      padding: const EdgeInsets.all(AppleSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              cover(),
              const SizedBox(width: AppleSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.title ?? tr('Faixa desconhecida'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.headline.copyWith(color: ink)),
                    Text(s.artist ?? tr('Artista desconhecido'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.subheadline.copyWith(color: soft)),
                  ],
                ),
              ),
            ],
          ),
          if (hasTime) ...[
            const SizedBox(height: AppleSpacing.md),
            ExcludeSemantics(
              child: Container(
                height: 4,
                alignment: Alignment.centerLeft,
                decoration: ShapeDecoration(
                    color: ink.withValues(alpha: 0.18), shape: const StadiumBorder()),
                child: FractionallySizedBox(
                  widthFactor: (s.position / s.duration).clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                        color: ink.withValues(alpha: 0.85), shape: const StadiumBorder()),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            DefaultTextStyle(
              style: type.caption2.copyWith(
                  color: soft, fontFeatures: const [FontFeature.tabularFigures()]),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_clock(s.position)),
                  Text('-${_clock(s.duration - s.position)}'),
                ],
              ),
            ),
          ] else
            const SizedBox(height: AppleSpacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              control(Icons.skip_previous_rounded, 28,
                  s.canGoPrevious ? () => widget.onCommand('previous') : null, tr('Anterior')),
              control(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, 38,
                  s.canPlayPause ? _playPause : null, 'Play/Pause'),
              control(Icons.skip_next_rounded, 28,
                  s.canGoNext ? () => widget.onCommand('next') : null, tr('Próxima')),
            ],
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.md, vertical: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppleRadii.lg),
          border: Border.all(color: c.separator, width: 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppleRadii.lg),
          child: Stack(
            children: [
              Positioned.fill(
                child: art == null
                    ? ColoredBox(color: c.secondaryGroupedBackground)
                    : ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                        child: Transform.scale(
                          scale: 1.6,
                          child: Image.memory(art, fit: BoxFit.cover, gaplessPlayback: true),
                        ),
                      ),
              ),
              if (art != null) const Positioned.fill(child: ColoredBox(color: Color(0x73000000))),
              content,
            ],
          ),
        ),
      ),
    );
  }
}
