import 'package:deckos/core/core.dart';
import 'package:deckos/src/connection/pc_store.dart';

import 'ai_limits_models.dart';

/// Typed REST client for `/api/ai-limits`, reusing [DeckOSClient]'s existing
/// authentication (`X-API-KEY`), language header, and USB/LAN PC routing
/// without broadening legacy core client APIs.
class AiLimitsClient {
  AiLimitsClient([DeckOSClient? client]) : _overrideClient = client;

  final DeckOSClient? _overrideClient;

  DeckOSClient get _client => _overrideClient ?? Injector.get<DeckOSClient>();

  Object get connectionIdentity => (_client, _client.currentBaseUrl, PcStore.currentId);

  Future<dynamic> _onHost(Future<dynamic> Function(DeckOSClient) send) async {
    final identity = connectionIdentity;
    final result = await send(_client);
    if (connectionIdentity != identity) {
      throw AiLimitsApiException(tr('O PC ativo mudou. Nada foi enviado; abra esta tela de novo no PC certo.'));
    }
    return result;
  }

  Future<dynamic> _getJson(String path) => _onHost((c) => c.getJson(path));
  Future<dynamic> _postJson(String path, dynamic data) => _onHost((c) => c.postJson(path, data));
  Future<dynamic> _putJson(String path, dynamic data) => _onHost((c) => c.putJson(path, data));
  Future<dynamic> _deleteJson(String path) => _onHost((c) => c.deleteJson(path));

  static const _base = '/api/ai-limits';

