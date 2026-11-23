import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

/// Arte vetorial personalizada desenhada direto no [Canvas] para os ícones de
/// destaque do modo demonstração (originais, sem baixar nenhum logo externo).
typedef DemoArtPainter = void Function(Canvas canvas, double size);

/// Ícone de demonstração: pode ser um logo solto em fundo transparente (como no
/// Windows/Linux, para o [LiquidGlassIcon] vestir com a placa de vidro) ou já
/// vir com a própria placa colorida (como ícones cheios do macOS/Android).
@immutable
class DemoIcon {
  /// Ícone com placa própria (fundo cheio em degradê + glifo ou arte por cima).
  const DemoIcon(
    this.glyph,
    this.background,
    this.foreground, {
    this.scale = 0.64,
    this.art,
  });

  /// Logo solto em fundo transparente: ganha a placa de vidro no [LiquidGlassIcon].
  const DemoIcon.transparent(
    this.glyph,
    this.foreground, {
    this.scale = 0.78,
    this.art,
  }) : background = null;

  /// Logo vetorial original em fundo transparente (sem placa embutida).
  const DemoIcon.custom(DemoArtPainter this.art)
    : glyph = null,
      background = null,
      foreground = const [],
      scale = 1;

  /// Placa colorida com arte vetorial original por cima (sem aro embutido: o aro
  /// e o brilho vêm do [LiquidGlassIcon]).
  const DemoIcon.platedCustom(List<Color> this.background, DemoArtPainter this.art)
    : glyph = null,
      foreground = const [],
      scale = 1;

  final IconData? glyph;

  /// Degradê da placa, de cima para baixo; nulo = fundo transparente (logo solto).
  final List<Color>? background;

  /// Degradê do glifo, de cima para baixo (uma cor só = liso).
  final List<Color> foreground;

  /// Lado do glifo em fração do ícone.
  final double scale;

  /// Pintor vetorial original opcional.
  final DemoArtPainter? art;
}

const _white = [Color(0xFFFFFFFF), Color(0xFFE5E6EC)];

