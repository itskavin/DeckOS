import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ai_provider_style.dart';

/// Official AI provider brand marks bundled locally as resolution-independent
/// Flutter vector paths (zero runtime network fetching, zero image generation).
///
/// Provenance & License Notice:
/// - Provider vector path data (`openai`, `claude`, `gemini`, `antigravity`,
///   `githubcopilot`, `cursor`, `windsurf`) is sourced from `@lobehub/icons`
///   (`https://github.com/lobehub/lobe-icons`, MIT License, Copyright (c) 2023 LobeHub).
/// - All brand marks remain trademarks of their respective owners and are bundled
///   strictly for local provider identification inside DeckOS.
/// - Providers without an unambiguous public vector mark here (e.g. `devin`, or
///   custom/unknown providers) render a crisp typographic monogram instead of a
///   fabricated mark.
/// - Connection sources such as `cliproxy_passive` (CLIProxyAPI) intentionally
///   keep a distinct network/proxy icon rather than an AI model brand mark.
enum AiProviderMarkKind {
  openai,
  claude,
  gemini,
  antigravity,
  copilot,
  cursor,
  windsurf,
  monogram,
  generic,
}

@immutable
class _VectorMarkSpec {
  final String pathData;
  final PathFillType fillType;

  const _VectorMarkSpec(
    this.pathData, {
    this.fillType = PathFillType.nonZero,
  });
}

