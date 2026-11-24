import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import '../connection/pc_store.dart';
import 'package:deckos/src/stream_deck/layout/grid_placement.dart';
import 'package:deckos/src/stream_deck/layout/slot_ops.dart';

import 'ai_limits_client.dart';
import 'ai_account_privacy.dart';
import 'ai_limits_models.dart';
import 'ai_provider_style.dart';

/// Reactive store for live AI Limits snapshots across tiles, editor, and settings.
/// Keeps all state strictly in-memory (never caches credentials or raw payloads in SharedPreferences).
class AiLimitsStore {
  AiLimitsStore({AiLimitsClient? client}) : _client = client ?? AiLimitsClient();

  static AiLimitsStore _instance = AiLimitsStore();
  static AiLimitsStore get instance => _instance;

  /// Allows tests to inject a clean store backed by a mock client.
  static void resetForTest({AiLimitsClient? client}) {
    _instance.dispose();
    _instance = AiLimitsStore(client: client);
  }

  static const signalREvent = 'ReceiveAiLimitsState';

  final AiLimitsClient _client;

  final snapshot = signal<AiLimitsSnapshot?>(null);
  final isLoading = signal<bool>(false);
  final isRefreshing = signal<bool>(false);
  final error = signal<String?>(null);
  final lastNotice = signal<String?>(null);
  final cooldownUntil = signal<DateTime?>(null);

  bool _boundSignalR = false;
  bool _hasLoadedOnce = false;
  Future<void>? _inFlightLoad;
  Future<AiLimitsRefreshResult?>? _inFlightRefresh;
  void Function()? _signalRCleanup;
  void Function()? _reconnectCleanup;
  Object? _connectionIdentity;

  /// Ensures SignalR listener is bound and triggers a single initial load if not yet loaded.
  void ensureInitialized() {
    _bindSignalR();
    if (!_hasLoadedOnce && snapshot.value == null && _inFlightLoad == null) {
      unawaited(load());
    }
  }

  void _bindSignalR() {
    final identity = _client.connectionIdentity;
    if (identity != _connectionIdentity) {
      dispose();
      _connectionIdentity = identity;
      AiAccountPrivacy.hideNames.value = true;
      snapshot.value = null;
      error.value = null;
      lastNotice.value = null;
      cooldownUntil.value = null;
      isLoading.value = false;
      isRefreshing.value = false;
      _hasLoadedOnce = false;
      _inFlightLoad = null;
      _inFlightRefresh = null;
    }
    if (_boundSignalR) return;
    SignalRService? signalR;
    try {
      signalR = Injector.get<SignalRService>();
    } catch (_) {
      return;
    }
    _boundSignalR = true;
    signalR.listenState(signalREvent);

    // Apply any state already pushed by SignalR before first widget mounted.
    final initial = signalR.stateOf(signalREvent);
    if (initial.isNotEmpty) {
      _applySignalRPayload(initial);
    }

    int? lastReceivedAt;
    _signalRCleanup = effect(() {
      final state = signalR!.stateOf(signalREvent);
      if (state.isEmpty) return;
      final ts = state['_receivedAt'] as int?;
      if (ts != null && ts == lastReceivedAt) return;
      lastReceivedAt = ts;
      untracked(() => _applySignalRPayload(state));
    });

    var wasConnected = signalR.connectionStatus.value == 'Connected';
    _reconnectCleanup = effect(() {
      final connected = signalR!.connectionStatus.value == 'Connected';
      if (connected && !wasConnected) {
        untracked(() => unawaited(load(silent: true)));
      }
      wasConnected = connected;
    });
  }

  void _applySignalRPayload(Map<String, dynamic> raw) {
    if (!raw.containsKey('sources') && !raw.containsKey('accounts')) return;
    try {
      final parsed = AiLimitsSnapshot.fromJson(raw);
      _applySnapshot(parsed);
      _hasLoadedOnce = true;
      error.value = null;
    } catch (_) {
      // Ignore malformed partial push; keep last known good snapshot.
    }
  }

  void _applySnapshot(AiLimitsSnapshot next) {
    final previousTime = snapshot.value?.generatedAt;
    final incomingTime = next.generatedAt;
    // A delayed refresh or hub push must not undo a newer privacy/alias change.
    if (previousTime != null && incomingTime != null && incomingTime.isBefore(previousTime)) return;
    AiAccountPrivacy.hideNames.value = next.hideAccountNames;
    snapshot.value = next;
    cooldownUntil.value = next.refresh.nextRefreshAllowedAt;
    isRefreshing.value = next.refresh.isRefreshing;
  }