/// Ícone de cada app da demonstração, pelo nome. Nome fora daqui ganha um genérico.
const Map<String, DemoIcon> kDemoIcons = {
  // Grade principal de demonstração: 7 logos transparentes + 1 exemplo com placa (Discord).
  'Opera': DemoIcon.custom(_paintRingOrb),
  'Chrome': DemoIcon.custom(_paintTriOrb),
  'Google Chrome': DemoIcon.custom(_paintTriOrb),
  'Discord': DemoIcon.platedCustom(
    [Color(0xFF7B87FF), Color(0xFF515DE2)],
    _paintMascotEmblem,
  ),
  'VS Code': DemoIcon.custom(_paintCodeRibbon),
  'Visual Studio Code': DemoIcon.custom(_paintCodeRibbon),
  'WhatsApp': DemoIcon.custom(_paintChatRing),
  'Claude': DemoIcon.custom(_paintSunburst),
  'ChatGPT': DemoIcon.custom(_paintHexKnot),
  'Music': DemoIcon.custom(_paintMusicNotes),
  // Biblioteca: mistura de logos transparentes e ícones com placa própria.
  'Activity Monitor': DemoIcon.transparent(
    CupertinoIcons.waveform_path_ecg,
    [Color(0xFF6BF0A0), Color(0xFF1FB866)],
  ),
  'AdGuard': DemoIcon(
    CupertinoIcons.checkmark_shield_fill,
    [Color(0xFF6DC98A), Color(0xFF2E8B57)],
    _white,
  ),
  'AirPort Utility': DemoIcon.transparent(
    CupertinoIcons.wifi,
    [Color(0xFF7CC4FF), Color(0xFF0A84FF)],
  ),
  'Antigravity': DemoIcon(
    CupertinoIcons.triangle_fill,
    [Color(0xFFFFFFFF), Color(0xFFE6E6EE)],
    [Color(0xFF5E9BFF), Color(0xFFB45EFF)],
    scale: 0.58,
  ),
  'App Store': DemoIcon(
    CupertinoIcons.app_badge_fill,
    [Color(0xFF3DB2FF), Color(0xFF0A64F0)],
    _white,
  ),
  'Audio MIDI Setup': DemoIcon.transparent(
    CupertinoIcons.music_note_list,
    _white,
  ),
  'Automator': DemoIcon(
    CupertinoIcons.gear_alt_fill,
    [Color(0xFFB4B4BC), Color(0xFF6E6E78)],
    _white,
  ),
  'Blender': DemoIcon(
    CupertinoIcons.cube_fill,
    [Color(0xFFFFA05A), Color(0xFFE8640F)],
    _white,
  ),
  'Bluetooth File Exchange': DemoIcon(
    CupertinoIcons.bluetooth,
    [Color(0xFF4FA8FF), Color(0xFF0A64F0)],
    _white,
  ),
  'Books': DemoIcon(
    CupertinoIcons.book_fill,
    [Color(0xFFFFB340), Color(0xFFFF7A00)],
    _white,
  ),
  'Calculator': DemoIcon.transparent(
    CupertinoIcons.plus_slash_minus,
    [Color(0xFFFFC45C), Color(0xFFFF9500)],
  ),
  'Calendar': DemoIcon(
    CupertinoIcons.calendar,
    [Color(0xFFFFFFFF), Color(0xFFEDEDF2)],
    [Color(0xFFFF5A50), Color(0xFFE5251B)],
  ),
  'CapCut': DemoIcon(
    CupertinoIcons.scissors,
    [Color(0xFF2A2A2C), Color(0xFF000000)],
    _white,
  ),
  'Chess': DemoIcon.transparent(CupertinoIcons.rosette, _white),
  'Clock': DemoIcon(
    CupertinoIcons.clock,
    [Color(0xFF2A2A2C), Color(0xFF000000)],
    _white,
    scale: 0.72,
  ),
  'Docker': DemoIcon(
    CupertinoIcons.cube_box_fill,
    [Color(0xFF5CB8FF), Color(0xFF1D7FD6)],
    _white,
  ),
  'Figma': DemoIcon.transparent(
    CupertinoIcons.paintbrush_fill,
    [Color(0xFFD08CFF), Color(0xFFA259FF)],
  ),
  'Finder': DemoIcon(
    CupertinoIcons.smiley_fill,
    [Color(0xFF6CC6FF), Color(0xFF1677F0)],
    _white,
    scale: 0.70,
  ),
  'FaceTime': DemoIcon(
    CupertinoIcons.videocam_fill,
    [Color(0xFF6BEB8A), Color(0xFF1FB84A)],
    _white,
  ),
  'Mail': DemoIcon(
    CupertinoIcons.envelope_fill,
    [Color(0xFF5CC0FF), Color(0xFF0A6CF0)],
    _white,
  ),
  'Maps': DemoIcon(
    CupertinoIcons.map_fill,
    [Color(0xFF8BE09A), Color(0xFF34A853)],
    _white,
  ),
  'Messages': DemoIcon(
    CupertinoIcons.chat_bubble_fill,
    [Color(0xFF6BEB8A), Color(0xFF1FB84A)],
    _white,
  ),
  'Notes': DemoIcon(
    CupertinoIcons.pencil,
    [Color(0xFFFFE680), Color(0xFFFFC800)],
    [Color(0xFF6E5A00), Color(0xFF4A3C00)],
  ),
  'OBS Studio': DemoIcon.transparent(
    CupertinoIcons.largecircle_fill_circle,
    _white,
  ),
  'Photos': DemoIcon(
    CupertinoIcons.sun_max_fill,
    [Color(0xFFFFFFFF), Color(0xFFEDEDF2)],
    [Color(0xFFFFB340), Color(0xFFFF3B80)],
    scale: 0.70,
  ),
  'Safari': DemoIcon(
    CupertinoIcons.compass,
    [Color(0xFF5CC0FF), Color(0xFF0A6CF0)],
    _white,
    scale: 0.72,
  ),
  'Slack': DemoIcon(
    CupertinoIcons.number,
    [Color(0xFF7A2A7D), Color(0xFF4A154B)],
    _white,
  ),
  'Spotify': DemoIcon.custom(_paintSoundOrb),
  'Steam': DemoIcon(
    CupertinoIcons.gamecontroller_fill,
    [Color(0xFF2A4A70), Color(0xFF111B2A)],
    _white,
  ),
  'System Settings': DemoIcon(
    CupertinoIcons.gear_alt_fill,
    [Color(0xFF9E9EA6), Color(0xFF5A5A62)],
    _white,
    scale: 0.70,
  ),
  'Terminal': DemoIcon.transparent(
    CupertinoIcons.chevron_right,
    [Color(0xFF6BF0A0), Color(0xFF1FB866)],
    scale: 0.64,
  ),
  'Xcode': DemoIcon(
    CupertinoIcons.hammer_fill,
    [Color(0xFF5CB8FF), Color(0xFF147EFB)],
    _white,
  ),
  'Zoom': DemoIcon(
    CupertinoIcons.videocam_fill,
    [Color(0xFF5CAEFF), Color(0xFF2D8CFF)],
    _white,
  ),
  'GitHub': DemoIcon.transparent(CupertinoIcons.arrow_branch, _white),
  'Postman': DemoIcon(
    CupertinoIcons.paperplane_fill,
    [Color(0xFFFF9A6B), Color(0xFFFF6C37)],
    _white,
  ),
};

