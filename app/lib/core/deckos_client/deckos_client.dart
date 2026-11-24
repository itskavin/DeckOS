import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:deckos/src/connection/transport_policy.dart';
import 'package:deckos/core/web_mode.dart';

import 'package:deckos/core/i18n/i18n.dart';
import 'package:dio/dio.dart';
import 'models/mixer_data.dart';
import 'models/audio_target.dart';
import 'models/mixer_entity.dart';
import 'models/mixer_master.dart';
import 'models/media_session.dart';
import 'models/deck_profile.dart';
import 'models/deck_action.dart';
import 'models/sound_result.dart';
import 'models/platform_info.dart';
import 'models/installed_app.dart';
import 'demo/demo_backend.dart';

export 'models/platform_info.dart';
export 'models/installed_app.dart';
export 'demo/demo_backend.dart' show DemoBackend;

/// Erro transitório de rede/transporte ao consultar um controle deslizante (sem resposta
/// do PC ou timeout). Distingue queda momentânea de um 404 explícito (alvo ausente).
class SliderOfflineException implements Exception {
  const SliderOfflineException([this.message = 'PC unreachable']);
  final String message;

  @override
  String toString() => 'SliderOfflineException: $message';
}

class DeckOSClient {
  Dio _dio;
  final bool _injected;
  String get baseUrl => _dio.options.baseUrl;

  void configureSecure(TransportPolicy policy, String? credential, {String? route}) {
    final old = _dio;
    final configured = policy.dio();
    _dio = configured;
    configured.options.headers['Accept-Language'] = AppLanguage.header;
    if (route != null) configured.options.baseUrl = route;
    setApiKey(credential);
    configured.interceptors.add(InterceptorsWrapper(onError: (error, handler) async {
      if (error.type != DioExceptionType.connectionError || !identical(_dio, configured) ||
          error.requestOptions.extra['rerouted'] == true) return handler.next(error);
      final reroute = onConnectionRefused;
      if (reroute == null) return handler.next(error);
      String? base;
      try { base = await reroute(error.requestOptions.baseUrl, credential); }
      catch (_) { return handler.next(error); }
      if (base == null || !identical(_dio, configured) || !policy.allows(Uri.parse(base))) return handler.next(error);
      // A failed USB request changes the next route. Only GET is automatically
      // replayed: an action or upload may have reached the PC before the failure.
      if (error.requestOptions.method != 'GET') return handler.next(error);
      error.requestOptions..baseUrl = base..extra['rerouted'] = true;
      try { handler.resolve(await configured.fetch(error.requestOptions)); }
      on DioException catch (retry) { handler.next(retry); }
    }));
    old.close(force: true);
  }