  Future<void> load({bool silent = false}) {
    _bindSignalR();
    final existing = _inFlightLoad;
    if (existing != null) return existing;
    final identity = _connectionIdentity;
    final task = _doLoad(silent: silent).whenComplete(() {
      if (identity == _connectionIdentity) _inFlightLoad = null;
    });
    _inFlightLoad = task;
    return task;
  }

  Future<void> _doLoad({required bool silent}) async {
    final identity = _client.connectionIdentity;
    if (!silent && snapshot.value == null) isLoading.value = true;
    try {
      final next = await _client.getSnapshot();
      _applySnapshot(next);
      error.value = null;
      _hasLoadedOnce = true;
    } on AiLimitsApiException catch (e) {
      if (identity == _client.connectionIdentity) error.value = e.message;
    } catch (_) {
      if (identity == _client.connectionIdentity) {
        error.value = tr('O PC não respondeu. Confira se o DeckOS está aberto nele.');
      }
    } finally {
      if (identity == _client.connectionIdentity) isLoading.value = false;
    }
  }

  int remainingCooldownSeconds({DateTime? now}) {
    final current = (now ?? DateTime.now()).toUtc();
    final localUntil = cooldownUntil.value;
    final snapUntil = snapshot.value?.refresh.nextRefreshAllowedAt;
    DateTime? latest = localUntil;
    if (snapUntil != null && (latest == null || snapUntil.isAfter(latest))) {
      latest = snapUntil;
    }
    if (latest == null) return 0;
    final diff = latest.toUtc().difference(current);
    if (diff.isNegative || diff.inMilliseconds <= 0) return 0;
    return (diff.inMilliseconds / 1000).ceil();
  }

  /// Triggers a bounded manual refresh respecting server cooldown (never storms).
  Future<AiLimitsRefreshResult?> refresh({String? sourceId}) {
    _bindSignalR();
    final existing = _inFlightRefresh;
    if (existing != null) return existing;
    final wait = remainingCooldownSeconds();
    if (wait > 0 && snapshot.value != null) {
      final result = AiLimitsRefreshResult(
        snapshot: snapshot.value!,
        throttled: true,
        retryAfterSeconds: wait,
        nextRefreshAllowedAt: cooldownUntil.value,
        message: tr('Aguarde {s}s antes de atualizar de novo.', {'s': '$wait'}),
      );
      lastNotice.value = result.message;
      return Future.value(result);
    }
    final identity = _connectionIdentity;
    final task = _doRefresh(sourceId: sourceId).whenComplete(() {
      if (identity == _connectionIdentity) _inFlightRefresh = null;
    });
    _inFlightRefresh = task;
    return task;
  }

  Future<AiLimitsRefreshResult?> _doRefresh({String? sourceId}) async {
    final identity = _client.connectionIdentity;
    isRefreshing.value = true;
    lastNotice.value = null;
    try {
      final result = await _client.refresh(sourceId: sourceId);
      _applySnapshot(result.snapshot);
      if (result.nextRefreshAllowedAt != null) {
        cooldownUntil.value = result.nextRefreshAllowedAt;
      } else if (result.retryAfterSeconds != null && result.retryAfterSeconds! > 0) {
        cooldownUntil.value = DateTime.now()
            .toUtc()
            .add(Duration(seconds: result.retryAfterSeconds!));
      } else if (result.snapshot.refresh.cooldownSeconds > 0) {
        cooldownUntil.value = DateTime.now()
            .toUtc()
            .add(Duration(seconds: result.snapshot.refresh.cooldownSeconds));
      }
      if (result.throttled) {
        lastNotice.value = result.message ??
            tr('Aguarde {s}s antes de atualizar de novo.', {
              's': '${result.retryAfterSeconds ?? result.snapshot.refresh.cooldownSeconds}',
            });
      }
      error.value = null;
      return result;
    } on AiLimitsApiException catch (e) {
      if (identity != _client.connectionIdentity) return null;
      error.value = e.message;
      lastNotice.value = e.message;
      return null;
    } finally {
      if (identity == _client.connectionIdentity) isRefreshing.value = false;
    }
  }

  Future<AiLimitsSourceTestResult> testSource(AiLimitsSourceDraft draft) =>
      _client.testSource(draft);

  Future<AiLimitsSourceMutationResult> createSource(AiLimitsSourceDraft draft) async {
    final res = await _client.createSource(draft);
    _applySnapshot(res.snapshot);
    error.value = null;
    return res;
  }

