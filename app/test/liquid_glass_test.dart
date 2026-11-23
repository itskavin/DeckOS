import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:deckos/core/core.dart';
import 'package:deckos/core/deckos_client/demo/demo_icons.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/layout/app_icon.dart';
import 'package:deckos/src/stream_deck/widgets/deck_grid_button.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

/// Cria um buffer RGBA preenchido pela função [pixel], que devolve `(r, g, b, a)`.
Uint8List _rgba(
  int w,
  int h,
  (int, int, int, int) Function(int x, int y) pixel,
) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (r, g, b, a) = pixel(x, y);
      final i = (y * w + x) * 4;
      out[i] = r;
      out[i + 1] = g;
      out[i + 2] = b;
      out[i + 3] = a;
    }
  }
  return out;
}

/// Gera um PNG em memória desenhando com [paint] numa tela `size × size`.
Future<Uint8List> _png(int size, void Function(Canvas, double) paint) async {
  final s = size.toDouble();
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Offset.zero & Size(s, s));
  paint(canvas, s);
  final img = await rec.endRecording().toImage(size, size);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

/// [ImageProvider] que sempre falha ao carregar, para testar fallback de erro.
class _FailingProvider extends ImageProvider<_FailingProvider> {
  const _FailingProvider();

  @override
  Future<_FailingProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _FailingProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    Future<ImageInfo>.error(Exception('falha simulada')),
  );
}

/// Cliente falso que devolve bytes fixos para testar [AppIconView].
class _FakeIconClient extends DeckOSClient {
  _FakeIconClient(this.bytes) : super(baseUrl: 'http://localhost');

  final Uint8List? bytes;

  @override
  Future<Uint8List?> getAppIcon(InstalledApp app) async => bytes;
}

