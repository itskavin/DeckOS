import 'dart:async';
import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/slider_state_store.dart';

class HomeController {
  final DeckOSClient _client = Injector.get<DeckOSClient>();
  final SignalRService _signalR = Injector.get<SignalRService>();

  late final outputs = signal<List<MixerEntity>>([]);
  late final inputs = signal<List<MixerEntity>>([]);
  late final isLoading = signal(false);
  late final error = signal<String?>(null);
  late final isFullscreen = signal(false);

  Timer? _pollingTimer;
  Timer? _signalRRefreshDebounce;
  Timer? _mediaRefreshDebounce;
  void Function()? _volumeSubDispose;
  void Function()? _mediaSubDispose;
  void Function()? _reconnectDispose;

  bool _disposed = false;
  Future<void>? _outputsInFlight;
  bool _outputsQueued = false;
  Future<void>? _inputsInFlight;
  bool _inputsQueued = false;
  Future<void>? _mediaInFlight;
  bool _mediaQueued = false;

  HomeController() {
    // Subscribe to SignalR volume updates and refresh when they arrive.
    // Guarda o dispose da assinatura pra cancelar no dispose() — senao o callback
    // continua vivo e dispara fetch num controller ja descartado (leak + erro).
    // Estado de midia mudou em OUTRO lugar (botao do deck, outro celular): recarrega
    // o card de midia. Sem isto, o app so descobria a troca no poll de 60s.
    var firstMedia = true;
    _mediaSubDispose = _signalR.mediaStateUpdates.subscribe((update) {
      if (firstMedia) {
        firstMedia = false;
        return;
      }
      if (update == null || _disposed) return;
      _mediaRefreshDebounce?.cancel();
      _mediaRefreshDebounce =
          Timer(const Duration(milliseconds: 400), fetchMediaSessions);
    });

    var firstVolume = true;
    _volumeSubDispose = _signalR.volumeUpdates.subscribe((updates) {
      if (firstVolume) {
        firstVolume = false;
        return;
      }
      if (updates.isEmpty || _disposed) return;

      // Debounce to avoid excessive refreshes during rapid slider changes
      _signalRRefreshDebounce?.cancel();
      _signalRRefreshDebounce = Timer(const Duration(milliseconds: 500), () {
        if (_disposed) return;
        fetchOutputs();
        fetchInputs();
      });
    });

    // Ao reconectar depois de queda ou erro offline, atualiza o mixer e a mídia sem esperar 60s.
    var wasConnected = _signalR.connectionStatus.value == 'Connected';
    var sawDisconnect = false;
    _reconnectDispose = effect(() {
      final connected = _signalR.connectionStatus.value == 'Connected';
      if (!connected && wasConnected) {
        sawDisconnect = true;
      } else if (connected && !wasConnected) {
        final shouldRefresh = sawDisconnect || error.value != null;
        sawDisconnect = false;
        if (shouldRefresh && !_disposed) {
          untracked(() {
            fetchOutputs();
            fetchInputs();
            fetchMediaSessions();
          });
        }
      }
      wasConnected = connected;
    });
  }

