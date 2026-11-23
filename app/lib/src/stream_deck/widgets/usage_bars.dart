import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

import 'info_deck_button.dart' show usageColor;

/// Uma medida em barra: nome à esquerda, valor à direita e a barra embaixo.
class UsageRow {
  final String name;
  final double percent;

  /// Texto à direita; sem ele, a porcentagem.
  final String? value;

  /// Cor do valor (a rede usa verde para ↓ e azul para ↑).
  final Color? valueColor;

  /// Linha extra embaixo da barra, só em botão alto (ex.: "120 GB livres").
  final String? detail;

  /// Sem barra: medida que não é porcentagem (velocidade da rede).
  final bool bar;

  /// Valor montado à parte (a rede: ↓ verde e ↑ azul na mesma linha), sem barra.
  final Widget? valueWidget;

  const UsageRow(this.name, this.percent, {this.value, this.valueColor, this.detail, this.bar = true})
      : valueWidget = null;

  /// Só texto, sem barra.
  const UsageRow.text(this.name, String this.value, {this.valueColor})
      : percent = 0,
        detail = null,
        bar = false,
        valueWidget = null;

  /// Só o [valueWidget], centralizado, sem nome nem barra.
  const UsageRow.custom(Widget this.valueWidget)
      : name = '',
        percent = 0,
        value = null,
        valueColor = null,
        detail = null,
        bar = false;
}

/// Medidas em barras, no mesmo molde do botão de uso de IA: título com ícone e uma barra
/// por medida (CPU e RAM, unidades de disco...). O que não cabe no botão fica de fora,
/// na ordem da lista.
class UsageBars extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<UsageRow> rows;

  const UsageBars({super.key, required this.icon, required this.title, required this.rows});

  static const _barRowHeight = 25.0;
  static const _textRowHeight = 18.0;
  static const _detailHeight = 13.0;
  static const _headerHeight = 16.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final fg = DeckTile.foregroundOf(context);
      final roomy = c.maxHeight >= 120;
      double height(UsageRow r) => !r.bar
          ? _textRowHeight
          : _barRowHeight + (roomy && r.detail != null ? _detailHeight : 0);
      // Título só quando sobra lugar: com muitas medidas, as barras valem mais.
      final room = c.maxHeight - 8;
      final total = rows.fold<double>(0, (sum, r) => sum + height(r));
      final header = total + _headerHeight <= room || rows.length <= 2;
      final shown = <UsageRow>[];
      var used = header ? _headerHeight : 0.0;
      for (final r in rows) {
        if (shown.isNotEmpty && used + height(r) > room) break;
        shown.add(r);
        used += height(r);
      }

      Widget small(String text, double alpha) => Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, color: fg.withValues(alpha: alpha)));

      Widget row(UsageRow r) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (r.valueWidget != null)
                  FittedBox(fit: BoxFit.scaleDown, child: r.valueWidget)
                else
                  Row(children: [
                    small(r.name, 0.75),
                    const SizedBox(width: 4),
                    // Botão estreito (~76 dp no celular): o valor encolhe em vez de estourar.
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(r.value ?? '${r.percent.round()}%',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: r.valueColor,
                                fontFeatures: const [FontFeature.tabularFigures()])),
                      ),
                    ),
                  ]),
                if (r.bar) const SizedBox(height: 2),
                if (r.bar)
                  CapsuleBar(value: r.percent / 100, color: usageColor(r.percent), height: 5),
                if (roomy && r.detail != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: FittedBox(fit: BoxFit.scaleDown, child: small(r.detail!, 0.6)),
                  ),
              ],
            ),
          );

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (header)
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, size: 12),
                const SizedBox(width: 4),
                Flexible(child: small(title, 0.85)),
              ]),
            if (header) const SizedBox(height: 2),
            if (rows.isEmpty) small(tr('Sem dados'), 0.7) else for (final r in shown) row(r),
          ],
        ),
      );
    });
  }
}

