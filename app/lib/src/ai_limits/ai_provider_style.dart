import 'package:deckos/core/core.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

/// Live quota tile dynamic type (distinct from legacy `ai_usage` and fixture `ai_limits_demo`).
const aiLimitsDynamicType = 'ai_limits';

/// Default page title when the user creates/populates an AI Usage deck page.
const aiLimitsDefaultPageName = 'AI Usage';

/// Visual styling metadata for an AI subscription provider in DeckOS tiles and settings.
/// Keeps provider identity clear and legible in both dark and light DeckOS themes.
@immutable
class AiProviderStyle {
  final String key;
  final String displayName;
  final Color accent;
  final IconData icon;

  const AiProviderStyle({
    required this.key,
    required this.displayName,
    required this.accent,
    required this.icon,
  });

  static const AiProviderStyle claude = AiProviderStyle(
    key: 'claude',
    displayName: 'Claude',
    accent: Color(0xFFD97757),
    icon: CupertinoIcons.sparkles,
  );

  static const AiProviderStyle codex = AiProviderStyle(
    key: 'codex',
    displayName: 'Codex',
    accent: Color(0xFF10A37F),
    icon: CupertinoIcons.chevron_left_slash_chevron_right,
  );

  static const AiProviderStyle geminiCli = AiProviderStyle(
    key: 'gemini_cli',
    displayName: 'Gemini CLI',
    accent: Color(0xFF4285F4),
    icon: CupertinoIcons.bolt_fill,
  );

  static const AiProviderStyle geminiWeb = AiProviderStyle(
    key: 'gemini_web',
    displayName: 'Gemini',
    accent: Color(0xFF60A5FA),
    icon: CupertinoIcons.sparkles,
  );

  static const AiProviderStyle antigravity = AiProviderStyle(
    key: 'antigravity',
    displayName: 'Antigravity',
    accent: Color(0xFFF59E0B),
    icon: CupertinoIcons.rocket_fill,
  );

  static const AiProviderStyle copilot = AiProviderStyle(
    key: 'copilot',
    displayName: 'Copilot',
    accent: Color(0xFF8B5CF6),
    icon: CupertinoIcons.circle_grid_hex_fill,
  );

  static const AiProviderStyle cursor = AiProviderStyle(
    key: 'cursor',
    displayName: 'Cursor',
    accent: Color(0xFF38BDF8),
    icon: CupertinoIcons.cube_fill,
  );

  static const AiProviderStyle windsurf = AiProviderStyle(
    key: 'windsurf',
    displayName: 'Windsurf',
    accent: Color(0xFF14B8A6),
    icon: CupertinoIcons.wind,
  );

  static const AiProviderStyle devin = AiProviderStyle(
    key: 'devin',
    displayName: 'Devin',
    accent: Color(0xFF22C55E),
    icon: CupertinoIcons.chevron_right_square_fill,
  );

  static const AiProviderStyle fallback = AiProviderStyle(
    key: 'other',
    displayName: 'AI',
    accent: Color(0xFF60A5FA),
    icon: CupertinoIcons.gauge,
  );

  /// Resolves a provider key (case-insensitive, substring-tolerant) into a visual style.
  static AiProviderStyle resolve(String? rawProvider, {String? fallbackLabel}) {
    final p = (rawProvider ?? '').trim().toLowerCase();
    if (p.contains('claude') || p.contains('anthropic')) return claude;
    if (p.contains('codex') || p.contains('openai') || p.contains('chatgpt')) return codex;
    if (p.contains('antigravity')) return antigravity;
    if (p == 'gemini_web' || p.contains('gemini web')) return geminiWeb;
    if (p.contains('gemini') || p.contains('google')) return geminiCli;
    if (p.contains('copilot') || p.contains('github')) return copilot;
    if (p.contains('cursor')) return cursor;
    if (p.contains('windsurf')) return windsurf;
    if (p.contains('devin')) return devin;
    if (fallbackLabel != null && fallbackLabel.trim().isNotEmpty) {
      return AiProviderStyle(
        key: p.isEmpty ? 'other' : p,
        displayName: fallbackLabel.trim(),
        accent: fallback.accent,
        icon: fallback.icon,
      );
    }
    return fallback;
  }

  /// Adjusts accent lightness so icons/badges remain legible on dark or light surfaces.
  Color legibleOn({required bool dark}) {
    final hsl = HSLColor.fromColor(accent);
    if (dark && hsl.lightness < 0.56) return hsl.withLightness(0.62).toColor();
    if (!dark && hsl.lightness > 0.44) return hsl.withLightness(0.40).toColor();
    return accent;
  }
}

/// Formats a reset timestamp into a concise countdown ("2h 14m", "45m") when within 24h,
/// or weekday + clock ("Thu 18:00") further out. Returns null if [resetsAt] is null.
String? formatAiResetTime(DateTime? resetsAt, {DateTime? now, bool compact = false}) {
  if (resetsAt == null) return null;
  final current = (now ?? DateTime.now()).toUtc();
  final target = resetsAt.toUtc();
  final diff = target.difference(current);
  if (diff.isNegative) {
    return tr('Após reinício');
  }
  if (diff.inMinutes < 1) {
    return tr('< 1 min');
  }
  if (diff.inHours < 24) {
    final h = diff.inHours;
    final m = diff.inMinutes % 60;
    if (h == 0) {
      return compact ? '${m}m' : tr('Em {m}m', {'m': '$m'});
    }
    if (m == 0) {
      return compact ? '${h}h' : tr('Em {h}h', {'h': '$h'});
    }
    return compact
        ? '${h}h ${m}m'
        : tr('Em {h}h {m}m', {'h': '$h', 'm': '$m'});
  }
  final local = resetsAt.toLocal().add(const Duration(seconds: 30));
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  const days = ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'];
  final day = tr(days[local.weekday - 1]);
  return '$day $hh:$mm';
}