/// O ícone de [name], ou um genérico com uma cor tirada do nome.
DemoIcon demoIconFor(String name) {
  final known = kDemoIcons[name];
  if (known != null) return known;
  const palette = [
    Color(0xFF0A84FF),
    Color(0xFFBF5AF2),
    Color(0xFFFF9F0A),
    Color(0xFF30D158),
    Color(0xFFFF375F),
    Color(0xFF64D2FF),
  ];
  final c = palette[name.hashCode.abs() % palette.length];
  return DemoIcon(
    CupertinoIcons.app_fill,
    [Color.lerp(c, Colors.white, 0.25)!, c],
    _white,
  );
}

final _png = <String, Future<Uint8List>>{};

/// PNG de [size] px do ícone de [name], desenhado uma vez por sessão.
Future<Uint8List> demoIconPng(String name, {int size = 256}) =>
    _png['$name@$size'] ??= _render(demoIconFor(name), size);

Future<Uint8List> _render(DemoIcon icon, int size) async {
  final s = size.toDouble();
  final rect = Offset.zero & Size(s, s);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, rect);

  final bg = icon.background;
  if (bg != null) {
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(s * 0.225),
    );
    final path = shape.getOuterPath(rect);
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: bg.length == 1 ? [bg.first, bg.first] : bg,
        ).createShader(rect),
    );
  }

  if (icon.art != null) {
    icon.art!(canvas, s);
  } else if (icon.glyph != null) {
    _paintGlyph(canvas, rect, s, icon, hasPlate: bg != null);
  }

  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void _paintGlyph(
  Canvas canvas,
  Rect rect,
  double s,
  DemoIcon icon, {
  required bool hasPlate,
}) {
  final glyph = icon.glyph!;
  final glyphSize = s * icon.scale;
  final glyphRect = Rect.fromCenter(
    center: rect.center,
    width: glyphSize,
    height: glyphSize,
  );
  final fg = icon.foreground.length == 1
      ? [icon.foreground.first, icon.foreground.first]
      : icon.foreground;
  final tp = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: String.fromCharCode(glyph.codePoint),
      style: TextStyle(
        fontFamily: glyph.fontFamily,
        package: glyph.fontPackage,
        fontSize: glyphSize,
        height: 1,
        foreground: Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: fg,
          ).createShader(glyphRect),
        shadows: hasPlate
            ? [
                Shadow(
                  color: const Color(0x45000000),
                  blurRadius: s * 0.04,
                  offset: Offset(0, s * 0.022),
                ),
              ]
            : null,
      ),
    ),
  )..layout();
  tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
  tp.dispose();
}