Widget _app(
  Widget child, {
  Brightness brightness = Brightness.dark,
  ThemeSettings settings = const ThemeSettings(),
}) => MaterialApp(
  themeAnimationDuration: Duration.zero,
  theme: buildAppTheme(settings, brightness),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  setUp(() {
    LiquidGlassCache.clear();
  });

  group('classifyIconPixels', () {
    test('entrada vazia, inválida ou totalmente transparente cai em glyph vazio', () {
      expect(classifyIconPixels(Uint8List(0), 0, 0), LiquidGlassShape.empty);
      expect(classifyIconPixels(Uint8List(10), 4, 4), LiquidGlassShape.empty);
      final blank = Uint8List(32 * 32 * 4);
      expect(classifyIconPixels(blank, 32, 32), LiquidGlassShape.empty);
    });

    test('imagem quadrada cheia (cantos opacos) vira plated', () {
      final solid = _rgba(64, 64, (_, _) => (90, 100, 240, 255));
      final shape = classifyIconPixels(solid, 64, 64);
      expect(shape.kind, LiquidGlassKind.plated);
      expect(shape.content.width, closeTo(1.0, 0.05));
      expect(shape.content.height, closeTo(1.0, 0.05));
    });

    test('imagem retangular muito estreita cheia não estoura índice e vira plated', () {
      final wide = _rgba(200, 4, (_, _) => (255, 255, 255, 255));
      final tall = _rgba(4, 200, (_, _) => (255, 255, 255, 255));
      expect(classifyIconPixels(wide, 200, 4).kind, LiquidGlassKind.plated);
      expect(classifyIconPixels(tall, 4, 200).kind, LiquidGlassKind.plated);
    });

    test('placa squircle com margem transparente (estilo macOS) vira plated e recorta a margem', () {
      // Quadrado opaco com cantos levemente arredondados e 12,5% de respiro em volta.
      final macPlate = _rgba(80, 80, (x, y) {
        if (x < 10 || x >= 70 || y < 10 || y >= 70) return (0, 0, 0, 0);
        // Corta os cantinhos extremos como um squircle.
        final dx = math.min(x - 10, 69 - x);
        final dy = math.min(y - 10, 69 - y);
        if (dx + dy < 6) return (0, 0, 0, 0);
        return (110, 120, 250, 255);
      });
      final shape = classifyIconPixels(macPlate, 80, 80);
      expect(shape.kind, LiquidGlassKind.plated);
      expect(shape.content.left, closeTo(10 / 80, 0.03));
      expect(shape.content.top, closeTo(10 / 80, 0.03));
      expect(shape.content.width, closeTo(60 / 80, 0.04));
    });

    test('logo circular em fundo transparente (78,5% da caixa) continua glyph', () {
      final circle = _rgba(96, 96, (x, y) {
        final dx = x - 47.5, dy = y - 47.5;
        return dx * dx + dy * dy <= 40 * 40
            ? (230, 50, 50, 255)
            : (0, 0, 0, 0);
      });
      final shape = classifyIconPixels(circle, 96, 96);
      expect(shape.kind, LiquidGlassKind.glyph);
    });

    test('logo vazado em anel sobre fundo transparente vira glyph com caixa justa', () {
      final ring = _rgba(96, 96, (x, y) {
        final dx = x - 47.5, dy = y - 47.5;
        final d2 = dx * dx + dy * dy;
        return d2 <= 36 * 36 && d2 >= 20 * 20
            ? (255, 40, 40, 255)
            : (0, 0, 0, 0);
      });
      final shape = classifyIconPixels(ring, 96, 96);
      expect(shape.kind, LiquidGlassKind.glyph);
      expect(shape.content.left, greaterThan(0.08));
      expect(shape.content.right, lessThan(0.92));
    });

    test('logos transparentes e placas do demo são classificados corretamente', () async {
      for (final transparent in [
        'Opera',
        'Chrome',
        'VS Code',
        'WhatsApp',
        'Claude',
        'ChatGPT',
        'Music',
        'Spotify',
      ]) {
        final bytes = await demoIconPng(transparent, size: 128);
        final art = await LiquidGlassCache.ofBytes(bytes);
        expect(art, isNotNull, reason: transparent);
        expect(art!.shape.kind, LiquidGlassKind.glyph, reason: transparent);
      }

      for (final plated in ['Discord', 'Finder', 'Safari']) {
        final bytes = await demoIconPng(plated, size: 128);
        final art = await LiquidGlassCache.ofBytes(bytes);
        expect(art, isNotNull, reason: plated);
        expect(art!.shape.kind, LiquidGlassKind.plated, reason: plated);
      }
    });
  });

  group('LiquidGlassCache', () {
    test('deduplica bytes iguais e compartilha entrada com MemoryImage', () async {
      final pngA = await _png(48, (c, s) {
        c.drawCircle(Offset(s / 2, s / 2), s * 0.35, Paint()..color = Colors.red);
      });
      final pngCopy = Uint8List.fromList(pngA);

      expect(LiquidGlassCache.keyOf(pngA), LiquidGlassCache.keyOf(pngCopy));
      expect(
        LiquidGlassCache.keyOfProvider(MemoryImage(pngCopy)),
        LiquidGlassCache.keyOf(pngA),
      );

      final art1 = await LiquidGlassCache.ofBytes(pngA);
      final art2 = await LiquidGlassCache.ofProvider(MemoryImage(pngCopy));
      expect(art1, isNotNull);
      expect(identical(art1, art2), isTrue);
      expect(LiquidGlassCache.cachedCount, 1);
    });

    test('respeita limite de capacidade LRU e não cresce sem fim', () async {
      for (var i = 0; i < LiquidGlassCache.capacity + 25; i++) {
        final broken = Uint8List.fromList([i & 0xFF, (i >> 8) & 0xFF, 0xDE, 0xAD]);
        final art = await LiquidGlassCache.ofBytes(broken);
        expect(art, isNull);
      }
      expect(LiquidGlassCache.cachedCount, LiquidGlassCache.capacity);
    });

    test('decodeBase64 remove prefixo data URI e trata base64 inválido', () {
      final raw = Uint8List.fromList([1, 2, 3, 4]);
      final uri = 'data:image/png;base64,${base64Encode(raw)}';
      final a = LiquidGlassCache.decodeBase64(uri);
      final b = LiquidGlassCache.decodeBase64(uri);
      expect(a, raw);
      expect(identical(a, b), isTrue);
      expect(LiquidGlassCache.decodeBase64('@@@nao-e-base64@@@'), isNull);
    });
  });

  group('LiquidGlassIcon e integrações', () {
    testWidgets('logo transparente renderiza glyph com RepaintBoundary e detalhe', (tester) async {
      late Uint8List glyphPng;
      await tester.runAsync(() async {
        glyphPng = await _png(64, (c, s) {
          c.drawCircle(Offset(s / 2, s / 2), s * 0.35, Paint()..color = Colors.orange);
        });
        await LiquidGlassCache.ofBytes(glyphPng);
      });

      await tester.pumpWidget(
        _app(LiquidGlassIcon.memory(glyphPng, size: 72)),
      );
      await tester.pump();

      final customPaint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(LiquidGlassIcon),
          matching: find.byType(CustomPaint),
        ),
      );
      final painter = customPaint.painter! as LiquidGlassPainter;
      expect(painter.art.shape.kind, LiquidGlassKind.glyph);
      expect(painter.detailed, isTrue);
      expect(painter.dark, isTrue);
      expect(
        find.descendant(
          of: find.byType(LiquidGlassIcon),
          matching: find.byType(RepaintBoundary),
        ),
        findsOneWidget,
      );
    });

    testWidgets('ícone com placa própria renderiza como plated (sem placa dobrada)', (tester) async {
      late Uint8List platedPng;
      await tester.runAsync(() async {
        platedPng = await _png(64, (c, s) {
          c.drawRect(Offset.zero & Size(s, s), Paint()..color = Colors.indigo);
        });
        await LiquidGlassCache.ofBytes(platedPng);
      });

      await tester.pumpWidget(
        _app(LiquidGlassIcon.memory(platedPng, size: 72)),
      );
      await tester.pump();

      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(LiquidGlassIcon),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter! as LiquidGlassPainter;
      expect(painter.art.shape.kind, LiquidGlassKind.plated);
      expect(painter.detailed, isTrue);
    });

    testWidgets('ícone miúdo (< 28 px) desliga aro e sombras (modo simplificado)', (tester) async {
      late Uint8List glyphPng;
      await tester.runAsync(() async {
        glyphPng = await _png(48, (c, s) {
          c.drawCircle(Offset(s / 2, s / 2), s * 0.35, Paint()..color = Colors.green);
        });
        await LiquidGlassCache.ofBytes(glyphPng);
      });

      await tester.pumpWidget(
        _app(LiquidGlassIcon.memory(glyphPng, size: 24)),
      );
      await tester.pump();

      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(LiquidGlassIcon),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter! as LiquidGlassPainter;
      expect(painter.detailed, isFalse);
    });

    testWidgets('tema claro passa dark=false ao LiquidGlassPainter', (tester) async {
      late Uint8List glyphPng;
      await tester.runAsync(() async {
        glyphPng = await _png(48, (c, s) {
          c.drawCircle(Offset(s / 2, s / 2), s * 0.35, Paint()..color = Colors.blue);
        });
        await LiquidGlassCache.ofBytes(glyphPng);
      });

      await tester.pumpWidget(
        _app(
          LiquidGlassIcon.memory(glyphPng, size: 64),
          brightness: Brightness.light,
        ),
      );
      await tester.pump();

      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(LiquidGlassIcon),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter! as LiquidGlassPainter;
      expect(painter.dark, isFalse);
    });

    testWidgets('bytes corrompidos e ImageProvider com erro chamam errorBuilder', (tester) async {
      final corrupt = Uint8List.fromList([0, 1, 2, 3, 4]);
      await tester.runAsync(() async {
        await LiquidGlassCache.ofBytes(corrupt);
      });

      await tester.pumpWidget(
        _app(
          LiquidGlassIcon.memory(
            corrupt,
            size: 64,
            errorBuilder: (_) => const Icon(Icons.broken_image),
          ),
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.broken_image), findsOneWidget);

      await tester.pumpWidget(
        _app(
          LiquidGlassIcon(
            image: const _FailingProvider(),
            size: 64,
            errorBuilder: (_) => const Icon(Icons.error_outline),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('toque no DeckSquircleTile pressiona a placa (press -> 1)', (tester) async {
      late Uint8List glyphPng;
      await tester.runAsync(() async {
        glyphPng = await _png(48, (c, s) {
          c.drawCircle(Offset(s / 2, s / 2), s * 0.35, Paint()..color = Colors.pink);
        });
        await LiquidGlassCache.ofBytes(glyphPng);
      });

      await tester.pumpWidget(
        _app(
          SizedBox.square(
            dimension: 110,
            child: DeckSquircleTile(
              image: MemoryImage(glyphPng),
              onTap: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      LiquidGlassPainter currentPainter() => tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(LiquidGlassIcon),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter! as LiquidGlassPainter;

      expect(currentPainter().press, 0);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(DeckSquircleTile)),
      );
      await tester.pump(kPressTimeout);
      await tester.pump(const Duration(milliseconds: 200));
      expect(currentPainter().press, closeTo(1.0, 0.05));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(currentPainter().press, 0);
    });

    testWidgets('ButtonLook usa LiquidGlass no squircle e preserva estilos legados', (tester) async {
      GetIt.I.registerSingleton<SignalRService>(SignalRService());
      addTearDown(GetIt.I.reset);

      late String b64;
      await tester.runAsync(() async {
        final png = await _png(48, (c, s) {
          c.drawCircle(Offset(s / 2, s / 2), s * 0.35, Paint()..color = Colors.teal);
        });
        await LiquidGlassCache.ofBytes(png);
        b64 = base64Encode(png);
      });

      final imageBtn = DeckButton(
        id: 'img',
        row: 0,
        column: 0,
        label: 'App',
        iconBase64: b64,
        action: DeckAction(type: 'launch_app'),
      );
      final glyphBtn = DeckButton(
        id: 'sys',
        row: 0,
        column: 1,
        label: 'Mic',
        iconName: 'mic',
        action: DeckAction(type: 'hotkey'),
      );

      // Estilo padrão (squircle): imagem usa LiquidGlassIcon; glifo usa LiquidGlassGlyph.
      await tester.pumpWidget(
        _app(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 110,
                child: DeckGridButton(button: imageBtn, onTap: () {}, onLongPress: () {}),
              ),
              SizedBox.square(
                dimension: 110,
                child: DeckGridButton(button: glyphBtn, onTap: () {}, onLongPress: () {}),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(LiquidGlassIcon), findsOneWidget);
      expect(find.byType(LiquidGlassGlyph), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.mic_fill), findsOneWidget);

      // Estilos legados (sólido, contorno, moldura): sem LiquidGlassIcon nem LiquidGlassGlyph.
      for (final preset in ['classico', 'oled', 'neon']) {
        await tester.pumpWidget(
          _app(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 110,
                  child: DeckGridButton(button: imageBtn, onTap: () {}, onLongPress: () {}),
                ),
                SizedBox.square(
                  dimension: 110,
                  child: DeckGridButton(button: glyphBtn, onTap: () {}, onLongPress: () {}),
                ),
              ],
            ),
            settings: ThemeSettings(presetId: preset),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(LiquidGlassIcon), findsNothing, reason: preset);
        expect(find.byType(LiquidGlassGlyph), findsNothing, reason: preset);
      }
    });

    testWidgets('LiquidGlassGlyph simplifica abaixo de 28 px', (tester) async {
      await tester.pumpWidget(
        _app(
          const IconTheme(
            data: IconThemeData(size: 20),
            child: LiquidGlassGlyph(child: Icon(CupertinoIcons.mic_fill)),
          ),
        ),
      );
      expect(find.byType(ShaderMask), findsNothing);

      await tester.pumpWidget(
        _app(
          const IconTheme(
            data: IconThemeData(size: 40),
            child: LiquidGlassGlyph(child: Icon(CupertinoIcons.mic_fill)),
          ),
        ),
      );
      expect(find.byType(ShaderMask), findsOneWidget);
    });

    testWidgets('AppIconView usa LiquidGlassIcon e cai no MonogramIcon em erro', (tester) async {
      late Uint8List validPng;
      await tester.runAsync(() async {
        validPng = await _png(48, (c, s) {
          c.drawCircle(Offset(s / 2, s / 2), s * 0.35, Paint()..color = Colors.amber);
        });
        await LiquidGlassCache.ofBytes(validPng);
      });

      GetIt.I.registerSingleton<DeckOSClient>(_FakeIconClient(validPng));
      addTearDown(GetIt.I.reset);

      const appOk = InstalledApp(id: 'app-ok-test', name: 'Opera', path: '/opera');
      await tester.pumpWidget(
        _app(
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconView(app: appOk, size: 50),
              AppIconView(app: appOk, size: 26),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final painters = tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byType(LiquidGlassIcon),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((w) => w.painter! as LiquidGlassPainter)
          .toList();
      expect(painters, hasLength(2));
      expect(painters[0].detailed, isTrue);
      expect(painters[1].detailed, isFalse);

      // Bytes inválidos -> fallback MonogramIcon.
      await GetIt.I.reset();
      final badBytes = Uint8List.fromList([9, 8, 7, 6]);
      await tester.runAsync(() async {
        await LiquidGlassCache.ofBytes(badBytes);
      });
      GetIt.I.registerSingleton<DeckOSClient>(_FakeIconClient(badBytes));
      const appBad = InstalledApp(id: 'app-bad-test', name: 'Broken', path: '/broken');
      await tester.pumpWidget(_app(const AppIconView(app: appBad, size: 50)));
      await tester.pumpAndSettle();
      expect(find.byType(MonogramIcon), findsOneWidget);
    });
  });
}