  Future<AiLimitsSourceMutationResult> updateSource(
    String sourceId,
    AiLimitsSourceDraft draft,
  ) async {
    final res = await _client.updateSource(sourceId, draft);
    _applySnapshot(res.snapshot);
    error.value = null;
    return res;
  }

  Future<void> deleteSource(String sourceId) async {
    final snap = await _client.deleteSource(sourceId);
    _applySnapshot(snap);
    error.value = null;
  }

  Future<AiLimitsAccount> updateAccount(
    String accountId, {
    String? alias,
    bool? enabled,
    String? plan,
    String? dashboardUrl,
  }) async {
    final res = await _client.updateAccount(
      accountId,
      alias: alias,
      enabled: enabled,
      plan: plan,
      dashboardUrl: dashboardUrl,
    );
    _applySnapshot(res.snapshot);
    error.value = null;
    return res.account;
  }

  Future<void> updatePrivacy(bool hideAccountNames) async {
    final next = await _client.updatePrivacy(hideAccountNames);
    _applySnapshot(next);
    error.value = null;
  }

  Future<void> removeAccount(String accountId) async {
    final snap = await _client.removeAccount(accountId);
    _applySnapshot(snap);
    error.value = null;
  }

  Future<AiLimitsSetupGuide> getSetupGuide(String sourceId) =>
      _client.getSetupGuide(sourceId);

  Future<AiLimitsSetupGuide> installHook(String sourceId) async {
    final res = await _client.installHook(sourceId);
    if (res.snapshot != null) {
      _applySnapshot(res.snapshot!);
    } else {
      unawaited(load(silent: true));
    }
    return res.setup;
  }

  Future<AiLimitsSetupGuide> uninstallHook(String sourceId) async {
    final res = await _client.uninstallHook(sourceId);
    if (res.snapshot != null) {
      _applySnapshot(res.snapshot!);
    } else {
      unawaited(load(silent: true));
    }
    return res.setup;
  }

  /// Creates a secret-free movable/resizable [DeckButton] bound to [account].
  static DeckButton buildAccountTileButton(
    AiLimitsAccount account, {
    required int row,
    required int column,
    int columnSpan = 2,
    int rowSpan = 1,
    String displayMode = 'used',
    String windows = 'five_hour,weekly',
    bool showReset = true,
    String density = 'comfortable',
  }) {
    final cfg = AiLimitsTileConfig(
      accountId: account.id,
      sourceId: account.sourceId,
      providerHint: account.provider,
      // Profiles/backups must not persist provider-reported personal names.
      aliasHint: account.defaultAlias,
      displayMode: displayMode,
      windows: windows,
      showReset: showReset,
      density: density,
    );
    return DeckButton(
      id: 'ai_lim_${DateTime.now().microsecondsSinceEpoch}_${account.id.hashCode.abs()}',
      row: row,
      column: column,
      columnSpan: columnSpan,
      rowSpan: rowSpan,
      label: '',
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: cfg.toParams(),
    );
  }

  /// Appends real movable quota tiles (defaulting to wide 2×1 when it fits, else 1×1)
  /// to an "AI Usage" deck profile using normal DeckOS profile persistence.
  /// Never modifies or deletes any existing user pages or `ai_limits_demo`.
  static Future<({DeckProfile profile, int added})> addAccountsToAiUsagePage(
    List<AiLimitsAccount> accounts, {
    DeckOSClient? client,
  }) async {
    final api = client ?? Injector.get<DeckOSClient>();
    final profiles = await api.getProfiles();
    final layout = await api.getLayout();
    final baseCols = (layout?['columns'] ?? 4).clamp(2, 10);
    final baseRows = (layout?['rows'] ?? 2).clamp(2, 10);

    // Find an existing real AI Usage page (explicitly excluding `ai_limits_demo`).
    DeckProfile? target;
    for (final p in profiles) {
      if (p.id == 'ai_limits_demo') continue;
      final lower = p.name.trim().toLowerCase();
      if (p.id == 'ai_usage' || lower == 'ai usage' || lower == 'uso de ia') {
        target = p;
        break;
      }
    }

    target ??= DeckProfile(
      id: 'ai_usage',
      name: aiLimitsDefaultPageName,
      rows: baseRows,
      columns: baseCols,
      buttons: const [],
    );

    final buttons = List<DeckButton>.from(target.buttons);
    final existingAccountIds = {
      for (final b in buttons)
        if (b.dynamicType == aiLimitsDynamicType)
          AiLimitsTileConfig.fromParams(b.dynamicParameters).accountId,
    };

    var cols = target.columns < baseCols ? baseCols : target.columns;
    var rows = target.rows < baseRows ? baseRows : target.rows;
    final minExisting = SlotOps.minGrid(buttons);
    if (minExisting.columns > cols) cols = minExisting.columns;
    if (minExisting.rows > rows) rows = minExisting.rows;

    final preferredSpan = cols >= 2 ? 2 : 1;
    var added = 0;

    for (final acct in accounts) {
      if (acct.id.isEmpty || existingAccountIds.contains(acct.id)) continue;
      final placement = _findSlotForSpan(
        buttons,
        rows: rows,
        cols: cols,
        colSpan: preferredSpan,
      );
      if (placement.row + 1 > rows) {
        rows = placement.row + 1;
      }
      buttons.add(buildAccountTileButton(
        acct,
        row: placement.row,
        column: placement.column,
        columnSpan: placement.colSpan,
        rowSpan: 1,
      ));
      existingAccountIds.add(acct.id);
      added++;
    }

    final updated = target.copyWith(
      rows: rows.clamp(1, 10),
      columns: cols.clamp(1, 10),
      buttons: buttons,
    );
    await api.saveProfile(updated);
    return (profile: updated, added: added);
  }

