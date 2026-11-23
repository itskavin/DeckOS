import 'package:flutter/foundation.dart';

/// Immutable Dart models matching `docs/ai-limits-api-contract.md` (v1).
/// Strictly secret-free: never models, stores, or logs credentials, tokens, or emails.

DateTime? _parseDate(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return null;
  return DateTime.tryParse(raw.trim());
}

double? _parseDouble(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    final v = raw.toDouble();
    return v.isNaN || v.isInfinite ? null : v;
  }
  if (raw is String) return double.tryParse(raw);
  return null;
}

int? _parseInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

bool? _parseBool(Object? raw) => raw is bool ? raw : null;

String _str(Object? raw, [String fallback = '']) =>
    raw is String ? raw : (raw == null ? fallback : '$raw');

String? _optStr(Object? raw) {
  if (raw is! String) return null;
  final t = raw.trim();
  return t.isEmpty ? null : t;
}

List<Map<String, dynamic>> _mapList(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

List<String> _strList(Object? raw) {
  if (raw is! List) return const [];
  return [for (final item in raw) if (item != null) '$item'];
}

@immutable
class AiLimitsDetectedEnvironment {
  final String? cliProxySuggestedUrl;
  final bool cliProxyReachable;
  final bool codexCliAvailable;
  final bool codexDefaultHomeExists;
  final bool claudeCliAvailable;
  final bool claudeConfigDirExists;
  final bool claudeStatusLineConfigured;
  final bool geminiDirExists;

  const AiLimitsDetectedEnvironment({
    this.cliProxySuggestedUrl,
    this.cliProxyReachable = false,
    this.codexCliAvailable = false,
    this.codexDefaultHomeExists = false,
    this.claudeCliAvailable = false,
    this.claudeConfigDirExists = false,
    this.claudeStatusLineConfigured = false,
    this.geminiDirExists = false,
  });

  factory AiLimitsDetectedEnvironment.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AiLimitsDetectedEnvironment();
    return AiLimitsDetectedEnvironment(
      cliProxySuggestedUrl: _optStr(json['cliProxySuggestedUrl']),
      cliProxyReachable: json['cliProxyReachable'] == true,
      codexCliAvailable: json['codexCliAvailable'] == true,
      codexDefaultHomeExists: json['codexDefaultHomeExists'] == true,
      claudeCliAvailable: json['claudeCliAvailable'] == true,
      claudeConfigDirExists: json['claudeConfigDirExists'] == true,
      claudeStatusLineConfigured: json['claudeStatusLineConfigured'] == true,
      geminiDirExists: json['geminiDirExists'] == true,
    );
  }
}

@immutable
class AiLimitsSourceKindCapability {
  final String kind;
  final String title;
  final String description;
  final String accessMode;
  final bool requiresCredential;
  final bool supportsMultiAccount;
  final bool supportsGuidedSetup;
  final bool supportsTestConnection;
  final String? provenanceNote;

  const AiLimitsSourceKindCapability({
    required this.kind,
    required this.title,
    required this.description,
    required this.accessMode,
    this.requiresCredential = false,
    this.supportsMultiAccount = false,
    this.supportsGuidedSetup = false,
    this.supportsTestConnection = true,
    this.provenanceNote,
  });

  factory AiLimitsSourceKindCapability.fromJson(Map<String, dynamic> json) {
    return AiLimitsSourceKindCapability(
      kind: _str(json['kind']),
      title: _str(json['title'], _str(json['kind'])),
      description: _str(json['description']),
      accessMode: _str(json['accessMode'], 'passive_local_file'),
      requiresCredential: json['requiresCredential'] == true,
      supportsMultiAccount: json['supportsMultiAccount'] == true,
      supportsGuidedSetup: json['supportsGuidedSetup'] == true,
      supportsTestConnection: json['supportsTestConnection'] != false,
      provenanceNote: _optStr(json['provenanceNote']),
    );
  }
}