/// Source viewBox is `0 0 24 24` for every bundled vector mark below.
const Map<AiProviderMarkKind, _VectorMarkSpec> _kProviderMarkSpecs = {
  // OpenAI / Codex — @lobehub/icons `openai.svg` (MIT)
  AiProviderMarkKind.openai: _VectorMarkSpec(
    'M9.205 8.658v-2.26c0-.19.072-.333.238-.428l4.543-2.616c.619-.357 1.356-.523 2.117-.523 2.854 0 4.662 2.212 4.662 4.566 0 .167 0 .357-.024.547l-4.71-2.759a.797.797 0 00-.856 0l-5.97 3.473zm10.609 8.8V12.06c0-.333-.143-.57-.429-.737l-5.97-3.473 1.95-1.118a.433.433 0 01.476 0l4.543 2.617c1.309.76 2.189 2.378 2.189 3.948 0 1.808-1.07 3.473-2.76 4.163zM7.802 12.703l-1.95-1.142c-.167-.095-.239-.238-.239-.428V5.899c0-2.545 1.95-4.472 4.591-4.472 1 0 1.927.333 2.712.928L8.23 5.067c-.285.166-.428.404-.428.737v6.898zM12 15.128l-2.795-1.57v-3.33L12 8.658l2.795 1.57v3.33L12 15.128zm1.796 7.23c-1 0-1.927-.332-2.712-.927l4.686-2.712c.285-.166.428-.404.428-.737v-6.898l1.974 1.142c.167.095.238.238.238.428v5.233c0 2.545-1.974 4.472-4.614 4.472zm-5.637-5.303l-4.544-2.617c-1.308-.761-2.188-2.378-2.188-3.948A4.482 4.482 0 014.21 6.327v5.423c0 .333.143.571.428.738l5.947 3.449-1.95 1.118a.432.432 0 01-.476 0zm-.262 3.9c-2.688 0-4.662-2.021-4.662-4.519 0-.19.024-.38.047-.57l4.686 2.71c.286.167.571.167.856 0l5.97-3.448v2.26c0 .19-.07.333-.237.428l-4.543 2.616c-.619.357-1.356.523-2.117.523zm5.899 2.83a5.947 5.947 0 005.827-4.756C22.287 18.339 24 15.84 24 13.296c0-1.665-.713-3.282-1.998-4.448.119-.5.19-.999.19-1.498 0-3.401-2.759-5.947-5.946-5.947-.642 0-1.26.095-1.88.31A5.962 5.962 0 0010.205 0a5.947 5.947 0 00-5.827 4.757C1.713 5.447 0 7.945 0 10.49c0 1.666.713 3.283 1.998 4.448-.119.5-.19 1-.19 1.499 0 3.401 2.759 5.946 5.946 5.946.642 0 1.26-.095 1.88-.309a5.96 5.96 0 004.162 1.713z',
    fillType: PathFillType.evenOdd,
  ),
  // Anthropic Claude — @lobehub/icons `claude.svg` (MIT)
  AiProviderMarkKind.claude: _VectorMarkSpec(
    'M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z',
    fillType: PathFillType.evenOdd,
  ),
  // Google Gemini — @lobehub/icons `gemini.svg` (MIT)
  AiProviderMarkKind.gemini: _VectorMarkSpec(
    'M20.616 10.835a14.147 14.147 0 01-4.45-3.001 14.111 14.111 0 01-3.678-6.452.503.503 0 00-.975 0 14.134 14.134 0 01-3.679 6.452 14.155 14.155 0 01-4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 000 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 014.45 3.001 14.112 14.112 0 013.679 6.453.502.502 0 00.975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 013.001-4.45 14.113 14.113 0 016.453-3.678.503.503 0 000-.975 13.245 13.245 0 01-2.003-.678z',
    fillType: PathFillType.evenOdd,
  ),
  // Google Antigravity — @lobehub/icons `antigravity.svg` (MIT)
  AiProviderMarkKind.antigravity: _VectorMarkSpec(
    'M21.751 22.607c1.34 1.005 3.35.335 1.508-1.508C17.73 15.74 18.904 1 12.037 1 5.17 1 6.342 15.74.815 21.1c-2.01 2.009.167 2.511 1.507 1.506 5.192-3.517 4.857-9.714 9.715-9.714 4.857 0 4.522 6.197 9.714 9.715z',
    fillType: PathFillType.evenOdd,
  ),
  // GitHub Copilot — @lobehub/icons `githubcopilot.svg` (MIT)
  AiProviderMarkKind.copilot: _VectorMarkSpec(
    'M19.245 5.364c1.322 1.36 1.877 3.216 2.11 5.817.622 0 1.2.135 1.592.654l.73.964c.21.278.323.61.323.955v2.62c0 .339-.173.669-.453.868C20.239 19.602 16.157 21.5 12 21.5c-4.6 0-9.205-2.583-11.547-4.258-.28-.2-.452-.53-.453-.868v-2.62c0-.345.113-.679.321-.956l.73-.963c.392-.517.974-.654 1.593-.654l.029-.297c.25-2.446.81-4.213 2.082-5.52 2.461-2.54 5.71-2.851 7.146-2.864h.198c1.436.013 4.685.323 7.146 2.864zm-7.244 4.328c-.284 0-.613.016-.962.05-.123.447-.305.85-.57 1.108-1.05 1.023-2.316 1.18-2.994 1.18-.638 0-1.306-.13-1.851-.464-.516.165-1.012.403-1.044.996a65.882 65.882 0 00-.063 2.884l-.002.48c-.002.563-.005 1.126-.013 1.69.002.326.204.63.51.765 2.482 1.102 4.83 1.657 6.99 1.657 2.156 0 4.504-.555 6.985-1.657a.854.854 0 00.51-.766c.03-1.682.006-3.372-.076-5.053-.031-.596-.528-.83-1.046-.996-.546.333-1.212.464-1.85.464-.677 0-1.942-.157-2.993-1.18-.266-.258-.447-.661-.57-1.108-.32-.032-.64-.049-.96-.05zm-2.525 4.013c.539 0 .976.426.976.95v1.753c0 .525-.437.95-.976.95a.964.964 0 01-.976-.95v-1.752c0-.525.437-.951.976-.951zm5 0c.539 0 .976.426.976.95v1.753c0 .525-.437.95-.976.95a.964.964 0 01-.976-.95v-1.752c0-.525.437-.951.976-.951zM7.635 5.087c-1.05.102-1.935.438-2.385.906-.975 1.037-.765 3.668-.21 4.224.405.394 1.17.657 1.995.657h.09c.649-.013 1.785-.176 2.73-1.11.435-.41.705-1.433.675-2.47-.03-.834-.27-1.52-.63-1.813-.39-.336-1.275-.482-2.265-.394zm6.465.394c-.36.292-.6.98-.63 1.813-.03 1.037.24 2.06.675 2.47.968.957 2.136 1.104 2.776 1.11h.044c.825 0 1.59-.263 1.995-.657.555-.556.765-3.187-.21-4.224-.45-.468-1.335-.804-2.385-.906-.99-.088-1.875.058-2.265.394zM12 7.615c-.24 0-.525.015-.84.044.03.16.045.336.06.526l-.001.159a2.94 2.94 0 01-.014.25c.225-.022.425-.027.612-.028h.366c.187 0 .387.006.612.028-.015-.146-.015-.277-.015-.409.015-.19.03-.365.06-.526a9.29 9.29 0 00-.84-.044z',
    fillType: PathFillType.evenOdd,
  ),
  // Cursor — @lobehub/icons `cursor.svg` (MIT)
  AiProviderMarkKind.cursor: _VectorMarkSpec(
    'M22.106 5.68L12.5.135a.998.998 0 00-.998 0L1.893 5.68a.84.84 0 00-.419.726v11.186c0 .3.16.577.42.727l9.607 5.547a.999.999 0 00.998 0l9.608-5.547a.84.84 0 00.42-.727V6.407a.84.84 0 00-.42-.726zm-.603 1.176L12.228 22.92c-.063.108-.228.064-.228-.061V12.34a.59.59 0 00-.295-.51l-9.11-5.26c-.107-.062-.063-.228.062-.228h18.55c.264 0 .428.286.296.514z',
    fillType: PathFillType.evenOdd,
  ),
  // Windsurf — @lobehub/icons `windsurf.svg` (MIT)
  AiProviderMarkKind.windsurf: _VectorMarkSpec(
    'M23.78 5.004h-.228a2.187 2.187 0 00-2.18 2.196v4.912c0 .98-.804 1.775-1.76 1.775a1.818 1.818 0 01-1.472-.773L13.168 5.95a2.197 2.197 0 00-1.81-.95c-1.134 0-2.154.972-2.154 2.173v4.94c0 .98-.797 1.775-1.76 1.775-.57 0-1.136-.289-1.472-.773L.408 5.098C.282 4.918 0 5.007 0 5.228v4.284c0 .216.066.426.188.604l5.475 7.889c.324.466.8.812 1.351.938 1.377.316 2.645-.754 2.645-2.117V11.89c0-.98.787-1.775 1.76-1.775h.002c.586 0 1.135.288 1.472.773l4.972 7.163a2.15 2.15 0 001.81.95c1.158 0 2.151-.973 2.151-2.173v-4.939c0-.98.787-1.775 1.76-1.775h.194c.122 0 .22-.1.22-.222V5.225a.221.221 0 00-.22-.222z',
    fillType: PathFillType.evenOdd,
  ),
};