// ---- Desenhos vetoriais originais para a grade de demonstração ----

/// Anel oval vermelho brilhante com profundidade interna (estilo navegador).
void _paintRingOrb(Canvas canvas, double s) {
  final outer = Path()
    ..addOval(Rect.fromCenter(
      center: Offset(s * 0.5, s * 0.5),
      width: s * 0.78,
      height: s * 0.84,
    ));
  final inner = Path()
    ..addOval(Rect.fromCenter(
      center: Offset(s * 0.52, s * 0.5),
      width: s * 0.36,
      height: s * 0.54,
    ));
  final ring = Path.combine(PathOperation.difference, outer, inner);

  // Corpo principal com degradê carmesim vibrante.
  canvas.drawPath(
    ring,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFF5C5C), Color(0xFFFF1E2D), Color(0xFFB80A18)],
      ).createShader(Offset.zero & Size(s, s)),
  );

  // Crescente interna mais funda para sensação 3D.
  final shade = Path.combine(
    PathOperation.intersect,
    ring,
    Path()
      ..addOval(Rect.fromCenter(
        center: Offset(s * 0.59, s * 0.51),
        width: s * 0.62,
        height: s * 0.76,
      )),
  );
  canvas.drawPath(
    shade,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x5575000A), Color(0x18FF8585), Color(0x666E0008)],
      ).createShader(Offset.zero & Size(s, s)),
  );
}

/// Esfera tricolor com núcleo azul brilhante (círculo: 78,5% -> logo solto).
void _paintTriOrb(Canvas canvas, double s) {
  final c = Offset(s * 0.5, s * 0.5);
  final r = s * 0.42;
  final orb = Rect.fromCircle(center: c, radius: r);
  final clip = Path()..addOval(orb);

  canvas.save();
  canvas.clipPath(clip);

  // Três setores de 120° com degradês brilhantes (vermelho, amarelo, verde).
  const sectors = [
    (-150.0, 120.0, [Color(0xFFFF5E52), Color(0xFFDB3227)]),
    (-30.0, 120.0, [Color(0xFFFFDF4D), Color(0xFFF2AD00)]),
    (90.0, 120.0, [Color(0xFF4BE278), Color(0xFF1F9D45)]),
  ];
  for (final (startDeg, sweepDeg, colors) in sectors) {
    final start = startDeg * math.pi / 180;
    final sweep = sweepDeg * math.pi / 180;
    final wedge = Path()
      ..moveTo(c.dx, c.dy)
      ..arcTo(Rect.fromCircle(center: c, radius: r * 1.1), start, sweep, false)
      ..close();
    canvas.drawPath(
      wedge,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ).createShader(orb),
    );
  }
  canvas.restore();

  // Aro branco de separação e núcleo azul brilhante.
  canvas.drawCircle(c, r * 0.48, Paint()..color = const Color(0xFFF6F7FA));
  final coreRect = Rect.fromCircle(center: c, radius: r * 0.37);
  canvas.drawCircle(
    c,
    r * 0.37,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF5EB3FF), Color(0xFF1A73E8)],
      ).createShader(coreRect),
  );
}

/// Fita dobrada azul-celeste para editor de código.
void _paintCodeRibbon(Canvas canvas, double s) {
  final rect = Offset.zero & Size(s, s);
  final stroke = s * 0.13;

  // Braço diagonal superior esquerdo -> inferior direito (mais fundo).
  final armBack = Path()
    ..moveTo(s * 0.21, s * 0.34)
    ..lineTo(s * 0.72, s * 0.77);
  canvas.drawPath(
    armBack,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF1C87D8), Color(0xFF005FA8)],
      ).createShader(rect),
  );

  // Braço diagonal inferior esquerdo -> superior direito.
  final armFront = Path()
    ..moveTo(s * 0.21, s * 0.66)
    ..lineTo(s * 0.72, s * 0.23);
  canvas.drawPath(
    armFront,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = const LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [Color(0xFF1B8FE3), Color(0xFF4FC3FF)],
      ).createShader(rect),
  );

  // Barra lateral direita em relevo luminoso.
  final spine = Path()
    ..moveTo(s * 0.66, s * 0.19)
    ..lineTo(s * 0.81, s * 0.26)
    ..lineTo(s * 0.81, s * 0.74)
    ..lineTo(s * 0.66, s * 0.81)
    ..close();
  canvas.drawPath(
    spine,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF66D1FF), Color(0xFF2196F3)],
      ).createShader(rect),
  );
}