@immutable
class AiLimitsCapabilities {
  final String platform;
  final bool claudeStatusLineInstallerAvailable;
  final AiLimitsDetectedEnvironment detected;
  final List<AiLimitsSourceKindCapability> supportedSourceKinds;

  const AiLimitsCapabilities({
    this.platform = 'unknown',
    this.claudeStatusLineInstallerAvailable = false,
    this.detected = const AiLimitsDetectedEnvironment(),
    this.supportedSourceKinds = const [],
  });

  AiLimitsSourceKindCapability? kindInfo(String kind) {
    for (final s in supportedSourceKinds) {
      if (s.kind == kind) return s;
    }
    return null;
  }

  factory AiLimitsCapabilities.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AiLimitsCapabilities();
    return AiLimitsCapabilities(
      platform: _str(json['platform'], 'unknown'),
      claudeStatusLineInstallerAvailable: json['claudeStatusLineInstallerAvailable'] == true,
      detected: AiLimitsDetectedEnvironment.fromJson(
        json['detected'] is Map ? Map<String, dynamic>.from(json['detected'] as Map) : null,
      ),
      supportedSourceKinds: _mapList(json['supportedSourceKinds'])
          .map(AiLimitsSourceKindCapability.fromJson)
          .where((e) => e.kind.isNotEmpty)
          .toList(),
    );
  }
}

@immutable
class AiLimitsRefreshState {
  final int cooldownSeconds;
  final DateTime? nextRefreshAllowedAt;
  final int autoRefreshIntervalSeconds;
  final bool isRefreshing;

  const AiLimitsRefreshState({
    this.cooldownSeconds = 15,
    this.nextRefreshAllowedAt,
    this.autoRefreshIntervalSeconds = 180,
    this.isRefreshing = false,
  });

  int remainingCooldownSeconds({DateTime? now}) {
    final next = nextRefreshAllowedAt;
    if (next == null) return 0;
    final diff = next.toUtc().difference((now ?? DateTime.now()).toUtc());
    if (diff.isNegative || diff.inMilliseconds <= 0) return 0;
    return (diff.inMilliseconds / 1000).ceil();
  }

  factory AiLimitsRefreshState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AiLimitsRefreshState();
    return AiLimitsRefreshState(
      cooldownSeconds: _parseInt(json['cooldownSeconds']) ?? 15,
      nextRefreshAllowedAt: _parseDate(json['nextRefreshAllowedAt']),
      autoRefreshIntervalSeconds: _parseInt(json['autoRefreshIntervalSeconds']) ?? 180,
      isRefreshing: json['isRefreshing'] == true,
    );
  }
}

@immutable
class AiLimitsSource {
  final String id;
  final String kind;
  final String label;
  final bool enabled;
  final String accessMode;
  final String supportLevel;
  final bool hasCredential;
  final String? baseUrl;
  final bool allowNonLoopback;
  final String? configDir;
  final String? snapshotFile;
  final String? codexMode;
  final String? provider;
  final String? planLabel;
  final String? dashboardUrl;
  final int? dailyLimitHint;
  final int pollIntervalSeconds;
  final String status;
  final String? errorCode;
  final String? statusMessage;
  final String? detectedApiVersion;
  final DateTime? lastCheckedAt;
  final DateTime? lastSyncedAt;
  final DateTime? backoffUntil;
  final int? retryAfterSeconds;
  final int accountCount;

  const AiLimitsSource({
    required this.id,
    required this.kind,
    required this.label,
    this.enabled = true,
    this.accessMode = '',
    this.supportLevel = '',
    this.hasCredential = false,
    this.baseUrl,
    this.allowNonLoopback = false,
    this.configDir,
    this.snapshotFile,
    this.codexMode,
    this.provider,
    this.planLabel,
    this.dashboardUrl,
    this.dailyLimitHint,
    this.pollIntervalSeconds = 180,
    this.status = 'awaiting_data',
    this.errorCode,
    this.statusMessage,
    this.detectedApiVersion,
    this.lastCheckedAt,
    this.lastSyncedAt,
    this.backoffUntil,
    this.retryAfterSeconds,
    this.accountCount = 0,
  });