  DeckOSClient({
    required String baseUrl,
    Dio? dio,
  })  : _dio = dio ?? Dio(),
        _injected = dio != null {
    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout ??= const Duration(seconds: 4)
      ..sendTimeout ??= const Duration(seconds: 5)
      ..receiveTimeout ??= const Duration(seconds: 15);
    // O PC traduz o que manda (tipos de ação, erros) pelo idioma do app.
    _dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (!_injected && options.headers['X-API-KEY'] != null &&
          !WebMode.onPcLoopback && !DemoBackend.enabled && !kIsWeb) {
        return handler.reject(DioException(requestOptions: options, error: 'Re-pair securely'));
      }
      if (options.headers['X-API-KEY'] != null && options.uri.origin != Uri.parse(options.baseUrl).origin) {
        return handler.reject(DioException(requestOptions: options, error: 'Unexpected PC endpoint'));
      }
      options.headers['Accept-Language'] = AppLanguage.header;
      handler.next(options);
    }));
    // Conexão recusada: a requisição não saiu do celular, então dá para repetir uma vez
    // (mesmo um aperto de botão) no endereço que [onConnectionRefused] devolver. Erro
    // depois de conectar não se repete: o PC pode já ter executado.
    _dio.interceptors.add(InterceptorsWrapper(onError: (e, handler) async {
      final o = e.requestOptions;
      final reroute = onConnectionRefused;
      if (e.type != DioExceptionType.connectionError ||
          reroute == null ||
          o.extra['rerouted'] == true ||
          o.path.startsWith('http') ||
          o.data is FormData ||
          o.data is Stream) {
        return handler.next(e);
      }
      String? base;
      try {
        base = await reroute(o.baseUrl, o.headers['X-API-KEY'] as String?);
      } catch (_) {}
      if (base == null) return handler.next(e);
      o
        ..baseUrl = base
        ..extra['rerouted'] = true;
      try {
        handler.resolve(await _dio.fetch(o));
      } on DioException catch (retryError) {
        handler.next(retryError);
      }
    }));
    // Só em build de depuração (ou com --dart-define=DECKOS_DEMO=true), com ?demo=1:
    // um PC de mentira para ver a interface cheia sem o servidor.
    if (DemoBackend.enabled) _dio.interceptors.add(DemoBackend.interceptor());
  }

  /// Endereço para repetir uma requisição cuja conexão com [failedBaseUrl] foi recusada
  /// (levando a chave [apiKey]), ou null para não repetir.
  Future<String?> Function(String failedBaseUrl, String? apiKey)? onConnectionRefused;

  void setBaseUrl(String url) {
    _dio.options.baseUrl = url;
  }

  /// Current transport route, without credentials; used to reject stale host responses.
  String get currentBaseUrl => _dio.options.baseUrl;

  /// Define (ou remove) a chave de API enviada em todas as requisições (header X-API-KEY).
  void setApiKey(String? key) {
    if (key == null || key.isEmpty) {
      _dio.options.headers.remove('X-API-KEY');
    } else {
      _dio.options.headers['X-API-KEY'] = key;
    }
  }

  /// Sistema e recursos do PC (GET /api/platform). Null se o PC é anterior ao endpoint
  /// ou não respondeu: aí a interface mostra tudo, como antes.
  Future<PlatformInfo?> getPlatform() async {
    try {
      final r = await _dio.get('/api/platform');
      final data = r.data;
      return data is Map ? PlatformInfo.fromJson(Map<String, dynamic>.from(data)) : null;
    } catch (_) {
      return null;
    }
  }

  /// Apps instalados no PC (GET /api/apps), em ordem alfabética. Null se o PC não tem a
  /// lista (versão antiga, ou sistema sem suporte): a interface esconde a biblioteca.
  Future<List<InstalledApp>?> getApps() async {
    try {
      final r = await _dio.get('/api/apps');
      final data = r.data;
      if (data is! List) return null;
      return data
          .whereType<Map>()
          .map((e) => InstalledApp.fromJson(Map<String, dynamic>.from(e)))
          .where((a) => a.id.isNotEmpty && a.name.isNotEmpty)
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Bytes do ícone de um app (PNG ou SVG). Null se o app não tem ícone.
  Future<Uint8List?> getAppIcon(InstalledApp app) async {
    final url = app.iconUrl;
    if (url == null || url.isEmpty) return null;
    try {
      final r = await _dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
      final bytes = r.data;
      return bytes == null || bytes.isEmpty ? null : Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<List<MixerEntity>> getOutputs() async {
    final response = await _dio.get('/api/v1/Mixer/out');
    return (response.data as List)
        .map((e) => MixerEntity.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<MixerEntity> getOutput(String id) async {
    final response = await _dio.get('/api/v1/Mixer/out/$id');
    return MixerEntity.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MixerMaster> setOutput(String id, MixerData data) async {
    final response = await _dio.put(
      '/api/v1/Mixer/out/$id',
      data: data.toJson(),
    );
    return MixerMaster.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<MixerEntity>> getInputs() async {
    final response = await _dio.get('/api/v1/Mixer/in');
    return (response.data as List)
        .map((e) => MixerEntity.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<MixerEntity> getInput(String id) async {
    final response = await _dio.get('/api/v1/Mixer/in/$id');
    return MixerEntity.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MixerMaster> setInput(String id, MixerData data) async {
    final response = await _dio.put(
      '/api/v1/Mixer/in/$id',
      data: data.toJson(),
    );
    return MixerMaster.fromJson(response.data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> mute(AudioTarget target) async {
    final response = await _dio.post(
      '/api/Software/mute',
      data: target.toJson(),
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> toggleMute(AudioTarget target) async {
    final response = await _dio.post(
      '/api/Software/toggle-mute',
      data: target.toJson(),
    );
    return response.data as Map<String, dynamic>;
  }

  /// Estado de mute atual de um processo (null se não houver sessão de áudio).
  Future<bool?> getMuteState(String process) async {
    final response = await _dio.get('/api/Software/mute-state/$process');
    final data = response.data;
    if (data is Map && data['muted'] is bool) return data['muted'] as bool;
    return null;
  }

  /// Estado atual do Discord (connected/mute/deaf/channelId/channelName/
  /// inputVolume/outputVolume/voiceMode/participants) ou null se indisponível.
  Future<Map<String, dynamic>?> getDiscordState() async {
    try {
      final response = await _dio.get('/api/discord/state');
      return (response.data as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Servidores do Discord do usuário ([{id, name}]).
  Future<List<Map<String, String>>> getDiscordGuilds() async {
    try {
      final r = await _dio.get('/api/discord/guilds');
      return (r.data as List)
          .map<Map<String, String>>(
              (e) => {'id': '${e['id']}', 'name': '${e['name'] ?? ''}'})
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Canais de voz de um servidor ([{id, name}]).
  Future<List<Map<String, String>>> getDiscordChannels(String guildId) async {
    try {
      final r = await _dio.get('/api/discord/channels/$guildId');
      return (r.data as List)
          .map<Map<String, String>>(
              (e) => {'id': '${e['id']}', 'name': '${e['name'] ?? ''}'})
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Salva as credenciais do app Discord (Client ID + Secret) no PC.
  Future<void> setDiscordConfig(String clientId, String clientSecret) async {
    await _dio.post('/api/discord/config',
        data: {'clientId': clientId, 'clientSecret': clientSecret});
  }

  /// Conecta ao Discord (abre o popup de autorização no PC na 1ª vez).
  /// Lança [Exception] com mensagem legível em caso de erro.
  Future<Map<String, dynamic>> connectDiscord() async {
    try {
      final r = await _dio.post('/api/discord/connect');
      return (r.data as Map).cast<String, dynamic>();
    } on DioException catch (e) {
      final data = e.response?.data;
      final msg = (data is Map && data['error'] != null)
          ? '${data['error']}'
          : tr('Falha ao conectar — o Discord está aberto no PC?');
      throw Exception(msg);
    }
  }

  /// Sons da soundboard NATIVA do Discord ([{soundId, name, guildId, emojiName}]).
  Future<List<Map<String, String>>> getDiscordSoundboardSounds() async {
    try {
      final r = await _dio.get('/api/discord/soundboard-sounds');
      return (r.data as List)
          .map<Map<String, String>>((e) => {
                'soundId': '${e['soundId'] ?? ''}',
                'name': '${e['name'] ?? ''}',
                'guildId': '${e['guildId'] ?? ''}',
                'emojiName': '${e['emojiName'] ?? ''}',
              })
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Toca um som da soundboard nativa do Discord no canal de voz atual.
  Future<void> playDiscordSoundboard(String soundId, String? guildId) async {
    await _dio.post('/api/discord/play-soundboard',
        data: {'soundId': soundId, 'guildId': guildId});
  }

  // ---- OBS ----
  /// Estado do OBS (connected/currentScene/recording/streaming/virtualCam/
  /// replayBuffer/scenes/audioInputs) ou null se indisponível.
  Future<Map<String, dynamic>?> getObsState() async {
    try {
      final r = await _dio.get('/api/obs/state');
      return (r.data as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Salva a config do OBS (host/porta/senha do obs-websocket).
  Future<void> setObsConfig(String host, int port, String? password) async {
    await _dio.post('/api/obs/config',
        data: {'host': host, 'port': port, 'password': password});
  }

  /// Conecta no OBS (obs-websocket). Lança [Exception] legível em caso de erro.
  Future<Map<String, dynamic>> connectObs() async {
    try {
      final r = await _dio.post('/api/obs/connect');
      return (r.data as Map).cast<String, dynamic>();
    } on DioException catch (e) {
      final data = e.response?.data;
      final msg = (data is Map && data['error'] != null)
          ? '${data['error']}'
          : tr('Falha ao conectar no OBS (obs-websocket ativo?)');
      throw Exception(msg);
    }
  }

  // ---- Tuya / Smart Life ----
  /// Estado do plugin: paired/connected/push + os dispositivos com status e funções.
  Future<Map<String, dynamic>?> getTuyaState() async {
    try {
      final r = await _dio.get('/api/tuya/state');
      return (r.data as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Passo 1 do pareamento: devolve `qrPayload` para renderizar o QR na tela.
  Future<Map<String, dynamic>> startTuyaPairing(String userCode) async {
    try {
      final r = await _dio
          .post('/api/tuya/pair/start', data: {'userCode': userCode});
      return (r.data as Map).cast<String, dynamic>();
    } on DioException catch (e) {
      throw Exception(_tuyaError(e, tr('Falha ao gerar o QR de pareamento')));
    }
  }

  /// Passo 2: chamar em laço. `false` = ainda não escaneado (não é erro).
  /// Lança [Exception] quando o QR expirou (HTTP 410) e outro precisa ser gerado.
  Future<bool> pollTuyaPairing() async {
    try {
      final r = await _dio.post('/api/tuya/pair/poll');
      return (r.data as Map)['scanned'] == true;
    } on DioException catch (e) {
      throw Exception(_tuyaError(e, tr('Falha ao verificar o pareamento')));
    }
  }

  /// Reenumera os dispositivos na nuvem. Caro em cota — só a pedido do usuário.
  Future<Map<String, dynamic>> refreshTuyaDevices() async {
    try {
      final r = await _dio.post('/api/tuya/devices/refresh');
      return (r.data as Map).cast<String, dynamic>();
    } on DioException catch (e) {
      throw Exception(_tuyaError(e, tr('Falha ao atualizar os dispositivos')));
    }
  }

  /// Dispara um comando avulso (usado pelo botão "testar" do editor).
  Future<void> sendTuyaCommand(
      String deviceId, String code, Object? value) async {
    try {
      await _dio.post('/api/tuya/command',
          data: {'deviceId': deviceId, 'code': code, 'value': value});
    } on DioException catch (e) {
      throw Exception(_tuyaError(e, tr('Falha ao enviar o comando')));
    }
  }

  static String _tuyaError(DioException e, String fallback) {
    final data = e.response?.data;
    return (data is Map && data['error'] != null) ? '${data['error']}' : fallback;
  }

  // Media Control methods
  Future<List<MediaSession>> getMediaSessions() async {
    final response = await _dio.get('/api/v1/Media/sessions');
    return (response.data as List)
        .map((e) => MediaSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<MediaSession> getMediaSession(String id) async {
    final response = await _dio.get('/api/v1/Media/sessions/$id');
    return MediaSession.fromJson(response.data as Map<String, dynamic>);
  }

  /// Envia um comando de transporte e devolve o que o backend aplicou:
  /// `sessionId` (pode diferir do pedido, quando o id salvo nao existe mais) e
  /// `playing` (estado logo apos o comando). Mapa vazio se a resposta vier sem corpo.
  Future<Map<String, dynamic>> sendMediaCommand(String id, String command) async {
    final response = await _dio.post(
      '/api/v1/Media/sessions/$id/command',
      data: {'command': command},
    );
    final data = response.data;
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  // StreamDeck methods
  Future<List<DeckProfile>> getProfiles() async {
    final response = await _dio.get('/api/StreamDeck/profiles');
    return (response.data as List)
        .map((e) => DeckProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<DeckProfile> getProfile(String id) async {
    final response = await _dio.get('/api/StreamDeck/profiles/$id');
    return DeckProfile.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> saveProfile(DeckProfile profile) async {
    await _dio.post(
      '/api/StreamDeck/profiles',
      data: profile.toJson(),
    );
  }

  Future<void> deleteProfile(String id) async {
    await _dio.delete('/api/StreamDeck/profiles/$id');
  }

  /// Aperta um botão salvo: o PC lê a ação do perfil. É o caminho do deck — o
  /// /execute com ação avulsa recusa (403), de fora do PC, ações que rodam código.
  Future<void> pressButton(String profileId, String buttonId,
      {String gesture = 'tap'}) async {
    await _dio.post(
      '/api/StreamDeck/press',
      data: {'profileId': profileId, 'buttonId': buttonId, 'gesture': gesture},
      // O PC só responde quando a ação termina (multi-ação com esperas pode levar
      // bem mais que o limite padrão); um timeout aqui mostraria erro de algo que rodou.
      options: Options(receiveTimeout: _actionTimeout),
    );
  }

  /// Copia (ou move) um botão salvo para a casa [row],[column] de outro perfil. O PC copia
  /// o que está salvo, então vale também para atalhos e programas.
  Future<void> copyButton({
    required String fromProfileId,
    required String buttonId,
    required String toProfileId,
    required int row,
    required int column,
    required bool move,
  }) async {
    await _dio.post(
      '/api/StreamDeck/buttons/copy',
      data: {
        'fromProfileId': fromProfileId,
        'buttonId': buttonId,
        'toProfileId': toProfileId,
        'row': row,
        'column': column,
        'move': move,
      },
    );
  }

  /// Backup dos perfis (.deckos, um zip).
  Future<List<int>> exportBackup() async {
    final response = await _dio.get<List<int>>('/api/backup',
        options: Options(responseType: ResponseType.bytes));
    return response.data ?? const [];
  }

  /// Restaura um .deckos. Devolve quantos perfis entraram.
  Future<int> importBackup(List<int> bytes) async {
    // Bytes direto (não Stream): no navegador o Dio só envia corpo binário assim.
    final response = await _dio.post('/api/backup',
        data: Uint8List.fromList(bytes),
        options: Options(contentType: 'application/octet-stream'));
    return ((response.data as Map?)?['imported'] as num?)?.toInt() ?? 0;
  }

  /// Controle deslizante: volume (0-100) do alvo ("output", "input" ou "app" + nome do
  /// processo). Null se o alvo não existe agora (404 — ex.: app fechado).
  /// Estado de um controle deslizante: {volume, max, mute, label, text}. [params] são os
  /// do botão (dispositivo, fonte, pessoa...). Lança com a mensagem do PC se o alvo falhou
  /// (503 — integração desconectada, luz fora da rede), [SliderOfflineException] se o PC
  /// não respondeu (queda/timeout de rede), ou devolve null se o alvo não existe agora (404).
  Future<Map<String, dynamic>?> getSlider(String target, Map<String, String> params) async {
    try {
      final r = await _dio.get('/api/slider', queryParameters: {...params, 'target': target});
      return Map<String, dynamic>.from(r.data as Map);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final data = e.response?.data;
      if (status == 503 && data is Map && data['error'] != null) {
        throw Exception(data['error']);
      }
      if (status == 404) {
        return null;
      }
      if (e.response == null || (status != null && status >= 500)) {
        throw SliderOfflineException(e.message ?? 'Connection error');
      }
      throw Exception('HTTP $status');
    }
  }

  Future<Map<String, dynamic>?> setSlider(String target, Map<String, String> params, int volume) async {
    try {
      final r = await _dio.put('/api/slider', data: {
        'target': target,
        'app': params['app'] ?? '',
        'params': params,
        'volume': volume,
      });
      final data = r.data;
      if (data is Map) return Map<String, dynamic>.from(data);
    } on DioException catch (e) {
      final data = e.response?.data;
      if (e.response == null) throw const SliderOfflineException();
      throw Exception(data is Map && data['error'] is String ? data['error'] : 'HTTP ${e.response?.statusCode}');
    }
    return null;
  }

  /// Importa um perfil do app da Elgato (.streamDeckProfile) como perfis novos.
  /// Devolve {profiles, buttons, unsupported: [nomes], stripped, firstProfileId}.
  Future<Map<String, dynamic>> importStreamDeck(List<int> bytes) async {
    final response = await _dio.post('/api/import/streamdeck',
        data: Uint8List.fromList(bytes),
        options: Options(contentType: 'application/octet-stream'));
    return Map<String, dynamic>.from(response.data as Map);
  }

  /// Catálogo dos tipos de ação (GET /api/actions/schema). Servidores anteriores
  /// à 1.8 não têm o endpoint: aí lança, e o editor usa o catálogo embutido.
  Future<List<Map<String, dynamic>>> getActionSchema() async {
    final response = await _dio.get('/api/actions/schema');
    return (response.data as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Estado atual de um provedor de ação (o mesmo que vai pelo SignalR).
  Future<Map<String, dynamic>?> getActionState(String type) async {
    final response = await _dio.get('/api/actions/state/$type');
    final data = response.data;
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  /// GET genérico para as listas de opções que o schema aponta (cenas, filtros...).
  Future<dynamic> getJson(String path) async {
    final response = await _dio.get(path);
    return response.data;
  }

  Future<dynamic> postJson(String path, [Object? body]) async {
    final response = await _dio.post(path, data: body);
    return response.data;
  }

  Future<List<int>> getBytes(String path) async {
    final response = await _dio.get<List<int>>(path,
        options: Options(responseType: ResponseType.bytes));
    return response.data ?? const [];
  }

  Future<dynamic> putJson(String path, [Object? body]) async {
    final response = await _dio.put(path, data: body);
    return response.data;
  }

  /// Espera máxima pela resposta de uma ação, que só volta quando ela termina.
  static const _actionTimeout = Duration(minutes: 5);

  Future<dynamic> deleteJson(String path) async {
    final response = await _dio.delete(path);
    return response.data;
  }

  Future<void> executeAction(DeckAction action) async {
    await _dio.post(
      '/api/StreamDeck/execute',
      data: action.toJson(),
      options: Options(receiveTimeout: _actionTimeout),
    );
  }

  /// Grade física do deck persistida no PC ({rows, columns}).
  Future<Map<String, int>?> getLayout() async {
    try {
      final r = await _dio.get('/api/StreamDeck/layout');
      final m = (r.data as Map);
      return {
        'rows': (m['rows'] as num).toInt(),
        'columns': (m['columns'] as num).toInt(),
      };
    } catch (_) {
      return null;
    }
  }

  /// A chave atual é aceita pelo PC? (falha de rede também conta como não)
  Future<bool> checkKey() async {
    try {
      await _dio.get('/api/StreamDeck/layout');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// O celular reporta quantos botões cabem inteiros na tela.
  Future<void> saveLayout(int rows, int columns) async {
    await _dio.post(
      '/api/StreamDeck/layout',
      data: {'rows': rows, 'columns': columns},
    );
  }

  // ---- Soundboard (MyInstants) ----
  /// Busca sons no MyInstants (proxiado pelo backend).
  Future<List<SoundResult>> searchSounds(String query) async {
    try {
      final r = await _dio.get('/api/Soundboard/search',
          queryParameters: {'q': query});
      return (r.data as List)
          .map((e) => SoundResult.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Sons em alta no MyInstants.
  Future<List<SoundResult>> getTrendingSounds() async {
    try {
      final r = await _dio.get('/api/Soundboard/trending');
      return (r.data as List)
          .map((e) => SoundResult.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Toca um som no PC (sai pelo dispositivo configurado — cabo/monitor).
  Future<void> playSound(String id, String url, String title) async {
    await _dio.post('/api/Soundboard/play',
        data: {'id': id, 'url': url, 'title': title});
  }

  /// Para tudo que estiver tocando na soundboard.
  Future<void> stopSounds() async {
    await _dio.post('/api/Soundboard/stop');
  }

  /// Dispositivos de saída de áudio disponíveis ([{id, name}]).
  Future<List<Map<String, String>>> getSoundDevices() async {
    try {
      final r = await _dio.get('/api/Soundboard/devices');
      return (r.data as List)
          .map<Map<String, String>>(
              (e) => {'id': '${e['id']}', 'name': '${e['name'] ?? ''}'})
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Config da soundboard ({cableDeviceId, monitorDeviceId, monitorEnabled, volume}).
  Future<Map<String, dynamic>?> getSoundboardConfig() async {
    try {
      final r = await _dio.get('/api/Soundboard/config');
      return (r.data as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Salva a config da soundboard (seleção de dispositivos + volume).
  Future<void> saveSoundboardConfig({
    String? cableDeviceId,
    String? monitorDeviceId,
    bool? monitorEnabled,
    int? volume,
  }) async {
    await _dio.post('/api/Soundboard/config', data: {
      'cableDeviceId': cableDeviceId,
      'monitorDeviceId': monitorDeviceId,
      'monitorEnabled': monitorEnabled,
      'volume': volume,
    });
  }
}