/// Balão verde brilhante com contorno limpo e fone estilizado no centro.
void _paintChatRing(Canvas canvas, double s) {
  final c = Offset(s * 0.51, s * 0.49);
  final r = s * 0.35;
  final rect = Offset.zero & Size(s, s);
  final green = Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFF47F57F), Color(0xFF11B84B)],
    ).createShader(rect);

  // Aro do balão com rabicho no canto inferior esquerdo.
  final bubble = Path()
    ..addArc(
      Rect.fromCircle(center: c, radius: r),
      2.62,
      2 * math.pi - 0.55,
    )
    ..lineTo(s * 0.15, s * 0.85)
    ..close();
  canvas.drawPath(
    bubble,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.085
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..shader = green.shader,
  );

  // Arco curvo representando o fone no centro.
  final phone = Path()
    ..moveTo(s * 0.38, s * 0.34)
    ..quadraticBezierTo(s * 0.34, s * 0.57, s * 0.62, s * 0.64);
  canvas.drawPath(
    phone,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.105
      ..strokeCap = StrokeCap.round
      ..shader = green.shader,
  );
}

/// Estrela radial coral com raios orgânicos (estilo assistente).
void _paintSunburst(Canvas canvas, double s) {
  final c = Offset(s * 0.5, s * 0.5);
  final rect = Offset.zero & Size(s, s);
  final paint = Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFF79C70), Color(0xFFD9643A)],
    ).createShader(rect);

  // 11 raios com comprimentos ligeiramente variados.
  const rays = [
    (-90.0, 0.41, 0.068),
    (-56.0, 0.36, 0.062),
    (-24.0, 0.40, 0.066),
    (8.0, 0.35, 0.060),
    (38.0, 0.39, 0.065),
    (70.0, 0.38, 0.064),
    (102.0, 0.40, 0.066),
    (134.0, 0.36, 0.062),
    (166.0, 0.39, 0.064),
    (198.0, 0.35, 0.060),
    (232.0, 0.38, 0.064),
  ];
  for (final (deg, len, width) in rays) {
    final rad = deg * math.pi / 180;
    final tip = c + Offset(math.cos(rad) * s * len, math.sin(rad) * s * len);
    canvas.drawLine(
      c,
      tip,
      Paint()
        ..shader = paint.shader
        ..strokeWidth = s * width
        ..strokeCap = StrokeCap.round,
    );
  }
  canvas.drawCircle(c, s * 0.125, paint);
}

/// Roseta hexagonal entrelaçada branco-pérola.
void _paintHexKnot(Canvas canvas, double s) {
  final c = Offset(s * 0.5, s * 0.5);
  final rect = Offset.zero & Size(s, s);
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = s * 0.068
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round
    ..shader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFFFFFFF), Color(0xFFC2C4CC)],
    ).createShader(rect);

  for (var i = 0; i < 6; i++) {
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(i * math.pi / 3);
    final loop = RRect.fromRectAndRadius(
      Rect.fromLTWH(-s * 0.11, -s * 0.39, s * 0.27, s * 0.36),
      Radius.circular(s * 0.135),
    );
    canvas.drawRRect(loop, stroke);
    canvas.restore();
  }
}