final Map<AiProviderMarkKind, Path> _cachedPaths = {};

/// Resolves which bundled mark (or honest monogram/generic fallback) to render for [style].
AiProviderMarkKind providerMarkKindFor(AiProviderStyle style) {
  return switch (style.key) {
    'codex' => AiProviderMarkKind.openai,
    'claude' => AiProviderMarkKind.claude,
    'gemini_cli' || 'gemini_web' => AiProviderMarkKind.gemini,
    'antigravity' => AiProviderMarkKind.antigravity,
    'copilot' => AiProviderMarkKind.copilot,
    'cursor' => AiProviderMarkKind.cursor,
    'windsurf' => AiProviderMarkKind.windsurf,
    'devin' => AiProviderMarkKind.monogram,
    'other' => AiProviderMarkKind.generic,
    _ => AiProviderMarkKind.monogram,
  };
}

/// Returns the cached Flutter [Path] in `0..24` coordinate space for an official vector mark.
Path? providerMarkPath(AiProviderMarkKind kind) {
  final spec = _kProviderMarkSpecs[kind];
  if (spec == null) return null;
  return _cachedPaths.putIfAbsent(
    kind,
    () => parseSvgPathData(spec.pathData, fillType: spec.fillType),
  );
}

/// Renders the recognizable brand mark for an [AiProviderStyle] (or a clean monogram when
/// no unambiguous public vector mark is bundled). Never performs runtime network requests.
class AiProviderIcon extends StatelessWidget {
  final AiProviderStyle style;
  final double size;
  final Color? color;
  final bool useBrandGradient;

  const AiProviderIcon({
    super.key,
    required this.style,
    required this.size,
    this.color,
    this.useBrandGradient = false,
  });

