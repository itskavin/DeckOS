import 'dart:ui' show ImageFilter;

import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Leitor de QR no estilo da câmera do iPhone: a imagem toda, desfocada e escurecida
/// fora de um visor de canto contínuo, com cantoneiras brancas e lanterna. Devolve (via
/// Navigator.pop) o texto do primeiro QR que começa com um dos [acceptPrefixes]. Mesma
/// interface do QrScanPage da configuração, que pode trocar por este.
class AppleQrScanPage extends StatefulWidget {
  /// Prefixos aceitos (sem diferenciar maiúsculas). Padrão: QR de pareamento.
  final List<String> acceptPrefixes;

  /// Título e dica em português; a tela traduz com [tr].
  final String title;
  final String hint;

  const AppleQrScanPage({
    super.key,
    this.acceptPrefixes = const ['deckos://'],
    this.title = 'Escanear código QR',
    this.hint = 'Abra "Parear dispositivo (QR)" na bandeja do PC',
  });

  @override
  State<AppleQrScanPage> createState() => _AppleQrScanPageState();
}

class _AppleQrScanPageState extends State<AppleQrScanPage> {
  final _scanner = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _handled = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      final lower = value.toLowerCase();
      if (widget.acceptPrefixes.any((p) => lower.startsWith(p.toLowerCase()))) {
        _handled = true;
        ThemeController.instance.tapFeedback();
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = AppleTextStyles.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, c) {
        final side = (c.biggest.shortestSide * 0.66).clamp(180.0, 300.0);
        final hole = Rect.fromCenter(
          center: Offset(c.maxWidth / 2, c.maxHeight * 0.46),
          width: side,
          height: side,
        );
        final radius = side * 0.12;
        return Stack(
          children: [
            Positioned.fill(child: MobileScanner(controller: _scanner, onDetect: _onDetect)),
            // Fora do visor: desfoque + véu escuro. O recorte deixa o visor nítido.
            Positioned.fill(
              child: ClipPath(
                clipper: _OutsideHole(hole, radius),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: const ColoredBox(color: Color(0x8C000000)),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: hole,
              child: IgnorePointer(
                child: CustomPaint(painter: _CornersPainter(radius)),
              ),
            ),
            // Título e fechar.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.all(AppleSpacing.md),
                  child: Row(
                    children: [
                      _RoundGlassButton(
                        icon: Icons.close_rounded,
                        tooltip: tr('Fechar'),
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Text(
                          tr(widget.title),
                          textAlign: TextAlign.center,
                          style: type.headline.copyWith(color: Colors.white),
                        ),
                      ),
                      ValueListenableBuilder<MobileScannerState>(
                        valueListenable: _scanner,
                        builder: (context, state, _) => _RoundGlassButton(
                          icon: state.torchState == TorchState.on
                              ? Icons.flash_on_rounded
                              : Icons.flash_off_rounded,
                          tooltip: tr('Lanterna'),
                          onTap: state.torchState == TorchState.unavailable
                              ? null
                              : () => _scanner.toggleTorch(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Dica embaixo do visor.
            Positioned(
              top: hole.bottom + AppleSpacing.xl,
              left: AppleSpacing.xl,
              right: AppleSpacing.xl,
              child: Center(
                child: GlassPanel(
                  radius: AppleRadii.xl,
                  color: const Color(0x66000000),
                  border: false,
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppleSpacing.md, vertical: AppleSpacing.xs),
                  child: Text(
                    tr(widget.hint),
                    textAlign: TextAlign.center,
                    style: type.subheadline.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _RoundGlassButton extends StatelessWidget {
  const _RoundGlassButton({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: Opacity(
        opacity: onTap == null ? 0.35 : 1,
        child: ApplePressable(
          onTap: onTap,
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                width: 40,
                height: 40,
                color: const Color(0x33FFFFFF),
                child: Icon(icon, color: Colors.white, size: 18),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tudo menos o visor.
class _OutsideHole extends CustomClipper<Path> {
  _OutsideHole(this.hole, this.radius);

  final Rect hole;
  final double radius;

  @override
  Path getClip(Size size) => Path()
    ..fillType = PathFillType.evenOdd
    ..addRect(Offset.zero & size)
    ..addRRect(RRect.fromRectAndRadius(hole, Radius.circular(radius)));

  @override
  bool shouldReclip(_OutsideHole old) => old.hole != hole || old.radius != radius;
}

/// Cantoneiras brancas arredondadas nos quatro cantos do visor.
class _CornersPainter extends CustomPainter {
  _CornersPainter(this.radius);

  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    final arm = size.shortestSide * 0.16;
    final r = radius;
    // Canto superior esquerdo; os outros são o mesmo desenho espelhado.
    final corner = Path()
      ..moveTo(0, r + arm)
      ..lineTo(0, r)
      ..arcToPoint(Offset(r, 0), radius: Radius.circular(r))
      ..lineTo(r + arm, 0);
    for (final (sx, sy) in [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)]) {
      canvas.save();
      canvas.translate(sx < 0 ? size.width : 0, sy < 0 ? size.height : 0);
      canvas.scale(sx, sy);
      canvas.drawPath(corner, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_CornersPainter old) => old.radius != radius;
}
