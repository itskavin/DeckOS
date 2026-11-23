import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Tela genérica de leitura de QR. Retorna (via Navigator.pop) a string crua do
/// primeiro QR cujo conteúdo começa com um dos [acceptPrefixes]. Usada tanto pro
/// pareamento (`deckos://...`) quanto pra ler o QR do OBS (`obsws://...`).
class QrScanPage extends StatefulWidget {
  /// Prefixos aceitos (case-insensitive). Padrão: QR de pareamento.
  final List<String> acceptPrefixes;

  /// Título e dica em português; a tela traduz com [tr].
  final String title;
  final String hint;

  const QrScanPage({
    super.key,
    this.acceptPrefixes = const ['deckos://'],
    this.title = 'Parear — aponte para o QR',
    this.hint = 'Abra "Parear dispositivo (QR)" na bandeja do PC',
  });

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      final lower = value.toLowerCase();
      final ok = widget.acceptPrefixes.any(
        (p) => lower.startsWith(p.toLowerCase()),
      );
      if (ok) {
        _handled = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = AppleTextStyles.of(context);
    // A câmera é sempre escura: a tela fica no visual escuro em qualquer tema.
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          tr(widget.title),
          style: type.headline.copyWith(color: Colors.white),
        ),
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(onDetect: _onDetect),
          const IgnorePointer(child: _Viewfinder(size: 248)),
          Positioned(
            left: AppleSpacing.xl,
            right: AppleSpacing.xl,
            bottom: AppleSpacing.xxl + MediaQuery.paddingOf(context).bottom,
            child: Center(
              child: GlassPanel(
                radius: AppleRadii.xl,
                color: Colors.black.withValues(alpha: 0.45),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpacing.md,
                  vertical: AppleSpacing.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.qr_code_scanner_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: AppleSpacing.xs),
                    Flexible(
                      child: Text(
                        tr(widget.hint),
                        textAlign: TextAlign.center,
                        style: type.subheadline.copyWith(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mira da câmera: só os quatro cantos, arredondados, como na câmera do iPhone.
class _Viewfinder extends StatelessWidget {
  const _Viewfinder({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _CornersPainter());
  }
}

class _CornersPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const len = 36.0;
    final paint = Paint()
      ..color = AppleSystemColors.yellowDark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    final w = size.width;
    final h = size.height;
    Path corner(Offset a, Offset ctrl, Offset b) => Path()
      ..moveTo(a.dx, a.dy)
      ..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy);
    for (final p in [
      corner(const Offset(0, len), Offset.zero, const Offset(len, 0)),
      corner(Offset(w - len, 0), Offset(w, 0), Offset(w, len)),
      corner(Offset(w, h - len), Offset(w, h), Offset(w - len, h)),
      corner(Offset(len, h), Offset(0, h), Offset(0, h - len)),
    ]) {
      canvas.drawPath(p, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