  Future<AiLimitsSnapshot> getSnapshot() async {
    try {
      final raw = await _getJson(_base);
      return AiLimitsSnapshot.fromJson(Map<String, dynamic>.from(raw as Map));
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<AiLimitsSourceTestResult> testSource(AiLimitsSourceDraft draft) async {
    try {
      final raw = await _postJson('$_base/sources/test', draft.toTestJson());
      return AiLimitsSourceTestResult.fromJson(Map<String, dynamic>.from(raw as Map));
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<AiLimitsSourceMutationResult> createSource(AiLimitsSourceDraft draft) async {
    try {
      final raw = await _postJson('$_base/sources', draft.toUpsertJson());
      return AiLimitsSourceMutationResult.fromJson(Map<String, dynamic>.from(raw as Map));
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<AiLimitsSourceMutationResult> updateSource(
    String sourceId,
    AiLimitsSourceDraft draft,
  ) async {
    try {
      final raw = await _putJson(
        '$_base/sources/${Uri.encodeComponent(sourceId)}',
        draft.toUpsertJson(),
      );
      return AiLimitsSourceMutationResult.fromJson(Map<String, dynamic>.from(raw as Map));
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<AiLimitsSnapshot> deleteSource(String sourceId) async {
    try {
      final raw = await _deleteJson(
        '$_base/sources/${Uri.encodeComponent(sourceId)}',
      );
      final map = Map<String, dynamic>.from(raw as Map);
      return AiLimitsSnapshot.fromJson(
        Map<String, dynamic>.from(map['snapshot'] as Map),
      );
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<AiLimitsRefreshResult> refresh({String? sourceId}) async {
    final path = sourceId != null && sourceId.isNotEmpty
        ? '$_base/sources/${Uri.encodeComponent(sourceId)}/refresh'
        : '$_base/refresh';
    try {
      final raw = await _postJson(path, const <String, dynamic>{});
      final snap = AiLimitsSnapshot.fromJson(Map<String, dynamic>.from(raw as Map));
      return AiLimitsRefreshResult(snapshot: snap);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final data = e.response?.data;
      if (code == 429 && data is Map) {
        final m = Map<String, dynamic>.from(data);
        final snapRaw = m['snapshot'];
        if (snapRaw is Map) {
          final snap = AiLimitsSnapshot.fromJson(Map<String, dynamic>.from(snapRaw));
          final retry = (m['retryAfterSeconds'] as num?)?.toInt();
          final nextAt = m['nextRefreshAllowedAt'] is String
              ? DateTime.tryParse(m['nextRefreshAllowedAt'] as String)
              : null;
          return AiLimitsRefreshResult(
            snapshot: snap,
            throttled: true,
            retryAfterSeconds: retry,
            nextRefreshAllowedAt: nextAt,
            message: m['message'] as String?,
          );
        }
      }
      throw _mapError(e);
    }
  }

  Future<AiLimitsAccountMutationResult> updateAccount(
    String accountId, {
    String? alias,
    bool? enabled,
    String? plan,
    String? dashboardUrl,
  }) async {
    try {
      final body = <String, dynamic>{
        if (alias != null) 'alias': alias.trim(),
        if (enabled != null) 'enabled': enabled,
        if (plan != null) 'plan': plan.trim(),
        if (dashboardUrl != null) 'dashboardUrl': dashboardUrl.trim(),
      };
      final raw = await _putJson(
        '$_base/accounts/${Uri.encodeComponent(accountId)}',
        body,
      );
      return AiLimitsAccountMutationResult.fromJson(Map<String, dynamic>.from(raw as Map));
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<AiLimitsSnapshot> removeAccount(String accountId) async {
    try {
      final raw = await _deleteJson(
        '$_base/accounts/${Uri.encodeComponent(accountId)}',
      );
      final map = Map<String, dynamic>.from(raw as Map);
      return AiLimitsSnapshot.fromJson(
        Map<String, dynamic>.from(map['snapshot'] as Map),
      );
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<AiLimitsSetupGuide> getSetupGuide(String sourceId) async {
    try {
      final raw = await _getJson(
        '$_base/sources/${Uri.encodeComponent(sourceId)}/setup',
      );
      return AiLimitsSetupGuide.fromJson(Map<String, dynamic>.from(raw as Map));
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<({AiLimitsSetupGuide setup, AiLimitsSnapshot? snapshot})> installHook(
    String sourceId,
  ) async {
    try {
      final raw = await _postJson(
        '$_base/sources/${Uri.encodeComponent(sourceId)}/install-hook',
        const <String, dynamic>{},
      );
      return _parseHookMutation(Map<String, dynamic>.from(raw as Map));
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<({AiLimitsSetupGuide setup, AiLimitsSnapshot? snapshot})> uninstallHook(
    String sourceId,
  ) async {
    try {
      final raw = await _postJson(
        '$_base/sources/${Uri.encodeComponent(sourceId)}/uninstall-hook',
        const <String, dynamic>{},
      );
      return _parseHookMutation(Map<String, dynamic>.from(raw as Map));
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  static ({AiLimitsSetupGuide setup, AiLimitsSnapshot? snapshot}) _parseHookMutation(
    Map<String, dynamic> map,
  ) {
    final setupRaw = map['setup'] is Map
        ? Map<String, dynamic>.from(map['setup'] as Map)
        : map;
    final snapRaw = map['snapshot'] is Map
        ? Map<String, dynamic>.from(map['snapshot'] as Map)
        : null;
    return (
      setup: AiLimitsSetupGuide.fromJson(setupRaw),
      snapshot: snapRaw != null ? AiLimitsSnapshot.fromJson(snapRaw) : null,
    );
  }

  static AiLimitsApiException _mapError(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    String? code;
    String? msg;
    int? retryAfter;
    if (data is Map) {
      final m = Map<String, dynamic>.from(data);
      if (m['errorCode'] is String) code = m['errorCode'] as String;
      if (m['message'] is String && (m['message'] as String).trim().isNotEmpty) {
        msg = (m['message'] as String).trim();
      } else if (m['error'] is String && (m['error'] as String).trim().isNotEmpty) {
        msg = (m['error'] as String).trim();
      }
      if (m['retryAfterSeconds'] is num) {
        retryAfter = (m['retryAfterSeconds'] as num).toInt();
      }
    }
    if (status == 404) {
      return AiLimitsApiException(
        tr('O DeckOS no PC ainda não suporta Limites de IA. Atualize o app no PC.'),
        errorCode: code ?? 'unsupported_version',
        statusCode: status,
      );
    }
    if (status == 403 && code == 'local_only_action') {
      return AiLimitsApiException(
        msg ?? tr('Esta ação só pode ser executada no próprio PC.'),
        errorCode: code,
        statusCode: status,
      );
    }
    if (status == 401 || status == 403) {
      return AiLimitsApiException(
        msg ?? tr('Autenticação recusada pelo PC.'),
        errorCode: code ?? 'auth_failed',
        statusCode: status,
      );
    }
    if (msg != null) {
      return AiLimitsApiException(
        msg,
        errorCode: code,
        statusCode: status,
        retryAfterSeconds: retryAfter,
      );
    }
    return AiLimitsApiException(
      tr('O PC não respondeu. Confira se o DeckOS está aberto nele.'),
      errorCode: code ?? 'unreachable',
      statusCode: status,
    );
  }
}