  bool get isConnected => enabled && status == 'connected';
  bool get needsAttention =>
      enabled &&
      (status == 'auth_required' ||
          status == 'rate_limited' ||
          status == 'offline' ||
          status == 'setup_required' ||
          status == 'error' ||
          status == 'degraded');

  factory AiLimitsSource.fromJson(Map<String, dynamic> json) {
    return AiLimitsSource(
      id: _str(json['id']),
      kind: _str(json['kind']),
      label: _str(json['label'], _str(json['kind'])),
      enabled: json['enabled'] != false,
      accessMode: _str(json['accessMode']),
      supportLevel: _str(json['supportLevel']),
      hasCredential: json['hasCredential'] == true,
      baseUrl: _optStr(json['baseUrl']),
      allowNonLoopback: json['allowNonLoopback'] == true,
      configDir: _optStr(json['configDir']),
      snapshotFile: _optStr(json['snapshotFile']),
      codexMode: _optStr(json['codexMode']),
      provider: _optStr(json['provider']),
      planLabel: _optStr(json['planLabel']),
      dashboardUrl: _optStr(json['dashboardUrl']),
      dailyLimitHint: _parseInt(json['dailyLimitHint']),
      pollIntervalSeconds: _parseInt(json['pollIntervalSeconds']) ?? 180,
      status: _str(json['status'], 'awaiting_data'),
      errorCode: _optStr(json['errorCode']),
      statusMessage: _optStr(json['statusMessage']),
      detectedApiVersion: _optStr(json['detectedApiVersion']),
      lastCheckedAt: _parseDate(json['lastCheckedAt']),
      lastSyncedAt: _parseDate(json['lastSyncedAt']),
      backoffUntil: _parseDate(json['backoffUntil']),
      retryAfterSeconds: _parseInt(json['retryAfterSeconds']),
      accountCount: _parseInt(json['accountCount']) ?? 0,
    );
  }
}

@immutable
class AiLimitsWindow {
  final String id;
  final String kind;
  final String label;
  final int? windowMinutes;
  final String unit;
  final String status;
  final double? usedPercent;
  final double? remainingPercent;
  final double? used;
  final double? limit;
  final DateTime? resetsAt;
  final String? modelPool;
  final bool? ordinaryUsageAllowed;
  final String? note;

  const AiLimitsWindow({
    required this.id,
    required this.kind,
    required this.label,
    this.windowMinutes,
    this.unit = 'percent',
    this.status = 'unavailable',
    this.usedPercent,
    this.remainingPercent,
    this.used,
    this.limit,
    this.resetsAt,
    this.modelPool,
    this.ordinaryUsageAllowed,
    this.note,
  });

  /// True only when a genuine percentage was reported by the backend (never fabricated).
  bool get hasPercent =>
      (status == 'available' || status == 'stale') &&
      (usedPercent != null || remainingPercent != null);

  double? get effectiveUsedPercent {
    if (usedPercent != null) return usedPercent!.clamp(0.0, 100.0);
    if (remainingPercent != null) return (100.0 - remainingPercent!).clamp(0.0, 100.0);
    return null;
  }

  double? get effectiveRemainingPercent {
    if (remainingPercent != null) return remainingPercent!.clamp(0.0, 100.0);
    if (usedPercent != null) return (100.0 - usedPercent!).clamp(0.0, 100.0);
    return null;
  }

  bool get isStale => status == 'stale';

