import 'package:deckos/src/stream_deck/stream_deck_page.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Telas em dp e a área que sobra para a grade (área segura, respiro e pontinhos).
  const iphoneLand = Size(932, 430), iphoneArea = Size(798, 365);
  const iphonePort = Size(430, 932), iphonePortArea = Size(414, 790);
  const pixelLand = Size(915, 412), pixelArea = Size(867, 360);

  group('celular deitado', () {
    test('teclas grandes: 4×2, como nos prints do PhoneDeck', () {
      final g = DeckGridFit.compute(area: iphoneArea, screen: iphoneLand);
      expect((g.cols, g.rows), (4, 2));
      expect(g.reflow, isFalse);
      expect(g.cell, greaterThan(140));
      expect((g.deckCols, g.deckRows), (4, 2));

      final p = DeckGridFit.compute(area: pixelArea, screen: pixelLand);
      expect((p.cols, p.rows), (4, 2));
    });

    test('a grade cabe na área', () {
      for (final (area, screen) in [(iphoneArea, iphoneLand), (pixelArea, pixelLand)]) {
        final g = DeckGridFit.compute(area: area, screen: screen);
        expect(g.cols * g.cell + (g.cols - 1) * g.spacing, lessThanOrEqualTo(area.width + 0.01));
        expect(g.rows * g.cell + (g.rows - 1) * g.spacing, lessThanOrEqualTo(area.height + 0.01));
      }
    });

    test('nunca esconde botões que já existem (deck antigo de 8×3)', () {
      final g = DeckGridFit.compute(
          area: iphoneArea, screen: iphoneLand, minCols: 8, minRows: 3);
      expect((g.cols, g.rows), (8, 3));
      expect(g.cell, greaterThanOrEqualTo(DeckGridFit.minCell));
    });
  });

  group('celular em pé', () {
    test('a grade do deck é a mesma (girar não muda o PC) e os botões são reorganizados', () {
      final land = DeckGridFit.compute(area: iphoneArea, screen: iphoneLand);
      final port = DeckGridFit.compute(area: iphonePortArea, screen: iphonePort);
      expect((port.deckCols, port.deckRows), (land.deckCols, land.deckRows));
      expect(port.reflow, isTrue);
      // 4×2 deitado vira 2 colunas em pé.
      expect(port.cols, 2);
      expect(port.cell, greaterThan(150));
    });

    test('deck grande vira 3 colunas, com fileiras que cabem na altura', () {
      final g = DeckGridFit.compute(
          area: iphonePortArea, screen: iphonePort, minCols: 8, minRows: 3);
      expect(g.reflow, isTrue);
      expect(g.cols, 3);
      expect(g.rows, greaterThanOrEqualTo(5));
      expect(g.rows * g.cell + (g.rows - 1) * g.spacing, lessThanOrEqualTo(iphonePortArea.height));
    });

    test('a tecla encolhe para caber sem rolar enquanto for boa de tocar', () {
      final g = DeckGridFit.compute(area: iphonePortArea, screen: iphonePort);
      final four = g.cellFor(4);
      expect(4 * four + 3 * g.spacing, lessThanOrEqualTo(iphonePortArea.height + 0.01));
      // Fileiras demais: mantém a tecla e a página rola.
      expect(g.cellFor(40), g.cell);
    });

    test('no modo de edição a grade é a do deck, sem reorganizar', () {
      final g = DeckGridFit.compute(
          area: iphonePortArea, screen: iphonePort, allowReflow: false);
      expect(g.reflow, isFalse);
      expect((g.cols, g.rows), (g.deckCols, g.deckRows));
    });
  });

  test('deck no navegador usa a grade do celular quando ela cabe', () {
    final g = DeckGridFit.compute(
      area: const Size(1200, 700),
      screen: const Size(1280, 800),
      shared: {'columns': 5, 'rows': 3},
    );
    expect((g.cols, g.rows, g.reflow), (5, 3, false));
  });
}
