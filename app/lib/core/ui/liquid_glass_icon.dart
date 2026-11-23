import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/apple_tokens.dart';
import '../theme/deck_theme.dart';
import 'deck_squircle_tile.dart';
import 'liquid_glass.dart';

/// Ícone de app no visual "Liquid Glass" do macOS 26: placa de vidro com aro claro no
/// topo, brilho interno e o logo em relevo (degradê de luz por cima e sombra
/// embaixo). Serve para qualquer imagem:
///
/// * logo solto em fundo transparente (Windows, Linux): ganha a placa grafite e fica
///   centrado nela;
/// * ícone que já tem placa (macOS, Android, imagem cheia): é recortado no squircle e
///   só ganha o aro e o brilho, sem placa dobrada.
///
/// O tipo sai dos pixels, lido uma vez por imagem ([LiquidGlassCache]). Abaixo de
/// [detailMinSize] o aro e o brilho somem: num ícone de lista eles viram ruído.
/// Dentro de um [ApplePressable] a placa afunda um pouco e o aro acende ao toque.
class LiquidGlassIcon extends StatefulWidget {
  const LiquidGlassIcon({
    super.key,
    required ImageProvider this.image,
    required this.size,
    this.pressed,
    this.brightness,
    this.errorBuilder,
  }) : bytes = null;

  /// Ícone a partir dos bytes (PNG, JPEG...). Bytes iguais compartilham a decodificação.
  const LiquidGlassIcon.memory(
    Uint8List this.bytes, {
    super.key,
    required this.size,
    this.pressed,
    this.brightness,
    this.errorBuilder,
  }) : image = null;

  final ImageProvider? image;
  final Uint8List? bytes;

  /// Lado da placa (o ícone é sempre quadrado).
  final double size;

  /// Afundado; nulo segue o [ApplePressable] em volta.
  final bool? pressed;

  /// Claro ou escuro; nulo segue o fundo do deck.
  final Brightness? brightness;

  /// O que mostrar se a imagem não abre.
  final WidgetBuilder? errorBuilder;

  /// Lado mínimo para o aro, o brilho e as sombras.
  static const detailMinSize = 28.0;

  /// Lado do logo solto em fração da placa (o maior lado do desenho).
  static const glyphFraction = 0.76;

  /// Raio da placa em fração do lado: o dos ícones do macOS.
  static const radiusFactor = 0.225;

  @override
  State<LiquidGlassIcon> createState() => _LiquidGlassIconState();
}

