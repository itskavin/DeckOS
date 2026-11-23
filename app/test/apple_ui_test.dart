import 'package:deckos/core/core.dart';
import 'package:deckos/core/ui/apple_ui.dart';
import 'package:flutter/gestures.dart' show kPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// O app com o tema padrão (o da Apple), escuro.
Widget _app(Widget child) => MaterialApp(
  theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  test('o tema padrão usa superfícies neutras modernas e preserva o visual das teclas do deck', () {
    const s = ThemeSettings();
    expect(s.presetId, kApplePresetId);
    expect(presetById('nao-existe').id, kApplePresetId);
    final t = buildAppTheme(s, Brightness.dark);
    final deckDark = t.extension<DeckTheme>()!;
    expect(deckDark.tileStyle, DeckTileStyle.squircle);
    // Aparência das teclas do deck preservada exatamente.
    expect(deckDark.background, const Color(0xFF000000));
    expect(deckDark.tileColor, const Color(0xFF141415));
    expect(t.colorScheme.primary, AppleSystemColors.blueDark);
    expect(t.scaffoldBackgroundColor, const Color(0xFF09090B));
    // No claro, superfícies neutras claras e deck claro preservado.
    final light = buildAppTheme(s, Brightness.light);
    final deckLight = light.extension<DeckTheme>()!;
    expect(light.colorScheme.primary, AppleSystemColors.blueLight);
    expect(light.scaffoldBackgroundColor, const Color(0xFFFAFAFA));
    expect(deckLight.background, const Color(0xFFF2F2F7));
    expect(deckLight.tileColor, Colors.white);
  });

  test('cores dentro das teclas ficam nos tons originais mesmo com o tema moderno', () {
    // As telas usam a paleta nova; medidores, timer e paleta de cor de tecla não mudam.
    expect(DeckTileColors.blue, const Color(0xFF0A84FF));
    expect(DeckTileColors.green, const Color(0xFF30D158));
    expect(DeckTileColors.orange, const Color(0xFFFF9F0A));
    expect(DeckTileColors.red, const Color(0xFFFF453A));
    expect(DeckTileColors.yellow, const Color(0xFFFFD60A));
    expect(AppleSystemColors.blueDark, isNot(DeckTileColors.blue));
  });

  test('os temas antigos continuam com o estilo de botão deles', () {
    final t = buildAppTheme(
      const ThemeSettings(presetId: 'neon'),
      Brightness.dark,
    );
    expect(t.extension<DeckTheme>()!.tileStyle, DeckTileStyle.frame);
    expect(
      t.extension<AppleColors>()!.groupedBackground,
      const Color(0xFF0B1020),
    );
  });

  group('DeckSquircleTile', () {
    testWidgets('mostra ícone e rótulo, e afunda ao toque', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app(
          SizedBox.square(
            dimension: 100,
            child: DeckSquircleTile(
              icon: Icons.mic,
              label: 'Mic',
              onTap: () => taps++,
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.text('Mic'), findsOneWidget);

      double scale() =>
          tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
      expect(scale(), 1);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(DeckSquircleTile)),
      );
      // O toque só "pega" depois do tempo de toque (kPressTimeout).
      await tester.pump(kPressTimeout);
      await tester.pump();
      expect(scale(), lessThan(1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scale(), 1);
      expect(taps, 1);
    });

    ShapeDecoration tileDeco(WidgetTester tester) {
      final box = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byType(DeckSquircleTile),
          matching: find.byType(AnimatedContainer),
        ),
      );
      return box.decoration! as ShapeDecoration;
    }

    testWidgets('a cor do botão vai só no glifo: a tecla é a mesma de sempre', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const SizedBox.square(
            dimension: 100,
            child: DeckSquircleTile(
              icon: Icons.mic,
              color: Color(0xFF5865F2),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final deck = DeckTheme.of(tester.element(find.byType(DeckSquircleTile)));
      final deco = tileDeco(tester);
      expect(deco.gradient!.colors.last, deck.tileColor);
      expect(deco.shape, isA<RoundedSuperellipseBorder>());
      final glyph = tester.widget<RichText>(
        find.descendant(of: find.byIcon(Icons.mic), matching: find.byType(RichText)),
      );
      final color = glyph.text.style!.color!;
      expect(color, isNot(deck.foreground));
      expect(HSLColor.fromColor(color).hue, closeTo(HSLColor.fromColor(const Color(0xFF5865F2)).hue, 2));
    });

    testWidgets('ativa, ganha um véu e o glifo na cor de ligado (sem pintar tudo)', (
      tester,
    ) async {
      const on = Color(0xFFFF453A);
      await tester.pumpWidget(
        _app(
          const SizedBox.square(
            dimension: 100,
            child: DeckSquircleTile(
              icon: Icons.mic_off,
              active: true,
              activeColor: on,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final deck = DeckTheme.of(tester.element(find.byType(DeckSquircleTile)));
      final fill = tileDeco(tester).gradient!.colors.last;
      expect(fill, isNot(on));
      expect(fill, isNot(deck.tileColor));
      expect(fill.r, greaterThan(fill.g));
      final glyph = tester.widget<RichText>(
        find.descendant(of: find.byIcon(Icons.mic_off), matching: find.byType(RichText)),
      );
      // A cor de ligado, só clareada o bastante para ler sobre o grafite.
      final fg = HSLColor.fromColor(glyph.text.style!.color!);
      expect(fg.hue, closeTo(HSLColor.fromColor(on).hue, 2));
      expect(fg.lightness, greaterThanOrEqualTo(HSLColor.fromColor(on).lightness));
    });

    testWidgets('DeckTile usa a tecla squircle no tema padrão', (tester) async {
      await tester.pumpWidget(
        _app(
          SizedBox.square(
            dimension: 100,
            child: DeckTile(onTap: () {}, child: const Icon(Icons.bolt)),
          ),
        ),
      );
      expect(find.byType(DeckSquircleTile), findsOneWidget);
    });
  });

  group('PageDots', () {
    testWidgets('a página atual vira cápsula larga', (tester) async {
      int? tapped;
      await tester.pumpWidget(
        _app(PageDots(count: 3, index: 1, onTap: (i) => tapped = i)),
      );
      await tester.pumpAndSettle();
      double width(int i) =>
          tester.getSize(find.byKey(ValueKey('page-dot-$i'))).width;
      expect(width(1), 18);
      expect(width(0), 6);
      expect(width(2), 6);

      await tester.tap(find.byKey(const ValueKey('page-dot-2')));
      expect(tapped, 2);
    });

    testWidgets('troca de página anima a cápsula', (tester) async {
      Widget dots(int i) => _app(PageDots(count: 3, index: i));
      await tester.pumpWidget(dots(0));
      await tester.pumpAndSettle();
      await tester.pumpWidget(dots(2));
      await tester.pump(const Duration(milliseconds: 60));
      final mid = tester
          .getSize(find.byKey(const ValueKey('page-dot-2')))
          .width;
      expect(mid, greaterThan(6));
      expect(mid, lessThan(18));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('page-dot-2'))).width,
        18,
      );
    });

    testWidgets('com uma página só, não aparece', (tester) async {
      await tester.pumpWidget(_app(const PageDots(count: 1, index: 0)));
      expect(find.byKey(const ValueKey('page-dot-0')), findsNothing);
    });
  });

  test('a mola começa em 0 e termina em 1', () {
    for (final curve in [
      AppleMotion.smooth,
      AppleMotion.snappy,
      AppleMotion.bouncy,
    ]) {
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      expect(curve.transform(0.5), greaterThan(0.5));
    }
  });
}