  /// Main (account-wide) pool: `modelPool` is null, empty or "all". Extra Codex/CLIProxyAPI
  /// model buckets (ids like `pool:<slug>:five_hour`) carry their own pool name.
  bool get isMainPool {
    final p = modelPool?.trim().toLowerCase();
    return p == null || p.isEmpty || p == 'all';
  }

  /// The reported reset time already passed. The last reading is kept as stale,
  /// never auto-reset to 0% (the provider may not have opened a new window yet).
  bool isPastReset({DateTime? now}) {
    final r = resetsAt;
    if (r == null) return false;
    return r.toUtc().isBefore((now ?? DateTime.now()).toUtc());
  }

  /// Stale for display: backend-stale or the reset time passed without a new reading.
  bool isEffectivelyStale({DateTime? now}) => isStale || (hasPercent && isPastReset(now: now));

  bool get isNotApplicable => status == 'not_applicable';
  bool get isUnavailable => status == 'unavailable';
  bool get isRateLimited => status == 'rate_limited';
  bool get isAuthRequired => status == 'auth_required';
  bool get isNotConnected => status == 'not_connected';

  /// True when non-percent consumed metrics (requests, credits, usd, tokens) are reported.
  bool get hasNativeCount => unit != 'percent' && unit != 'none' && used != null;

  factory AiLimitsWindow.fromJson(Map<String, dynamic> json) {
    return AiLimitsWindow(
      id: _str(json['id'], _str(json['kind'])),
      kind: _str(json['kind'], 'custom'),
      label: _str(json['label'], _str(json['kind'])),
      windowMinutes: _parseInt(json['windowMinutes']),
      unit: _str(json['unit'], 'none'),
      status: _str(json['status'], 'unavailable'),
      usedPercent: _parseDouble(json['usedPercent']),
      remainingPercent: _parseDouble(json['remainingPercent']),
      used: _parseDouble(json['used']),
      limit: _parseDouble(json['limit']),
      resetsAt: _parseDate(json['resetsAt']),
      modelPool: _optStr(json['modelPool']),
      ordinaryUsageAllowed: _parseBool(json['ordinaryUsageAllowed']),
      note: _optStr(json['note']),
    );
  }
}

@immutable
class AiLimitsAccount {
  final String id;
  final String sourceId;
  final String sourceKind;
  final String provider;
  final String? product;
  final String providerLabel;
  final String alias;
  final String defaultAlias;
  final String? plan;
  final String? modelPool;
  final bool enabled;
  final String connectionStatus;
  final String quotaStatus;
  final String freshness;
  final String supportLevel;
  final String coverageScope;
  final String? provenanceLabel;
  final String? provenanceDetails;
  final DateTime? observedAt;
  final int? staleAfterSeconds;
  final DateTime? cooldownUntil;
  final DateTime? backoffUntil;
  final bool? ordinaryUsageAllowed;
  final String? dashboardUrl;
  final String? errorCode;
  final String? statusMessage;
  final List<AiLimitsWindow> windows;

  const AiLimitsAccount({
    required this.id,
    required this.sourceId,
    required this.sourceKind,
    required this.provider,
    this.product,
    required this.providerLabel,
    required this.alias,
    this.defaultAlias = '',
    this.plan,
    this.modelPool,
    this.enabled = true,
    this.connectionStatus = 'connected',
    this.quotaStatus = 'unavailable',
    this.freshness = 'unavailable',
    this.supportLevel = '',
    this.coverageScope = 'none',
    this.provenanceLabel,
    this.provenanceDetails,
    this.observedAt,
    this.staleAfterSeconds,
    this.cooldownUntil,
    this.backoffUntil,
    this.ordinaryUsageAllowed,
    this.dashboardUrl,
    this.errorCode,
    this.statusMessage,
    this.windows = const [],
  });

  String get displayTitle =>
      alias.isEmpty || alias.toLowerCase() == providerLabel.toLowerCase()
          ? providerLabel
          : '$providerLabel · $alias';