  @override
  Widget build(BuildContext context) {
    final kind = providerMarkKindFor(style);
    final effectiveColor = color ?? style.accent;
    final path = providerMarkPath(kind);

    if (path != null) {
      final gradient = useBrandGradient ? _brandGradientFor(kind) : null;
      return Semantics(
        label: style.displayName,
        excludeSemantics: true,
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            key: ValueKey('ai-brand-mark-${kind.name}'),
            painter: _SvgMarkPainter(
              path: path,
              color: effectiveColor,
              gradient: gradient,
            ),
          ),
        ),
      );
    }

    if (kind == AiProviderMarkKind.monogram) {
      final letters = _monogramText(style.displayName);
      return Semantics(
        label: style.displayName,
        excludeSemantics: true,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                letters,
                key: ValueKey('ai-brand-monogram-${style.key}'),
                maxLines: 1,
                style: TextStyle(
                  fontSize: size * (letters.length > 1 ? 0.60 : 0.72),
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  height: 1.0,
                  color: effectiveColor,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Icon(style.icon, size: size, color: effectiveColor);
  }

  static String _monogramText(String label) {
    final parts = label
        .trim()
        .split(RegExp(r'[\s_\-\.]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'AI';
    if (parts.length == 1) {
      final word = parts.first.toUpperCase();
      return word.length >= 2 ? word.substring(0, 2) : word;
    }
    return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  }

  static Gradient? _brandGradientFor(AiProviderMarkKind kind) {
    return switch (kind) {
      AiProviderMarkKind.gemini => const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Color(0xFF4285F4), Color(0xFF9B72CB), Color(0xFFD96570)],
        ),
      AiProviderMarkKind.antigravity => const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF3186FF),
            Color(0xFF00B95C),
            Color(0xFFFBBC04),
            Color(0xFFFC413D),
          ],
          stops: [0.0, 0.36, 0.68, 1.0],
        ),
      _ => null,
    };
  }
}

/// Consistent rounded-square provider icon badge reused across deck tiles,
/// detail sheets, settings dashboard cards, and onboarding/account lists.
class AiProviderBadge extends StatelessWidget {
  final AiProviderStyle style;
  final double size;
  final double? iconSize;
  final bool dark;
  final double? borderRadius;
  final bool showBorder;
  final bool useBrandGradient;
  final Color? accentOverride;

  const AiProviderBadge({
    super.key,
    required this.style,
    required this.size,
    required this.dark,
    this.iconSize,
    this.borderRadius,
    this.showBorder = true,
    this.useBrandGradient = false,
    this.accentOverride,
  });

  @override
  Widget build(BuildContext context) {
    final accent = accentOverride ?? style.legibleOn(dark: dark);
    final radius = borderRadius ?? (size * 0.28).clamp(5.0, 12.0);
    final glyph = iconSize ?? (size * 0.56).clamp(9.5, 24.0);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: dark ? 0.28 : 0.18),
            accent.withValues(alpha: dark ? 0.13 : 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: showBorder
            ? Border.all(
                color: accent.withValues(alpha: dark ? 0.38 : 0.26),
                width: 0.9,
              )
            : null,
      ),
      child: Center(
        child: AiProviderIcon(
          style: style,
          size: glyph,
          color: accent,
          useBrandGradient: useBrandGradient,
        ),
      ),
    );
  }
}

/// Renders an icon badge for an AI Limits **source kind**, keeping connection/proxy
/// sources (`cliproxy_passive`, `manual_dashboard`) visually distinct from individual
/// provider brand marks (`codex_local`, `claude_statusline`, `gemini_local_otel`).
class AiSourceKindBadge extends StatelessWidget {
  final String kind;
  final Color color;
  final bool dark;
  final double size;

  const AiSourceKindBadge({
    super.key,
    required this.kind,
    required this.color,
    required this.dark,
    this.size = 28,
  });

  static AiProviderStyle? providerStyleForSourceKind(String kind) => switch (kind) {
        'codex_local' => AiProviderStyle.codex,
        'claude_statusline' => AiProviderStyle.claude,
        'gemini_local_otel' => AiProviderStyle.geminiCli,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final providerStyle = providerStyleForSourceKind(kind);
    if (providerStyle != null) {
      return AiProviderBadge(
        style: providerStyle,
        size: size,
        iconSize: size * 0.58,
        dark: dark,
        borderRadius: size * 0.25,
        showBorder: true,
        accentOverride: color,
      );
    }
    final icon = switch (kind) {
      'cliproxy_passive' => Icons.lan_rounded,
      'manual_dashboard' => Icons.open_in_new_rounded,
      _ => Icons.speed_rounded,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.22 : 0.14),
        borderRadius: BorderRadius.circular(size * 0.25),
        border: Border.all(
          color: color.withValues(alpha: dark ? 0.34 : 0.22),
          width: 0.85,
        ),
      ),
      child: Icon(icon, size: size * 0.58, color: color),
    );
  }
}

class _SvgMarkPainter extends CustomPainter {
  final Path path;
  final Color color;
  final Gradient? gradient;

