import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Que tipo de imagem um ícone de app é, para o [LiquidGlassIcon] saber como vesti-lo.
enum LiquidGlassKind {
  /// Logo solto num fundo transparente (ícones do Windows e do Linux, logos sem
  /// placa): ganha a placa de vidro escura por baixo.
  glyph,

  /// Já tem a placa dele (ícone do macOS, adaptativo do Android, imagem quadrada que
  /// ocupa tudo): só recorta no squircle e ganha o aro e o brilho do vidro.
  plated,
}

/// Resultado da leitura dos pixels de um ícone: o tipo e onde o desenho de fato está.
@immutable
class LiquidGlassShape {
  const LiquidGlassShape(this.kind, this.content);

  final LiquidGlassKind kind;

  /// Caixa do que não é transparente, em fração do lado da imagem (0..1). Serve para
  /// tirar a margem que cada ícone traz: no Windows o logo vem solto num canto do
  /// quadro; no macOS a placa vem com ~10% de respiro em volta.
  final Rect content;

  static const empty = LiquidGlassShape(
    LiquidGlassKind.glyph,
    Rect.fromLTWH(0, 0, 1, 1),
  );

  @override
  bool operator ==(Object other) =>
      other is LiquidGlassShape && other.kind == kind && other.content == content;

  @override
  int get hashCode => Object.hash(kind, content);

  @override
  String toString() => 'LiquidGlassShape($kind, $content)';
}