/// Uma medida só, em barra: ícone e nome, o número grande e a barra (a opção "Barra" dos
/// medidores de CPU, memória, GPU e disco).
class UsageBar extends StatelessWidget {
  final IconData icon;
  final String name;
  final double percent;
  final String? detail;

  const UsageBar({super.key, required this.icon, required this.name, required this.percent, this.detail});

  @override
  Widget build(BuildContext context) {
    final fg = DeckTile.foregroundOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 12),
            const SizedBox(width: 4),
            Flexible(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: fg.withValues(alpha: 0.85))),
            ),
          ]),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('${percent.round()}%',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  fontFeatures: [FontFeature.tabularFigures()],
                )),
          ),
          CapsuleBar(value: percent / 100, color: usageColor(percent), height: 6),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(detail!, style: TextStyle(fontSize: 10, color: fg.withValues(alpha: 0.7))),
              ),
            ),
        ],
      ),
    );
  }
}

/// Barra de progresso em cápsula, fina, com trilho translúcido (como a bateria nos
/// widgets do iPhone). [value] de 0 a 1; anima quando muda.
class CapsuleBar extends StatelessWidget {
  final double value;
  final Color color;
  final double height;

  /// Trilho; padrão a cor do conteúdo da tecla a 12%.
  final Color? track;

  const CapsuleBar({super.key, required this.value, required this.color, this.height = 5, this.track});

  @override
  Widget build(BuildContext context) {
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    return ExcludeSemantics(
      child: Container(
        height: height,
        decoration: ShapeDecoration(
          color: track ?? DeckTile.foregroundOf(context).withValues(alpha: 0.12),
          shape: const StadiumBorder(),
        ),
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: v),
          duration: AppleMotion.of(context, DeckTileMotion.slow),
          curve: AppleMotion.smooth,
          builder: (context, t, _) => FractionallySizedBox(
            widthFactor: t.clamp(0.0, 1.0),
            heightFactor: 1.0,
            child: DecoratedBox(
              decoration: ShapeDecoration(color: color, shape: const StadiumBorder()),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

/// Anel de progresso fino, de pontas arredondadas, começando no topo (o anel de
/// atividade do Apple Watch, em versão discreta). Anima quando o valor muda.
class DeckRing extends StatelessWidget {
  final double value;
  final Color color;
  final double stroke;
  final Color? track;
  final Widget? child;

  const DeckRing({
    super.key,
    required this.value,
    required this.color,
    this.stroke = 5,
    this.track,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    final t = track ?? DeckTile.foregroundOf(context).withValues(alpha: 0.12);
    return ExcludeSemantics(
      excluding: child == null,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: v),
        duration: AppleMotion.of(context, DeckTileMotion.slow),
        curve: AppleMotion.smooth,
        builder: (context, p, child) => CustomPaint(
          painter: _RingPainter(p.clamp(0.0, 1.0), color, t, stroke),
          child: child,
        ),
        child: child,
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track, this.stroke);

  final double value;
  final Color color;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final r = (size.shortestSide - stroke) / 2;
    if (r <= 0) return;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: r);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 6.2832, false, paint..color = track);
    if (value > 0) {
      canvas.drawArc(rect, -1.5708, 6.2832 * value, false, paint..color = color);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color || old.track != track || old.stroke != stroke;
}

/// Tamanho em disco: "931 GB", "1,8 TB" (inglês: "1.8 TB").
String formatBytes(num bytes) {
  const gb = 1024 * 1024 * 1024;
  String f(double v) {
    var t = v < 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(0);
    if (t.endsWith('.0')) t = t.substring(0, t.length - 2);
    return decimalText(t);
  }

  final g = bytes / gb;
  if (g >= 1000) return '${f(g / 1024)} TB';
  if (g >= 1) return '${f(g)} GB';
  return '${f(bytes / (1024 * 1024))} MB';
}