  const _SvgMarkPainter({
    required this.path,
    required this.color,
    this.gradient,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final side = math.min(size.width, size.height);
    final dx = (size.width - side) / 2;
    final dy = (size.height - side) / 2;
    final scale = side / 24.0;

    canvas.save();
    canvas.translate(dx, dy);
    canvas.scale(scale, scale);

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    if (gradient != null) {
      paint.shader = gradient!.createShader(const Rect.fromLTWH(0, 0, 24, 24));
    } else {
      paint.color = color;
    }
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SvgMarkPainter old) =>
      old.path != path || old.color != color || old.gradient != gradient;
}

/// Minimal, spec-compliant SVG `d` path parser producing a Flutter [Path].
/// Supports M/m, L/l, H/h, V/v, C/c, S/s, Q/q, T/t, A/a (including compact arc flags), Z/z.
Path parseSvgPathData(
  String d, {
  PathFillType fillType = PathFillType.nonZero,
}) {
  final path = Path()..fillType = fillType;
  final scanner = _SvgPathScanner(d);

  double cx = 0, cy = 0;
  double sx = 0, sy = 0;
  double lastCtrlX = 0, lastCtrlY = 0;
  String? prevCmd;
  String? cmd;

  while (!scanner.isDone) {
    scanner.skipSeparators();
    if (scanner.isDone) break;
    final nextCmd = scanner.readCommand();
    if (nextCmd != null) {
      cmd = nextCmd;
    } else if (cmd == null) {
      break;
    }

    switch (cmd) {
      case 'M':
      case 'm':
        final rel = cmd == 'm';
        final x = scanner.readNumber() + (rel ? cx : 0);
        final y = scanner.readNumber() + (rel ? cy : 0);
        path.moveTo(x, y);
        cx = x;
        cy = y;
        sx = x;
        sy = y;
        lastCtrlX = cx;
        lastCtrlY = cy;
        prevCmd = cmd;
        cmd = rel ? 'l' : 'L';
      case 'L':
      case 'l':
        final rel = cmd == 'l';
        final x = scanner.readNumber() + (rel ? cx : 0);
        final y = scanner.readNumber() + (rel ? cy : 0);
        path.lineTo(x, y);
        cx = x;
        cy = y;
        lastCtrlX = cx;
        lastCtrlY = cy;
        prevCmd = cmd;
      case 'H':
      case 'h':
        final rel = cmd == 'h';
        final x = scanner.readNumber() + (rel ? cx : 0);
        path.lineTo(x, cy);
        cx = x;
        lastCtrlX = cx;
        lastCtrlY = cy;
        prevCmd = cmd;
      case 'V':
      case 'v':
        final rel = cmd == 'v';
        final y = scanner.readNumber() + (rel ? cy : 0);
        path.lineTo(cx, y);
        cy = y;
        lastCtrlX = cx;
        lastCtrlY = cy;
        prevCmd = cmd;
      case 'C':
      case 'c':
        final rel = cmd == 'c';
        final x1 = scanner.readNumber() + (rel ? cx : 0);
        final y1 = scanner.readNumber() + (rel ? cy : 0);
        final x2 = scanner.readNumber() + (rel ? cx : 0);
        final y2 = scanner.readNumber() + (rel ? cy : 0);
        final x = scanner.readNumber() + (rel ? cx : 0);
        final y = scanner.readNumber() + (rel ? cy : 0);
        path.cubicTo(x1, y1, x2, y2, x, y);
        lastCtrlX = x2;
        lastCtrlY = y2;
        cx = x;
        cy = y;
        prevCmd = cmd;
      case 'S':
      case 's':
        final rel = cmd == 's';
        final x1 = (prevCmd == 'C' || prevCmd == 'c' || prevCmd == 'S' || prevCmd == 's')
            ? 2 * cx - lastCtrlX
            : cx;
        final y1 = (prevCmd == 'C' || prevCmd == 'c' || prevCmd == 'S' || prevCmd == 's')
            ? 2 * cy - lastCtrlY
            : cy;
        final x2 = scanner.readNumber() + (rel ? cx : 0);
        final y2 = scanner.readNumber() + (rel ? cy : 0);
        final x = scanner.readNumber() + (rel ? cx : 0);
        final y = scanner.readNumber() + (rel ? cy : 0);
        path.cubicTo(x1, y1, x2, y2, x, y);
        lastCtrlX = x2;
        lastCtrlY = y2;
        cx = x;
        cy = y;
        prevCmd = cmd;
      case 'Q':
      case 'q':
        final rel = cmd == 'q';
        final x1 = scanner.readNumber() + (rel ? cx : 0);
        final y1 = scanner.readNumber() + (rel ? cy : 0);
        final x = scanner.readNumber() + (rel ? cx : 0);
        final y = scanner.readNumber() + (rel ? cy : 0);
        path.quadraticBezierTo(x1, y1, x, y);
        lastCtrlX = x1;
        lastCtrlY = y1;
        cx = x;
        cy = y;
        prevCmd = cmd;
      case 'T':
      case 't':
        final rel = cmd == 't';
        final x1 = (prevCmd == 'Q' || prevCmd == 'q' || prevCmd == 'T' || prevCmd == 't')
            ? 2 * cx - lastCtrlX
            : cx;
        final y1 = (prevCmd == 'Q' || prevCmd == 'q' || prevCmd == 'T' || prevCmd == 't')
            ? 2 * cy - lastCtrlY
            : cy;
        final x = scanner.readNumber() + (rel ? cx : 0);
        final y = scanner.readNumber() + (rel ? cy : 0);
        path.quadraticBezierTo(x1, y1, x, y);
        lastCtrlX = x1;
        lastCtrlY = y1;
        cx = x;
        cy = y;
        prevCmd = cmd;
      case 'A':
      case 'a':
        final rel = cmd == 'a';
        final rx = scanner.readNumber().abs();
        final ry = scanner.readNumber().abs();
        final rotation = scanner.readNumber();
        final largeArc = scanner.readFlag();
        final clockwise = scanner.readFlag();
        final x = scanner.readNumber() + (rel ? cx : 0);
        final y = scanner.readNumber() + (rel ? cy : 0);
        if (rx == 0 || ry == 0) {
          path.lineTo(x, y);
        } else {
          path.arcToPoint(
            Offset(x, y),
            radius: Radius.elliptical(rx, ry),
            rotation: rotation,
            largeArc: largeArc,
            clockwise: clockwise,
          );
        }
        cx = x;
        cy = y;
        lastCtrlX = cx;
        lastCtrlY = cy;
        prevCmd = cmd;
      case 'Z':
      case 'z':
        path.close();
        cx = sx;
        cy = sy;
        lastCtrlX = cx;
        lastCtrlY = cy;
        prevCmd = cmd;
        cmd = null;
      default:
        return path;
    }
  }
  return path;
}

class _SvgPathScanner {
  final String _s;
  int _i = 0;

