import 'dart:convert';


import 'package:deckos/core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../widgets/editor/look_pickers.dart';

/// Ícones dos apps do PC, baixados uma vez por sessão.
class AppIconCache {
  AppIconCache._();

  static final _bytes = <String, Future<Uint8List?>>{};

  static Future<Uint8List?> of(InstalledApp app) =>
      _bytes['${Injector.get<DeckOSClient>().currentBaseUrl}:${app.id}'] ??= Injector.get<DeckOSClient>().getAppIcon(app);

  static bool isPng(Uint8List b) =>
      b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

  static bool isSvg(Uint8List b) {
    final head = utf8.decode(b.sublist(0, b.length < 256 ? b.length : 256), allowMalformed: true);
    return head.contains('<svg') || head.trimLeft().startsWith('<?xml');
  }

  /// PNG pequeno (até 256) para gravar no botão; null se o ícone não é PNG (SVG não
  /// vira imagem do botão: o celular não desenha SVG).
  static Future<Uint8List?> pngForButton(InstalledApp app) async {
    final b = await of(app);
    if (b == null || !isPng(b)) return null;
    return shrinkImage(b, 256);
  }
}

/// Ícone de um app da biblioteca: o do PC (PNG, ou SVG no navegador) ou, sem ele, a
/// inicial num quadrado squircle com uma cor tirada do nome.
class AppIconView extends StatelessWidget {
  final InstalledApp app;
  final double size;

  const AppIconView({super.key, required this.app, this.size = 52});

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: FutureBuilder<Uint8List?>(
        future: AppIconCache.of(app),
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null) {
            return snap.connectionState == ConnectionState.done
                ? MonogramIcon(name: app.name, size: size)
                : const SizedBox.shrink();
          }
          final fallback = MonogramIcon(name: app.name, size: size);
          if (AppIconCache.isSvg(bytes)) {
            // O Flutter não decodifica SVG: no navegador, uma <img> desenha.
            if (!kIsWeb) return fallback;
            return Image.network(
              'data:image/svg+xml;base64,${base64Encode(bytes)}',
              width: size,
              height: size,
              webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
              errorBuilder: (_, _, _) => fallback,
            );
          }
          return LiquidGlassIcon.memory(
            bytes,
            size: size,
            brightness: Theme.of(context).brightness,
            errorBuilder: (_) => fallback,
          );
        },
      ),
    );
  }
}

/// Inicial do nome num squircle colorido.
class MonogramIcon extends StatelessWidget {
  final String name;
  final double size;

  const MonogramIcon({super.key, required this.name, this.size = 52});

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final palette = [c.blue, c.purple, c.pink, c.orange, c.teal, c.indigo, c.green, c.red];
    final bg = palette[name.hashCode.abs() % palette.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(bg, Colors.white, 0.18)!, bg],
        ),
        shape: AppleShapes.squircle(AppleShapes.tileRadius(size)),
      ),
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: AppleColors.onColor(bg),
          fontSize: size * 0.46,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