  /// Green connected indicator ONLY when source/account reachability & auth are valid.
  bool get isConnectionHealthy => enabled && connectionStatus == 'connected';

  bool get isAuthRequired =>
      connectionStatus == 'auth_required' || quotaStatus == 'auth_required';

  bool get isRateLimited => quotaStatus == 'rate_limited' || quotaStatus == 'cooldown';

  bool get isStale => quotaStatus == 'stale' || freshness == 'stale';

  bool get isOffline => connectionStatus == 'offline' || connectionStatus == 'unavailable';

  bool get hasLivePercentReading =>
      windows.any((w) => w.status == 'available' && w.hasPercent);

  AiLimitsWindow? windowByKind(String kind) {
    for (final w in windows) {
      if (w.kind == kind) return w;
    }
    return null;
  }

  /// Distinct extra model pools (besides the main pool) reported for this account, in
  /// backend order. Empty for most accounts.
  List<String> get extraPools {
    final seen = <String>[];
    for (final w in windows) {
      if (w.isMainPool) continue;
      final p = w.modelPool!.trim();
      if (!seen.contains(p)) seen.add(p);
    }
    return seen;
  }

  bool _inPool(AiLimitsWindow w, String? pool) =>
      pool == null || pool.isEmpty ? w.isMainPool : w.modelPool?.trim() == pool;

  /// Selects ordered windows matching tile preferences without inventing missing windows.
  ///
  /// Picks at most ONE window per requested kind, from [pool] when given (an extra model
  /// pool name) or from the main pool (`modelPool` null/"all") otherwise. A window from
  /// another pool is used only when the chosen pool has none of that kind. Percentages
  /// are never summed across pools or accounts.
  List<AiLimitsWindow> selectWindows(
    List<String> preferredKinds, {
    int maxCount = 2,
    String? pool,
  }) {
    if (windows.isEmpty || maxCount <= 0) return const [];
    // Chosen pool first, then the main pool, then everything else; stable inside each.
    int rank(AiLimitsWindow w) => _inPool(w, pool) ? 0 : (w.isMainPool ? 1 : 2);
    final ordered = [
      for (var r = 0; r < 3; r++) ...windows.where((w) => rank(w) == r),
    ];

    if (preferredKinds.isEmpty) {
      // "All windows": the chosen pool's windows, then other pools', one per kind+pool.
      final seen = <String>{};
      final picked = <AiLimitsWindow>[];
      for (final w in ordered) {
        if (seen.add('${w.kind}|${w.isMainPool ? '' : w.modelPool}')) picked.add(w);
        if (picked.length >= maxCount) break;
      }
      return picked;
    }

    final picked = <AiLimitsWindow>[];
    for (final kind in preferredKinds.toSet()) {
      final match = ordered.where((w) => w.kind == kind).firstOrNull;
      if (match != null) picked.add(match);
      if (picked.length >= maxCount) return picked;
    }
    // If neither 5h nor weekly exists (e.g. Gemini CLI daily local count or Copilot credits),
    // fall back to the account's native reported windows (one per kind) rather than an
    // empty box.
    if (picked.isEmpty) {
      final kinds = <String>{};
      for (final w in ordered) {
        if (kinds.add(w.kind)) picked.add(w);
        if (picked.length >= maxCount) break;
      }
    }
    return picked;
  }

  /// Earliest UPCOMING reset among windows. Past resets are ignored (they mean the
  /// reading is stale, not that a reset is about to happen).
  DateTime? nextResetAfter(DateTime now, {Iterable<AiLimitsWindow>? among}) {
    DateTime? earliest;
    for (final w in among ?? windows) {
      final r = w.resetsAt;
      if (r == null || !r.toUtc().isAfter(now.toUtc())) continue;
      if (earliest == null || r.isBefore(earliest)) earliest = r;
    }
    return earliest;
  }

  DateTime? get nextResetAt => nextResetAfter(DateTime.now());