/// Lê os pixels RGBA (`width` × `height`, 4 bytes por pixel) e diz se o ícone é um
/// logo solto ou uma placa. Função pura: os testes chamam direto.
///
/// Placa: os cantos do quadro são opacos (imagem quadrada cheia), ou o desenho enche
/// quase toda a própria caixa (≥ 88%: um squircle perde só os cantos) e é quase
/// quadrado e grande. Um círculo enche 78,5% da caixa: logo redondo continua logo.
LiquidGlassShape classifyIconPixels(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    return LiquidGlassShape.empty;
  }
  // Amostra numa grade de até 96 × 96: basta para a forma e roda num instante.
  final step = (width > height ? width : height) ~/ 96 + 1;
  int alphaAt(int x, int y) => rgba[(y * width + x) * 4 + 3];

  var minX = width, minY = height, maxX = -1, maxY = -1;
  for (var y = 0; y < height; y += step) {
    for (var x = 0; x < width; x += step) {
      if (alphaAt(x, y) > 128) {
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return LiquidGlassShape.empty;
  // A grade pode ter pulado até um passo de cada borda.
  minX = (minX - step + 1).clamp(0, width - 1);
  minY = (minY - step + 1).clamp(0, height - 1);
  maxX = (maxX + step - 1).clamp(0, width - 1);
  maxY = (maxY + step - 1).clamp(0, height - 1);
  final content = Rect.fromLTRB(
    minX / width,
    minY / height,
    (maxX + 1) / width,
    (maxY + 1) / height,
  );

  // Cantos do quadro opacos: imagem cheia (ícone quadrado, capa).
  final insetX = (width * 0.02).floor().clamp(0, width - 1);
  final insetY = (height * 0.02).floor().clamp(0, height - 1);
  final corners = [
    alphaAt(insetX, insetY),
    alphaAt(width - 1 - insetX, insetY),
    alphaAt(insetX, height - 1 - insetY),
    alphaAt(width - 1 - insetX, height - 1 - insetY),
  ];
  if (corners.where((a) => a > 200).length >= 3) {
    return LiquidGlassShape(LiquidGlassKind.plated, content);
  }

  var inside = 0, opaque = 0;
  for (var y = minY; y <= maxY; y += step) {
    for (var x = minX; x <= maxX; x += step) {
      inside++;
      if (alphaAt(x, y) > 200) opaque++;
    }
  }
  final fill = inside == 0 ? 0.0 : opaque / inside;
  final aspect = content.width / content.height;
  final big = content.width >= 0.5 && content.height >= 0.5;
  final squareish = aspect > 0.85 && aspect < 1.18;
  final kind = fill >= 0.88 && squareish && big
      ? LiquidGlassKind.plated
      : LiquidGlassKind.glyph;
  return LiquidGlassShape(kind, content);
}

/// Imagem pronta para desenhar e a forma dela.
@immutable
class LiquidGlassArt {
  const LiquidGlassArt(this.image, this.shape);

  final ui.Image image;
  final LiquidGlassShape shape;
}

/// Decodifica e classifica cada ícone uma vez só. Bytes iguais (mesmo vindo de outro
/// base64) caem na mesma entrada: a chave é um hash do conteúdo.
abstract final class LiquidGlassCache {
  /// Maior lado decodificado: o bastante para uma tecla grande num tablet 3×.
  static const maxDecode = 512;

  /// Limite de entradas decodificadas em memória (LRU).
  static const capacity = 300;
  static const _base64Capacity = 200;

  static final _pending = <Object, Future<LiquidGlassArt?>>{};
  static final _ready = <Object, LiquidGlassArt?>{};
  static final _keys = Expando<_BytesKey>();
  static final _decodedBase64 = <String, Uint8List?>{};

  /// Quantidade de entradas prontas em cache (útil para testes).
  @visibleForTesting
  static int get cachedCount => _ready.length;

  /// Decodifica base64 (com ou sem prefixo `data:image/...;base64,`) uma vez só,
  /// em cache LRU limitado, evitando decodificar a cada rebuild.
  static Uint8List? decodeBase64(String data) {
    if (_decodedBase64.containsKey(data)) {
      final hit = _decodedBase64.remove(data);
      _decodedBase64[data] = hit;
      return hit;
    }
    Uint8List? bytes;
    try {
      final raw = data.startsWith('data:')
          ? data.substring(data.indexOf(',') + 1)
          : data;
      bytes = base64Decode(raw);
    } catch (_) {
      bytes = null;
    }
    _decodedBase64[data] = bytes;
    while (_decodedBase64.length > _base64Capacity) {
      _decodedBase64.remove(_decodedBase64.keys.first);
    }
    return bytes;
  }

  /// Chave de [bytes] (hash duplo do conteúdo, calculado uma vez por lista).
  static Object keyOf(Uint8List bytes) => _keys[bytes] ??= _hashBytes(bytes);

  /// Chave de um [ImageProvider]: [MemoryImage] compartilha a entrada com [ofBytes].
  static Object keyOfProvider(ImageProvider provider) =>
      provider is MemoryImage ? keyOf(provider.bytes) : provider;

  /// Já decodificado? Desenha no mesmo quadro, sem piscar.
  static LiquidGlassArt? peek(Object key) => _ready[key];
  static bool has(Object key) => _ready.containsKey(key);

  static Future<LiquidGlassArt?> ofBytes(Uint8List bytes) {
    final key = keyOf(bytes);
    return _load(key, () async {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      ui.Codec? codec;
      try {
        codec = await ui.instantiateImageCodecWithSize(
          buffer,
          getTargetSize: (w, h) {
            final big = w > h ? w : h;
            if (big <= maxDecode) return ui.TargetImageSize(width: w, height: h);
            return ui.TargetImageSize(
              width: math.max(1, (w * maxDecode / big).round()),
              height: math.max(1, (h * maxDecode / big).round()),
            );
          },
        );
        final frame = await codec.getNextFrame();
        return frame.image;
      } finally {
        codec?.dispose();
        // instantiateImageCodecWithSize assume a posse e descarta o buffer.
      }
    });
  }

  static Future<LiquidGlassArt?> ofProvider(ImageProvider provider) {
    if (provider is MemoryImage) return ofBytes(provider.bytes);
    return _load(provider, () {
      final done = Completer<ui.Image>();
      final stream = provider.resolve(ImageConfiguration.empty);
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          stream.removeListener(listener);
          if (!done.isCompleted) done.complete(info.image.clone());
          info.dispose();
        },
        onError: (e, st) {
          stream.removeListener(listener);
          if (!done.isCompleted) done.completeError(e, st);
        },
      );
      stream.addListener(listener);
      return done.future;
    });
  }

  static Future<LiquidGlassArt?> _load(
    Object key,
    Future<ui.Image> Function() decode,
  ) {
    if (_ready.containsKey(key)) {
      final hit = _ready.remove(key);
      _ready[key] = hit; // sobe para o fim (mais recente)
      return SynchronousFuture(hit);
    }
    return _pending[key] ??= () async {
      LiquidGlassArt? art;
      try {
        final image = await decode();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final shape = data == null
            ? LiquidGlassShape.empty
            : classifyIconPixels(
                data.buffer.asUint8List(),
                image.width,
                image.height,
              );
        art = LiquidGlassArt(image, shape);
      } catch (_) {
        art = null;
      }
      _pending.remove(key);
      _ready[key] = art;
      // As imagens que saem não são descartadas aqui: alguma tecla pode ainda estar
      // desenhando com elas; o coletor de lixo solta quando ninguém mais usa.
      while (_ready.length > capacity) {
        _ready.remove(_ready.keys.first);
      }
      return art;
    }();
  }

  /// Só para testes.
  static void clear() {
    _pending.clear();
    _ready.clear();
    _decodedBase64.clear();
  }

  /// Dois acumuladores de 32 bits (seguro em JS/Web) para evitar colisões no cache.
  static _BytesKey _hashBytes(Uint8List b) {
    var h1 = 0x811c9dc5;
    var h2 = 0x9e3779b9;
    for (var i = 0; i < b.length; i++) {
      final byte = b[i];
      h1 = ((h1 ^ byte) * 0x01000193) & 0xFFFFFFFF;
      h2 = (((h2 << 5) - h2 + byte) ^ (i & 0xFF)) & 0xFFFFFFFF;
    }
    return _BytesKey(h1, h2, b.length);
  }
}

class _BytesKey {
  const _BytesKey(this.h1, this.h2, this.length);

  final int h1;
  final int h2;
  final int length;

  @override
  bool operator ==(Object other) =>
      other is _BytesKey &&
      other.h1 == h1 &&
      other.h2 == h2 &&
      other.length == length;

  @override
  int get hashCode => Object.hash(h1, h2, length);
}