/// Colcheia dupla rosa-carmesim brilhante.
void _paintMusicNotes(Canvas canvas, double s) {
  final rect = Offset.zero & Size(s, s);
  final paint = Paint()
    ..shader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFFF5284), Color(0xFFFA1738)],
    ).createShader(rect);

  // Barra superior inclinada ligando as duas hastes.
  final beam = Path()
    ..moveTo(s * 0.38, s * 0.24)
    ..lineTo(s * 0.78, s * 0.15)
    ..lineTo(s * 0.78, s * 0.31)
    ..lineTo(s * 0.38, s * 0.40)
    ..close();
  canvas.drawPath(beam, paint);

  // Duas hastes verticais.
  final stemW = s * 0.095;
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.38, s * 0.24, stemW, s * 0.50),
      Radius.circular(stemW * 0.3),
    ),
    paint,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(s * 0.78 - stemW, s * 0.15, stemW, s * 0.52),
      Radius.circular(stemW * 0.3),
    ),
    paint,
  );

  // Duas cabeças de nota inclinadas.
  void head(double cx, double cy) {
    canvas.save();
    canvas.translate(s * cx, s * cy);
    canvas.rotate(-0.28);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: s * 0.25, height: s * 0.19),
      paint,
    );
    canvas.restore();
  }

  head(0.34, 0.76);
  head(0.66, 0.68);
}

/// Emblema branco amigável sobre placa azul-violeta (exemplo de ícone com placa).
void _paintMascotEmblem(Canvas canvas, double s) {
  final body = Path()
    ..moveTo(s * 0.30, s * 0.31)
    ..quadraticBezierTo(s * 0.50, s * 0.26, s * 0.70, s * 0.31)
    ..quadraticBezierTo(s * 0.81, s * 0.45, s * 0.80, s * 0.64)
    ..quadraticBezierTo(s * 0.71, s * 0.72, s * 0.62, s * 0.73)
    ..lineTo(s * 0.57, s * 0.66)
    ..quadraticBezierTo(s * 0.50, s * 0.68, s * 0.43, s * 0.66)
    ..lineTo(s * 0.38, s * 0.73)
    ..quadraticBezierTo(s * 0.29, s * 0.72, s * 0.20, s * 0.64)
    ..quadraticBezierTo(s * 0.19, s * 0.45, s * 0.30, s * 0.31)
    ..close();

  // Sombra macia do emblema sobre a placa colorida.
  canvas.drawPath(
    body.shift(Offset(0, s * 0.032)),
    Paint()
      ..color = const Color(0x40000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.035),
  );

  // Corpo branco com leve profundidade na base.
  canvas.drawPath(
    body,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFFFFFF), Color(0xFFE8EAFF)],
      ).createShader(Offset.zero & Size(s, s)),
  );

  // Olhos vazados na cor da placa.
  final eyePaint = Paint()..color = const Color(0xFF5A66E8);
  canvas.drawOval(
    Rect.fromCenter(center: Offset(s * 0.40, s * 0.52), width: s * 0.125, height: s * 0.145),
    eyePaint,
  );
  canvas.drawOval(
    Rect.fromCenter(center: Offset(s * 0.60, s * 0.52), width: s * 0.125, height: s * 0.145),
    eyePaint,
  );
}

/// Esfera verde com ondas sonoras vazadas (círculo: 78,5% -> logo solto).
void _paintSoundOrb(Canvas canvas, double s) {
  final c = Offset(s * 0.5, s * 0.5);
  final r = s * 0.41;
  final rect = Rect.fromCircle(center: c, radius: r);
  canvas.saveLayer(rect.inflate(4), Paint());
  canvas.drawCircle(
    c,
    r,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF4BEE81), Color(0xFF1DB954)],
      ).createShader(rect),
  );
  final cut = Paint()
    ..blendMode = BlendMode.clear
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  for (final (dy, arcR, span, w) in [
    (0.11, 0.36, 0.92, 0.072),
    (0.19, 0.29, 0.86, 0.062),
    (0.26, 0.22, 0.80, 0.052),
  ]) {
    canvas.drawArc(
      Rect.fromCircle(center: Offset(c.dx, c.dy + s * dy), radius: s * arcR),
      -math.pi / 2 - span / 2,
      span,
      false,
      cut..strokeWidth = s * w,
    );
  }
  canvas.restore();
}