  void startPolling() {
    if (_disposed) return;
    // Initial fetch
    fetchOutputs();
    fetchInputs();
    fetchMediaSessions();

    // Poll every 60 seconds (SignalR handles real-time updates)
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (_disposed) return;
      fetchOutputs();
      fetchInputs();
      fetchMediaSessions();
    });
  }

  void stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  Future<void> fetchOutputs() {
    if (_disposed) return Future<void>.value();
    final existing = _outputsInFlight;
    if (existing != null) {
      _outputsQueued = true;
      return existing;
    }
    final task = _runOutputsLoop().whenComplete(() => _outputsInFlight = null);
    _outputsInFlight = task;
    return task;
  }

  Future<void> _runOutputsLoop() async {
    do {
      _outputsQueued = false;
      if (_disposed) return;
      // Don't show loading on periodic refresh; retain last valid data while refreshing.
      final isInitialLoad = outputs.value.isEmpty;
      if (isInitialLoad) {
        isLoading.value = true;
      }

      try {
        final res = await _client.getOutputs();
        if (_disposed) return;
        outputs.value = res;
        error.value = null;
      } catch (e) {
        if (_disposed) return;
        error.value = e.toString();
      } finally {
        if (!_disposed && isInitialLoad) {
          isLoading.value = false;
        }
      }
    } while (_outputsQueued && !_disposed);
  }

  Future<void> fetchInputs() {
    if (_disposed) return Future<void>.value();
    final existing = _inputsInFlight;
    if (existing != null) {
      _inputsQueued = true;
      return existing;
    }
    final task = _runInputsLoop().whenComplete(() => _inputsInFlight = null);
    _inputsInFlight = task;
    return task;
  }

  Future<void> _runInputsLoop() async {
    do {
      _inputsQueued = false;
      if (_disposed) return;
      try {
        final res = await _client.getInputs();
        if (_disposed) return;
        inputs.value = res;
        error.value = null;
      } catch (e) {
        if (_disposed) return;
        error.value = e.toString();
      }
    } while (_inputsQueued && !_disposed);
  }

  // Send volume change and refresh immediately
  Future<void> setVolume(String id, int volume, {bool isInput = false}) async {
    try {
      final data = MixerData(volume: volume);
      if (isInput) {
        await _client.setInput(id, data);
        if (_disposed) return;
        fetchInputs();
      } else {
        await _client.setOutput(id, data);
        if (_disposed) return;
        fetchOutputs();
      }
      SliderStateStore.instance.scheduleAudioRefresh();
    } catch (e) {
      if (!_disposed) error.value = e.toString();
    }
  }

  Future<void> toggleMute(String id, bool currentMute,
      {bool isInput = false}) async {
    try {
      final data = MixerData(mute: !currentMute);
      if (isInput) {
        await _client.setInput(id, data);
        if (_disposed) return;
        fetchInputs();
      } else {
        await _client.setOutput(id, data);
        if (_disposed) return;
        fetchOutputs();
      }
      SliderStateStore.instance.scheduleAudioRefresh();
    } catch (e) {
      if (!_disposed) error.value = e.toString();
    }
  }

  Future<void> setChannelVolume(
      String deviceId, int sessionId, int volume) async {
    try {
      await _client.setOutput(
          deviceId, MixerData(session: sessionId, volume: volume));
      if (_disposed) return;
      // Refresh immediately - slider won't jump because of _isDragging flag
      fetchOutputs();
      SliderStateStore.instance.scheduleAudioRefresh();
    } catch (e) {
      if (!_disposed) error.value = e.toString();
    }
  }

  Future<void> toggleChannelMute(
      String deviceId, int sessionId, bool currentMute) async {
    try {
      await _client.setOutput(
          deviceId, MixerData(session: sessionId, mute: !currentMute));
      if (_disposed) return;
      fetchOutputs();
      SliderStateStore.instance.scheduleAudioRefresh();
    } catch (e) {
      if (!_disposed) error.value = e.toString();
    }
  }

  void dispose() {
    _disposed = true;
    stopPolling();
    _signalRRefreshDebounce?.cancel();
    _mediaRefreshDebounce?.cancel();
    _volumeSubDispose?.call();
    _volumeSubDispose = null;
    _mediaSubDispose?.call();
    _mediaSubDispose = null;
    _reconnectDispose?.call();
    _reconnectDispose = null;
  }

  void toggleFullscreen() {
    isFullscreen.value = !isFullscreen.value;
  }

  // Media Control methods
  late final mediaSessions = signal<Map<String, MediaSession>>({});

  Future<void> fetchMediaSessions() {
    if (_disposed) return Future<void>.value();
    final existing = _mediaInFlight;
    if (existing != null) {
      _mediaQueued = true;
      return existing;
    }
    final task = _runMediaLoop().whenComplete(() => _mediaInFlight = null);
    _mediaInFlight = task;
    return task;
  }

  Future<void> _runMediaLoop() async {
    do {
      _mediaQueued = false;
      if (_disposed) return;
      try {
        final sessions = await _client.getMediaSessions();
        if (_disposed) return;
        // Convert list to map by ID for easy lookup
        final sessionMap = <String, MediaSession>{};
        for (final session in sessions) {
          if (session.id != null) {
            sessionMap[session.id!] = session;
          }
        }
        mediaSessions.value = sessionMap;
      } catch (_) {
        // Best-effort refresh; SignalR or next poll retries.
      }
    } while (_mediaQueued && !_disposed);
  }

  Future<void> sendMediaCommand(String sessionId, String command) async {
    try {
      // A resposta ja traz o estado logo apos o comando — antes havia um
      // Future.delayed(500ms) as cegas antes de recarregar tudo, que tanto podia
      // ser cedo demais (voltava o estado velho) quanto atraso puro na UI.
      final result = await _client.sendMediaCommand(sessionId, command);

      final playing = result['playing'];
      // O backend redireciona o comando quando o id salvo nao existe mais, entao
      // o estado tem que ser aplicado na sessao que REALMENTE recebeu.
      final applied = result['sessionId'] as String? ?? sessionId;

      if (playing is bool) {
        final known = mediaSessions.value[applied];
        if (known != null) {
          mediaSessions.value = {
            ...mediaSessions.value,
            applied: known.copyWith(
                playbackStatus: playing ? 'Playing' : 'Paused'),
          };
        }
      }

      // Recarrega para pegar faixa/capa novas (next/previous trocam a musica).
      fetchMediaSessions();
    } catch (_) {
      // Best-effort command error handling.
    }
  }
}