  _SvgPathScanner(this._s);

  bool get isDone => _i >= _s.length;

  void skipSeparators() {
    while (_i < _s.length) {
      final ch = _s.codeUnitAt(_i);
      if (ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0x2C) {
        _i++;
      } else {
        break;
      }
    }
  }

  String? readCommand() {
    skipSeparators();
    if (_i >= _s.length) return null;
    final ch = _s.codeUnitAt(_i);
    final isAlpha = (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A);
    if (!isAlpha) return null;
    _i++;
    return String.fromCharCode(ch);
  }

  bool readFlag() {
    skipSeparators();
    if (_i >= _s.length) return false;
    final ch = _s.codeUnitAt(_i);
    if (ch == 0x30 || ch == 0x31) {
      _i++;
      return ch == 0x31;
    }
    return readNumber() != 0;
  }

  double readNumber() {
    skipSeparators();
    final start = _i;
    if (_i < _s.length && (_s.codeUnitAt(_i) == 0x2B || _s.codeUnitAt(_i) == 0x2D)) {
      _i++;
    }
    while (_i < _s.length && _isDigit(_s.codeUnitAt(_i))) {
      _i++;
    }
    if (_i < _s.length && _s.codeUnitAt(_i) == 0x2E) {
      _i++;
      while (_i < _s.length && _isDigit(_s.codeUnitAt(_i))) {
        _i++;
      }
    }
    if (_i < _s.length && (_s.codeUnitAt(_i) == 0x65 || _s.codeUnitAt(_i) == 0x45)) {
      final expStart = _i;
      _i++;
      if (_i < _s.length && (_s.codeUnitAt(_i) == 0x2B || _s.codeUnitAt(_i) == 0x2D)) {
        _i++;
      }
      final digitsStart = _i;
      while (_i < _s.length && _isDigit(_s.codeUnitAt(_i))) {
        _i++;
      }
      if (_i == digitsStart) _i = expStart;
    }
    if (_i == start) return 0;
    return double.tryParse(_s.substring(start, _i)) ?? 0;
  }

  static bool _isDigit(int ch) => ch >= 0x30 && ch <= 0x39;
}