class _LiquidGlassIconState extends State<LiquidGlassIcon> {
  Future<LiquidGlassArt?>? _future;
  Object? _key;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(LiquidGlassIcon old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes) || old.image != widget.image) {
      _resolve();
    }
  }

  void _resolve() {
    final bytes = widget.bytes;
    final key = bytes != null
        ? LiquidGlassCache.keyOf(bytes)
        : LiquidGlassCache.keyOfProvider(widget.image!);
    if (key == _key && _future != null) return;
    _key = key;
    _future = bytes != null
        ? LiquidGlassCache.ofBytes(bytes)
        : LiquidGlassCache.ofProvider(widget.image!);
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final brightness =
        widget.brightness ??
        (DeckTheme.of(context).background.computeLuminance() < 0.3
            ? Brightness.dark
            : Brightness.light);
    final pressed = widget.pressed ?? ApplePressable.isDown(context);
    return SizedBox.square(
      dimension: size,
      child: FutureBuilder<LiquidGlassArt?>(
        future: _future,
        initialData: _key == null ? null : LiquidGlassCache.peek(_key!),
        builder: (context, snap) {
          final art = snap.data;
          if (art == null) {
            final failed =
                snap.connectionState == ConnectionState.done ||
                (_key != null && LiquidGlassCache.has(_key!));
            if (failed && widget.errorBuilder != null) {
              return widget.errorBuilder!(context);
            }
            return const SizedBox.shrink();
          }
          return TweenAnimationBuilder<double>(
            tween: Tween(end: pressed ? 1 : 0),
            duration: AppleMotion.of(
              context,
              pressed ? AppleMotion.fast : AppleMotion.normal,
            ),
            curve: AppleMotion.easeOut,
            builder: (context, press, _) => RepaintBoundary(
              child: CustomPaint(
                size: Size.square(size),
                painter: LiquidGlassPainter(
                  art: art,
                  dark: brightness == Brightness.dark,
                  press: press,
                  detailed: size >= LiquidGlassIcon.detailMinSize,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Desenha a placa, o logo e o vidro. Público só para os testes de pintura.
class LiquidGlassPainter extends CustomPainter {
  LiquidGlassPainter({
    required this.art,
    required this.dark,
    this.press = 0,
    this.detailed = true,
  });

  final LiquidGlassArt art;
  final bool dark;

  /// 0 solto, 1 afundado.
  final double press;

  /// Aro, brilho e sombras (desligados em ícones miúdos).
  final bool detailed;

  static const _white = Color(0xFFFFFFFF);
  static const _black = Color(0xFF000000);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    if (s <= 0) return;
    final center = size.center(Offset.zero);
    // Afundar: a placa encolhe 4% (para 0,96) em volta do centro.
    final k = 1 - 0.04 * press;
    final plate = Rect.fromCenter(center: center, width: s * k, height: s * k);
    final side = plate.width;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(side * LiquidGlassIcon.radiusFactor),
    );
    final path = shape.getOuterPath(plate);
    final glyph = art.shape.kind == LiquidGlassKind.glyph;

    if (detailed) _plateShadow(canvas, path, side);

    if (glyph) {
      // Placa grafite quase lisa (#222224 em média), um tico mais clara em cima.
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? const [Color(0xFF272729), Color(0xFF1D1D1F)]
                : const [Color(0xFFFFFFFF), Color(0xFFEDEDF1)],
          ).createShader(plate),
      );
      if (detailed) _sheen(canvas, path, plate, strength: 1);
      _logo(canvas, plate);
    } else {
      canvas.save();
      canvas.clipPath(path);
      canvas.drawImageRect(
        art.image,
        _coverSource(plate.size),
        plate,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
      if (detailed) _sheen(canvas, path, plate, strength: 1.25);
    }

    if (detailed) _rim(canvas, plate, side, plated: !glyph);
  }

  /// Sombra macia da placa sobre a tecla.
  void _plateShadow(Canvas canvas, Path path, double side) {
    canvas.drawPath(
      path.shift(Offset(0, side * (dark ? 0.014 : 0.02))),
      Paint()
        ..color = _black.withValues(alpha: dark ? 0.48 : 0.16)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, side * 0.032),
    );
  }

  /// Brilho de vidro por dentro: luz no topo, um leve escuro na base.
  void _sheen(Canvas canvas, Path path, Rect plate, {required double strength}) {
    final lit = (dark ? 0.085 : 0.5) * strength * (1 + 0.35 * press);
    canvas.save();
    canvas.clipPath(path);
    canvas.drawRect(
      plate,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _white.withValues(alpha: lit.clamp(0, 1)),
            _white.withValues(alpha: 0),
            _black.withValues(alpha: 0),
            _black.withValues(alpha: ((dark ? 0.12 : 0.04) * strength).clamp(0, 1)),
          ],
          stops: const [0, 0.38, 0.72, 1],
        ).createShader(plate),
    );
    canvas.restore();
  }

  /// O aro de 1–2 px: forte no topo-esquerdo, some nas laterais e volta suave na
  /// base. Ao toque ele acende.
  void _rim(Canvas canvas, Rect plate, double side, {required bool plated}) {
    final w = (side * 0.014).clamp(1.0, 2.2);
    final boost = 1 + 0.7 * press;
    double a(double v) => (v * boost).clamp(0.0, 1.0);
    final ring = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(
        (side - w) * LiquidGlassIcon.radiusFactor,
      ),
    ).getOuterPath(plate.deflate(w / 2));
    if (!dark) {
      // No claro o aro branco não aparece sobre o branco: um fio escuro desenha a
      // borda e a luz fica só no topo.
      canvas.drawPath(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..color = _black.withValues(alpha: plated ? 0.10 : 0.08),
      );
    }
    final top = dark ? (plated ? 0.60 : 0.54) : 0.95;
    canvas.drawPath(
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..shader = LinearGradient(
          begin: const Alignment(-0.4, -1),
          end: const Alignment(0.4, 1),
          colors: [
            _white.withValues(alpha: a(top)),
            _white.withValues(alpha: a(top * 0.42)),
            _white.withValues(alpha: a(dark ? 0.06 : 0)),
            _white.withValues(alpha: a(dark ? 0.05 : 0)),
            _white.withValues(alpha: a(dark ? 0.20 : 0.3)),
          ],
          stops: const [0, 0.18, 0.45, 0.78, 1],
        ).createShader(plate),
    );
    if (dark) {
      // Ponto de brilho especular no canto superior esquerdo do aro de vidro.
      canvas.drawPath(
        ring,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..shader = RadialGradient(
            center: const Alignment(-0.85, -0.85),
            radius: 0.75,
            colors: [
              _white.withValues(alpha: a(plated ? 0.36 : 0.32)),
              _white.withValues(alpha: 0),
            ],
          ).createShader(plate),
      );
    }
  }

  /// O logo solto: centrado, com sombra embaixo e luz de cima.
  void _logo(Canvas canvas, Rect plate) {
    final src = _contentSource();
    final box = plate.width * LiquidGlassIcon.glyphFraction;
    final scale = box / (src.width > src.height ? src.width : src.height);
    final dst = Rect.fromCenter(
      center: plate.center,
      width: src.width * scale,
      height: src.height * scale,
    );
    final quality = Paint()..filterQuality = FilterQuality.medium;
    if (!detailed) {
      canvas.drawImageRect(art.image, src, dst, quality);
      return;
    }
    final side = plate.width;
    // Sombra: a silhueta do logo em preto, borrada e um pouco abaixo.
    canvas.saveLayer(
      dst.inflate(side * 0.12),
      Paint()
        ..colorFilter = ColorFilter.mode(
          _black.withValues(alpha: dark ? 0.55 : 0.22),
          BlendMode.srcIn,
        )
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: side * 0.022,
          sigmaY: side * 0.022,
        ),
    );
    canvas.drawImageRect(
      art.image,
      src,
      dst.shift(Offset(0, side * 0.028)),
      quality,
    );
    canvas.restore();

    // Relevo: luz de cima, sombra na base e um reflexo no canto de cima, só sobre
    // os pixels do logo (srcATop).
    canvas.saveLayer(dst.inflate(1), Paint());
    canvas.drawImageRect(art.image, src, dst, quality);
    canvas.drawRect(
      dst,
      Paint()
        ..blendMode = BlendMode.srcATop
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _white.withValues(alpha: 0.22),
            _white.withValues(alpha: 0),
            _black.withValues(alpha: 0),
            _black.withValues(alpha: 0.18),
          ],
          stops: const [0, 0.45, 0.6, 1],
        ).createShader(dst),
    );
    canvas.drawRect(
      dst,
      Paint()
        ..blendMode = BlendMode.srcATop
        ..shader = RadialGradient(
          center: const Alignment(-0.45, -0.75),
          radius: 0.7,
          colors: [
            _white.withValues(alpha: 0.2),
            _white.withValues(alpha: 0),
          ],
        ).createShader(dst),
    );
    canvas.restore();
  }

  /// Parte da imagem com desenho (sem a margem transparente).
  Rect _contentSource() {
    final w = art.image.width.toDouble(), h = art.image.height.toDouble();
    final c = art.shape.content;
    final r = Rect.fromLTRB(c.left * w, c.top * h, c.right * w, c.bottom * h);
    return r.isEmpty ? Offset.zero & Size(w, h) : r;
  }

  /// A placa da imagem, cortada para cobrir [target] sem distorcer.
  Rect _coverSource(Size target) {
    final r = _contentSource();
    final want = target.width / target.height;
    if (r.width / r.height > want) {
      final w = r.height * want;
      return Rect.fromCenter(center: r.center, width: w, height: r.height);
    }
    final h = r.width / want;
    return Rect.fromCenter(center: r.center, width: r.width, height: h);
  }

  @override
  bool shouldRepaint(LiquidGlassPainter old) =>
      old.art != art ||
      old.dark != dark ||
      old.press != press ||
      old.detailed != detailed;
}

/// Relevo para os glifos dos botões de sistema (volume, mídia, microfone): o glifo
/// continua branco, mas ganha luz de cima, a base um pouco mais escura e uma sombra
/// macia. Sem placa: a tecla já é o fundo.
class LiquidGlassGlyph extends StatelessWidget {
  const LiquidGlassGlyph({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = (child is Icon ? (child as Icon).size : null) ??
        IconTheme.of(context).size ?? 24;
    if (size < LiquidGlassIcon.detailMinSize) return child;
    final dark = DeckTheme.of(context).background.computeLuminance() < 0.3;
    return IconTheme.merge(
      data: IconThemeData(
        shadows: [
          Shadow(
            color: Colors.black.withValues(alpha: dark ? 0.55 : 0.18),
            blurRadius: size * 0.1,
            offset: Offset(0, size * 0.045),
          ),
        ],
      ),
      child: ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (r) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.14),
            Colors.white.withValues(alpha: 0),
            Colors.black.withValues(alpha: dark ? 0.16 : 0.1),
          ],
          stops: const [0, 0.42, 1],
        ).createShader(r),
        child: child,
      ),
    );
  }
}