  /// Add an overview page without modifying existing tiles or page layouts.
  static Future<DeckProfile> addCombinedAccountsPage(List<AiLimitsAccount> accounts, {DeckOSClient? client}) async {
    final api = client ?? Injector.get<DeckOSClient>();
    final identity = (api, api.currentBaseUrl, PcStore.currentId);
    final profiles = await api.getProfiles();
    final layout = await api.getLayout();
    if (identity != (api, api.currentBaseUrl, PcStore.currentId)) {
      throw AiLimitsApiException(tr('O PC ativo mudou. Nada foi enviado; abra esta tela de novo no PC certo.'));
    }
    final existing = profiles.where((p) => p.id == 'ai_overview').firstOrNull;
    if (existing != null && existing.buttons.any((b) => b.dynamicType == aiLimitsDynamicType && AiLimitsTileConfig.fromParams(b.dynamicParameters).combined)) return existing;
    final cols = ((layout?['columns'] as num?)?.toInt() ?? 4).clamp(2, 10);
    final profile = DeckProfile(
      id: existing == null ? 'ai_overview' : 'ai_overview_${DateTime.now().millisecondsSinceEpoch}',
      name: tr('Visão geral de IA'), columns: cols, rows: 3, customColumns: cols, customRows: 3,
      buttons: [DeckButton(
        id: 'ai_combined_${DateTime.now().microsecondsSinceEpoch}', row: 0, column: 0,
        columnSpan: cols, rowSpan: 3, dynamicType: aiLimitsDynamicType,
        dynamicParameters: AiLimitsTileConfig(combined: true, accountIds: accounts.map((a) => a.id).toSet().toList()).toParams(),
      )],
    );
    await api.saveProfile(profile);
    return profile;
  }

  static ({int row, int column, int colSpan}) _findSlotForSpan(
    List<DeckButton> buttons, {
    required int rows,
    required int cols,
    required int colSpan,
  }) {
    final maxSearchRows = rows + 8;
    final layout = GridLayout.of(buttons, maxSearchRows, cols);
    final anchors = {for (final b in buttons) GridLayout.key(b.row, b.column)};
    bool isCellFree(int r, int c) =>
        layout.isFree(r, c) && !anchors.contains(GridLayout.key(r, c));

    // Try placing with preferred colSpan (2x1 when fits) in reading order.
    for (var r = 0; r < maxSearchRows; r++) {
      for (var c = 0; c <= cols - colSpan; c++) {
        var fits = true;
        for (var dx = 0; dx < colSpan; dx++) {
          if (!isCellFree(r, c + dx)) {
            fits = false;
            break;
          }
        }
        if (fits) return (row: r, column: c, colSpan: colSpan);
      }
    }
    // Fallback to 1x1 in first free cell.
    final fallback = SlotOps.firstEmpty(buttons, maxSearchRows, cols);
    if (fallback != null) {
      return (row: fallback.row, column: fallback.column, colSpan: 1);
    }
    return (row: rows, column: 0, colSpan: colSpan.clamp(1, cols));
  }

  void dispose() {
    _signalRCleanup?.call();
    _reconnectCleanup?.call();
    _signalRCleanup = null;
    _reconnectCleanup = null;
    _boundSignalR = false;
  }
}