/// Formats a short relative age for an observation timestamp ("Agora", "há 3 min", "há 2 h").
String? formatObservedAge(DateTime? observedAt, {DateTime? now}) {
  if (observedAt == null) return null;
  final current = (now ?? DateTime.now()).toUtc();
  final diff = current.difference(observedAt.toUtc());
  if (diff.isNegative || diff.inSeconds < 45) {
    return tr('Agora');
  }
  if (diff.inMinutes < 60) {
    return tr('há {m} min', {'m': '${diff.inMinutes}'});
  }
  if (diff.inHours < 24) {
    return tr('há {h} h', {'h': '${diff.inHours}'});
  }
  return tr('há {d} d', {'d': '${diff.inDays}'});
}

/// Tile-local display preferences stored strictly inside `DeckButton.dynamicParameters`.
/// Never contains credentials, management keys, emails, tokens, or auth filenames.
@immutable
class AiLimitsTileConfig {
  /// Opaque backend account identifier (e.g. "acct_...").
  final String accountId;
  final bool combined;
  final bool allAccounts;
  final List<String> accountIds;

  /// Optional opaque source identifier for repair/lookup context.
  final String sourceId;

  /// Optional provider key hint for rendering while loading/offline.
  final String providerHint;

  /// Optional user-friendly alias fallback while offline/loading.
  final String aliasHint;

  /// Display mode: 'used' (default) or 'remaining'.
  final String displayMode;

  /// Comma-separated window filter per contract:
  /// 'five_hour,weekly' (default), 'five_hour', 'weekly', or 'all'.
  final String windows;

  /// Whether to show reset countdown badge/labels on the tile.
  final bool showReset;

  /// Visual density: 'comfortable' (default) or 'compact'.
  final String density;

  /// Optional extra model pool name (e.g. a Codex model bucket). Empty = main pool.
  final String pool;

  const AiLimitsTileConfig({
    this.accountId = '',
    this.combined = false,
    this.allAccounts = false,
    this.accountIds = const [],
    this.sourceId = '',
    this.providerHint = '',
    this.aliasHint = '',
    this.displayMode = 'used',
    this.windows = 'five_hour,weekly',
    this.showReset = true,
    this.density = 'comfortable',
    this.pool = '',
  });

  bool get showRemaining => displayMode == 'remaining';
  bool get isCompact => density == 'compact';
  bool get isBound => combined ? (allAccounts || accountIds.isNotEmpty) : accountId.isNotEmpty;

  /// Normalized list of preferred window kinds (empty list means show all reported windows).
  List<String> get preferredWindowKinds {
    final trimmed = windows.trim().toLowerCase();
    if (trimmed.isEmpty || trimmed == 'all') return const [];
    return trimmed
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  factory AiLimitsTileConfig.fromParams(Map<String, String>? params) {
    final p = params ?? const <String, String>{};
    final mode = p['displayMode'] == 'remaining' ? 'remaining' : 'used';
    final rawWin = (p['windows'] ?? '').trim();
    final win = rawWin.isEmpty ? 'five_hour,weekly' : rawWin;
    final showReset = p['showReset'] != 'false';
    final dens = p['density'] == 'compact' ? 'compact' : 'comfortable';
    return AiLimitsTileConfig(
      accountId: (p['accountId'] ?? '').trim(),
      combined: p['view'] == 'combined',
      allAccounts: p['accountSelection'] == 'all',
      accountIds: (p['accountIds'] ?? '').split(',').map((id) => id.trim()).where((id) => id.isNotEmpty).toSet().take(100).toList(),
      sourceId: (p['sourceId'] ?? '').trim(),
      providerHint: (p['provider'] ?? '').trim(),
      aliasHint: (p['alias'] ?? '').trim(),
      displayMode: mode,
      windows: win,
      showReset: showReset,
      density: dens,
      pool: (p['pool'] ?? '').trim(),
    );
  }

  Map<String, String> toParams() => {
        if (combined) 'view': 'combined',
        if (allAccounts) 'accountSelection': 'all',
        if (accountIds.isNotEmpty) 'accountIds': accountIds.toSet().join(','),
        if (pool.isNotEmpty) 'pool': pool,
        if (accountId.isNotEmpty) 'accountId': accountId,
        if (sourceId.isNotEmpty) 'sourceId': sourceId,
        if (providerHint.isNotEmpty) 'provider': providerHint,
        if (aliasHint.isNotEmpty) 'alias': aliasHint,
        if (displayMode != 'used') 'displayMode': displayMode,
        if (windows != 'five_hour,weekly') 'windows': windows,
        if (!showReset) 'showReset': 'false',
        if (density != 'comfortable') 'density': density,
      };

  AiLimitsTileConfig copyWith({
    String? accountId,
    bool? combined,
    bool? allAccounts,
    List<String>? accountIds,
    String? sourceId,
    String? providerHint,
    String? aliasHint,
    String? displayMode,
    String? windows,
    bool? showReset,
    String? density,
    String? pool,
  }) =>
      AiLimitsTileConfig(
        pool: pool ?? this.pool,
        combined: combined ?? this.combined,
        allAccounts: allAccounts ?? this.allAccounts,
        accountIds: accountIds ?? this.accountIds,
        accountId: accountId ?? this.accountId,
        sourceId: sourceId ?? this.sourceId,
        providerHint: providerHint ?? this.providerHint,
        aliasHint: aliasHint ?? this.aliasHint,
        displayMode: displayMode ?? this.displayMode,
        windows: windows ?? this.windows,
        showReset: showReset ?? this.showReset,
        density: density ?? this.density,
      );
}