  /// Provider said ordinary usage is blocked (on the account or any main-pool window).
  /// Shown even when the reset timer already ran out: only a new reading clears it.
  bool get isUsageBlocked =>
      ordinaryUsageAllowed == false ||
      windows.any((w) => w.isMainPool && w.ordinaryUsageAllowed == false);

  factory AiLimitsAccount.fromJson(Map<String, dynamic> json) {
    final provider = _str(json['provider'], 'other');
    final providerLabel = _str(json['providerLabel'], provider);
    final alias = _str(json['alias'], _str(json['defaultAlias'], providerLabel));
    return AiLimitsAccount(
      id: _str(json['id']),
      sourceId: _str(json['sourceId']),
      sourceKind: _str(json['sourceKind']),
      provider: provider,
      product: _optStr(json['product']),
      providerLabel: providerLabel,
      alias: alias,
      defaultAlias: _str(json['defaultAlias'], alias),
      plan: _optStr(json['plan']),
      modelPool: _optStr(json['modelPool']),
      enabled: json['enabled'] != false,
      connectionStatus: _str(json['connectionStatus'], 'unavailable'),
      quotaStatus: _str(json['quotaStatus'], 'unavailable'),
      freshness: _str(json['freshness'], 'unavailable'),
      supportLevel: _str(json['supportLevel']),
      coverageScope: _str(json['coverageScope'], 'none'),
      provenanceLabel: _optStr(json['provenanceLabel']),
      provenanceDetails: _optStr(json['provenanceDetails']),
      observedAt: _parseDate(json['observedAt']),
      staleAfterSeconds: _parseInt(json['staleAfterSeconds']),
      cooldownUntil: _parseDate(json['cooldownUntil']),
      backoffUntil: _parseDate(json['backoffUntil']),
      ordinaryUsageAllowed: _parseBool(json['ordinaryUsageAllowed']),
      dashboardUrl: _optStr(json['dashboardUrl']),
      errorCode: _optStr(json['errorCode']),
      statusMessage: _optStr(json['statusMessage']),
      windows: _mapList(json['windows']).map(AiLimitsWindow.fromJson).toList(),
    );
  }
}

@immutable
class AiLimitsSnapshot {
  final int schemaVersion;
  final DateTime? generatedAt;
  final AiLimitsCapabilities capabilities;
  final AiLimitsRefreshState refresh;
  final List<AiLimitsSource> sources;
  final List<AiLimitsAccount> accounts;

  const AiLimitsSnapshot({
    this.schemaVersion = 1,
    this.generatedAt,
    this.capabilities = const AiLimitsCapabilities(),
    this.refresh = const AiLimitsRefreshState(),
    this.sources = const [],
    this.accounts = const [],
  });

  AiLimitsAccount? accountById(String id) {
    if (id.isEmpty) return null;
    for (final a in accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  AiLimitsSource? sourceById(String id) {
    if (id.isEmpty) return null;
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<AiLimitsAccount> get enabledAccounts =>
      accounts.where((a) => a.enabled).toList();

  int get connectedSourceCount => sources.where((s) => s.isConnected).length;
  int get attentionSourceCount => sources.where((s) => s.needsAttention).length;

  /// True ONLY when at least one enabled account has a genuine live reading.
  bool get hasAnyLiveReading =>
      accounts.any((a) => a.enabled && a.hasLivePercentReading);

  factory AiLimitsSnapshot.fromJson(Map<String, dynamic> json) {
    return AiLimitsSnapshot(
      schemaVersion: _parseInt(json['schemaVersion']) ?? 1,
      generatedAt: _parseDate(json['generatedAt']),
      capabilities: AiLimitsCapabilities.fromJson(
        json['capabilities'] is Map
            ? Map<String, dynamic>.from(json['capabilities'] as Map)
            : null,
      ),
      refresh: AiLimitsRefreshState.fromJson(
        json['refresh'] is Map
            ? Map<String, dynamic>.from(json['refresh'] as Map)
            : null,
      ),
      sources: _mapList(json['sources']).map(AiLimitsSource.fromJson).toList(),
      accounts: _mapList(json['accounts']).map(AiLimitsAccount.fromJson).toList(),
    );
  }
}

/// Request payload for testing or saving a source.
/// [credential] is sent once over DeckOS's authenticated channel and never persisted client-side.
@immutable
class AiLimitsSourceDraft {
  final String? sourceId;
  final String kind;
  final String label;
  final bool enabled;
  final String? baseUrl;
  final bool allowNonLoopback;
  final String? credential;
  final bool clearCredential;
  final String? configDir;
  final String? snapshotFile;
  final String? codexMode;
  final String? provider;
  final String? planLabel;
  final String? dashboardUrl;
  final int? dailyLimitHint;
  final int? pollIntervalSeconds;

  const AiLimitsSourceDraft({
    this.sourceId,
    required this.kind,
    required this.label,
    this.enabled = true,
    this.baseUrl,
    this.allowNonLoopback = false,
    this.credential,
    this.clearCredential = false,
    this.configDir,
    this.snapshotFile,
    this.codexMode,
    this.provider,
    this.planLabel,
    this.dashboardUrl,
    this.dailyLimitHint,
    this.pollIntervalSeconds,
  });

  Map<String, dynamic> toTestJson() => {
        if (sourceId != null && sourceId!.isNotEmpty) 'sourceId': sourceId,
        'kind': kind,
        'label': label.trim(),
        if (baseUrl != null && baseUrl!.trim().isNotEmpty) 'baseUrl': baseUrl!.trim(),
        'allowNonLoopback': allowNonLoopback,
        if (credential != null && credential!.trim().isNotEmpty)
          'credential': credential!.trim(),
        if (configDir != null && configDir!.trim().isNotEmpty)
          'configDir': configDir!.trim(),
        if (snapshotFile != null && snapshotFile!.trim().isNotEmpty)
          'snapshotFile': snapshotFile!.trim(),
        if (codexMode != null && codexMode!.trim().isNotEmpty)
          'codexMode': codexMode!.trim(),
        if (provider != null && provider!.trim().isNotEmpty)
          'provider': provider!.trim(),
        if (planLabel != null && planLabel!.trim().isNotEmpty)
          'planLabel': planLabel!.trim(),
        if (dashboardUrl != null && dashboardUrl!.trim().isNotEmpty)
          'dashboardUrl': dashboardUrl!.trim(),
        if (dailyLimitHint != null) 'dailyLimitHint': dailyLimitHint,
      };

  Map<String, dynamic> toUpsertJson() => {
        ...toTestJson(),
        'enabled': enabled,
        if (pollIntervalSeconds != null) 'pollIntervalSeconds': pollIntervalSeconds,
        if (clearCredential) 'clearCredential': true,
      };
}

@immutable
class AiLimitsSourceTestResult {
  final bool ok;
  final bool reachable;
  final String status;
  final String? errorCode;
  final String message;
  final String? detectedApiVersion;
  final String? capabilitiesNote;
  final List<AiLimitsAccount> accounts;

  const AiLimitsSourceTestResult({
    required this.ok,
    required this.reachable,
    required this.status,
    this.errorCode,
    required this.message,
    this.detectedApiVersion,
    this.capabilitiesNote,
    this.accounts = const [],
  });

  factory AiLimitsSourceTestResult.fromJson(Map<String, dynamic> json) {
    return AiLimitsSourceTestResult(
      ok: json['ok'] == true,
      reachable: json['reachable'] == true,
      status: _str(json['status'], 'error'),
      errorCode: _optStr(json['errorCode']),
      message: _str(json['message']),
      detectedApiVersion: _optStr(json['detectedApiVersion']),
      capabilitiesNote: _optStr(json['capabilitiesNote']),
      accounts: _mapList(json['accounts']).map(AiLimitsAccount.fromJson).toList(),
    );
  }
}

@immutable
class AiLimitsSourceMutationResult {
  final AiLimitsSource source;
  final List<AiLimitsAccount> accounts;
  final AiLimitsSnapshot snapshot;

  const AiLimitsSourceMutationResult({
    required this.source,
    required this.accounts,
    required this.snapshot,
  });

  factory AiLimitsSourceMutationResult.fromJson(Map<String, dynamic> json) {
    return AiLimitsSourceMutationResult(
      source: AiLimitsSource.fromJson(
        Map<String, dynamic>.from(json['source'] as Map),
      ),
      accounts: _mapList(json['accounts']).map(AiLimitsAccount.fromJson).toList(),
      snapshot: AiLimitsSnapshot.fromJson(
        Map<String, dynamic>.from(json['snapshot'] as Map),
      ),
    );
  }
}

@immutable
class AiLimitsAccountMutationResult {
  final AiLimitsAccount account;
  final AiLimitsSnapshot snapshot;

  const AiLimitsAccountMutationResult({
    required this.account,
    required this.snapshot,
  });

  factory AiLimitsAccountMutationResult.fromJson(Map<String, dynamic> json) {
    return AiLimitsAccountMutationResult(
      account: AiLimitsAccount.fromJson(
        Map<String, dynamic>.from(json['account'] as Map),
      ),
      snapshot: AiLimitsSnapshot.fromJson(
        Map<String, dynamic>.from(json['snapshot'] as Map),
      ),
    );
  }
}

@immutable
class AiLimitsRefreshResult {
  final AiLimitsSnapshot snapshot;
  final bool throttled;
  final int? retryAfterSeconds;
  final DateTime? nextRefreshAllowedAt;
  final String? message;

  const AiLimitsRefreshResult({
    required this.snapshot,
    this.throttled = false,
    this.retryAfterSeconds,
    this.nextRefreshAllowedAt,
    this.message,
  });
}

@immutable
class AiLimitsSetupGuide {
  final String sourceId;
  final String kind;
  final bool supported;
  final bool isInstalled;
  final bool hasExistingUserHook;
  final bool canAutoInstall;
  final List<String> steps;
  final List<String> caveats;
  final String? commandPreview;

  /// Set when the PC refused a setup action (for example `internal_error` when Claude's
  /// settings.json isn't plain JSON and was left untouched). Null normally.
  final String? errorCode;
  final String? message;

  const AiLimitsSetupGuide({
    required this.sourceId,
    required this.kind,
    this.supported = false,
    this.isInstalled = false,
    this.hasExistingUserHook = false,
    this.canAutoInstall = false,
    this.steps = const [],
    this.caveats = const [],
    this.commandPreview,
    this.errorCode,
    this.message,
  });

  bool get hasError => errorCode != null;

  factory AiLimitsSetupGuide.fromJson(Map<String, dynamic> json) {
    return AiLimitsSetupGuide(
      sourceId: _str(json['sourceId']),
      kind: _str(json['kind']),
      supported: json['supported'] == true,
      isInstalled: json['isInstalled'] == true,
      hasExistingUserHook: json['hasExistingUserHook'] == true,
      canAutoInstall: json['canAutoInstall'] == true,
      steps: _strList(json['steps']),
      caveats: _strList(json['caveats']),
      commandPreview: _optStr(json['commandPreview']),
      errorCode: _optStr(json['errorCode']),
      message: _optStr(json['message']),
    );
  }
}

class AiLimitsApiException implements Exception {
  final String message;
  final String? errorCode;
  final int? statusCode;
  final int? retryAfterSeconds;

  const AiLimitsApiException(
    this.message, {
    this.errorCode,
    this.statusCode,
    this.retryAfterSeconds,
  });

  @override
  String toString() => message;
}
