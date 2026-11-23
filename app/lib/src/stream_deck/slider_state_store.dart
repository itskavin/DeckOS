import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/foundation.dart';

/// Immutable snapshot of a deck slider's last known state.
@immutable
class SliderSnapshot {
  const SliderSnapshot({
    this.volume,
    this.max = 100,
    this.mute = false,
    this.serverLabel,
    this.text,
    this.error,
    this.missing = false,
    required this.updatedAt,
  });

  /// Current level in `0..max` (`0` is a valid 0% reading; `null` means absent/unloaded).
  final int? volume;

  /// Upper bound of the scale (100, 200 for Discord user, or track duration in seconds).
  final int max;
  final bool mute;

  /// Name returned by the PC (light name, track title, output device title).
  final String? serverLabel;

  /// Custom display text replacing the numeric percentage (e.g. `"1:23"` for media seek).
  final String? text;

  /// Error message from the PC when the target integration failed (HTTP 503).
  final String? error;

  /// True when the PC explicitly replied 404 (target does not exist right now, e.g. app closed).
  final bool missing;

  final DateTime updatedAt;

  bool get hasValue => volume != null && error == null;

  bool sameVisibleData(SliderSnapshot other) =>
      volume == other.volume &&
      max == other.max &&
      mute == other.mute &&
      serverLabel == other.serverLabel &&
      text == other.text &&
      error == other.error &&
      missing == other.missing;
}

class _SliderMeta {
  const _SliderMeta(this.target, this.params);
  final String target;
  final Map<String, String> params;
}

/// Shared, bounded, single-flight store for deck [SliderDeckButton] values.
///
/// - Preloaded values are read synchronously on frame 0 (no `'—'` / `0%` flash).
/// - Concurrent reads for the same target coalesce onto one in-flight request.
/// - Active 3s polling runs ONLY for keys with mounted subscribers, never for off-screen pages.
/// - Monotonic write generations and drag tracking prevent stale GETs from resetting a slider
///   under the user's finger or bouncing back right after drag release.
/// - SignalR volume/media/reconnect events keep cached sliders fresh without blind full polls.
class SliderStateStore {
  SliderStateStore._();

  static SliderStateStore _instance = SliderStateStore._();
  static SliderStateStore get instance => _instance;

  /// Bounded LRU cap to prevent unbounded memory growth across many dynamic sliders.
  static const int maxEntries = 64;

  /// Default freshness window for coalescing prewarm + mount reads.
  static const Duration defaultFreshTtl = Duration(seconds: 2);

  /// Poll interval for currently mounted (visible) sliders.
  static const Duration pollInterval = Duration(seconds: 3);

  static const _audioTargets = {'output', 'input', 'app'};

  /// Monotonic revision signal read by [SliderDeckButton] inside `Watch` / `effect`.
  final revision = signal<int>(0);

  final Map<String, SliderSnapshot> _cache = <String, SliderSnapshot>{};
  final Map<String, _SliderMeta> _meta = <String, _SliderMeta>{};
  final Map<String, Future<SliderSnapshot?>> _inFlight = <String, Future<SliderSnapshot?>>{};
  final Map<String, int> _subscribers = <String, int>{};
  final Map<String, int> _draggingCount = <String, int>{};
  final Map<String, int> _writeGen = <String, int>{};
  final Map<String, int> _pendingWrites = <String, int>{};
  final Map<String, Future<void>> _writing = <String, Future<void>>{};
  int _bindingEpoch = 0;
  int _nextWriteGen = 0;

  WeakReference<DeckOSClient>? _boundClient;
  WeakReference<SignalRService>? _boundSignalR;
  String? _boundPcId;
  String? _boundBaseUrl;

  void Function()? _volumeSubCleanup;
  void Function()? _mediaSubCleanup;
  void Function()? _reconnectCleanup;

  Timer? _pollTimer;
  Timer? _audioDebounce;
  Timer? _mediaDebounce;
  bool _hadOfflineError = false;
  bool _wasDisconnected = false;

  /// Resets the singleton cleanly (used by unit/widget tests).
  static void resetForTest() {
    _instance._disposeInternal();
    _instance = SliderStateStore._();
  }

  /// Canonical cache key for a slider target + parameters (independent of map identity/order).
  static String keyFor(String target, Map<String, String> params) {
    final normTarget = target.trim().toLowerCase();
    final entries = params.entries
        .where((e) => e.key != 'target' && e.value.isNotEmpty)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    if (entries.isEmpty) return normTarget;
    return '$normTarget|${entries.map((e) => '${e.key}=${e.value}').join('&')}';
  }

  static Map<String, String> cleanParams(Map<String, String>? raw) {
    if (raw == null || raw.isEmpty) return const {};
    final out = <String, String>{};
    for (final e in raw.entries) {
      if (e.key != 'target' && e.value.isNotEmpty) {
        out[e.key] = e.value;
      }
    }
    return Map.unmodifiable(out);
  }

  static String formatClock(int seconds) {
    final safe = seconds < 0 ? 0 : seconds;
    final h = safe ~/ 3600;
    final m = (safe % 3600) ~/ 60;
    final s = safe % 60;
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
  }

  @visibleForTesting
  int get cachedCount => _cache.length;

  @visibleForTesting
  int get activeSubscriberKeyCount => _subscribers.length;

  @visibleForTesting
  bool get isPolling => _pollTimer?.isActive ?? false;

  /// Synchronous read of the last cached snapshot (if any) for frame-0 rendering.
  SliderSnapshot? peek(String target, Map<String, String> params) {
    _syncBindings();
    return _cache[keyFor(target, params)];
  }

  /// Synchronous read by canonical key.
  SliderSnapshot? peekKey(String key) {
    _syncBindings();
    return _cache[key];
  }

  /// Registers a mounted [SliderDeckButton] as an active viewer of `(target, params)`.
  /// Starts periodic 3s polling only while at least one slider is actively mounted.
  String acquire(String target, Map<String, String> params) {
    _syncBindings();
    final cleaned = cleanParams(params);
    final key = keyFor(target, cleaned);
    _meta[key] = _SliderMeta(target.trim().toLowerCase(), cleaned);
    _subscribers[key] = (_subscribers[key] ?? 0) + 1;
    _ensurePollTimer();
    return key;
  }

  /// Unregisters a mounted [SliderDeckButton]. Stops polling immediately when none remain.
  void release(String key) {
    final current = _subscribers[key];
    if (current == null) return;
    if (current <= 1) {
      _subscribers.remove(key);
    } else {
      _subscribers[key] = current - 1;
    }
    if (_subscribers.isEmpty) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  /// Marks a slider key as actively being dragged by the user so background refreshes
  /// never overwrite the value under the user's finger.
  void beginDrag(String key) {
    _syncBindings();
    _draggingCount[key] = (_draggingCount[key] ?? 0) + 1;
    _bumpWriteGen(key);
  }

  /// Releases the drag lock for [key].
  void endDrag(String key) {
    final count = _draggingCount[key];
    if (count == null) return;
    if (count <= 1) {
      _draggingCount.remove(key);
    } else {
      _draggingCount[key] = count - 1;
    }
  }

  bool isDragging(String key) => (_draggingCount[key] ?? 0) > 0;

  /// Applies an immediate local value while dragging (keeps store & siblings in sync).
  void setOptimistic(String target, Map<String, String> params, int volume) {
    _syncBindings();
    final normTarget = target.trim().toLowerCase();
    final cleaned = cleanParams(params);
    final key = keyFor(normTarget, cleaned);
    _meta[key] = _SliderMeta(normTarget, cleaned);
    _bumpWriteGen(key);
    final prev = _cache[key];
    final max = prev?.max ?? (normTarget == 'discord_user' ? 200 : 100);
    final clamped = volume.clamp(0, max);
    final mute = _audioTargets.contains(normTarget)
        ? (clamped > 0 ? false : (prev?.mute ?? false))
        : (prev?.mute ?? false);
    final next = SliderSnapshot(
      volume: clamped,
      max: max,
      mute: mute,
      serverLabel: prev?.serverLabel,
      text: normTarget == 'media' ? formatClock(clamped) : prev?.text,
      error: null,
      missing: false,
      updatedAt: DateTime.now(),
    );
    _put(key, next);
  }

  /// Sends a volume/value update to the PC and applies the confirmed response if no
  /// newer drag/write superseded it.
  Future<void> writeVolume(String target, Map<String, String> params, int volume) {
    final client = _syncBindings();
    if (client == null) return Future<void>.value();
    final normTarget = target.trim().toLowerCase();
    final cleaned = cleanParams(params);
    final key = keyFor(normTarget, cleaned);
    _meta[key] = _SliderMeta(normTarget, cleaned);
    setOptimistic(normTarget, cleaned, volume);
    _pendingWrites[key] = volume;
    final epoch = _bindingEpoch;
    // One PUT per target at a time, retaining only the newest pending level.
    // HTTP completion order must never undo the final position of a drag.
    return _writing[key] ??= () async {
      try {
        while (epoch == _bindingEpoch && _pendingWrites.containsKey(key)) {
          final next = _pendingWrites.remove(key)!;
          final gen = _writeGen[key] ?? 0;
          Map<String, dynamic>? confirmed;
          try {
            confirmed = await client.setSlider(normTarget, cleaned, next);
          } catch (e) {
            _syncBindings();
            if (epoch != _bindingEpoch) return;
            if ((_writeGen[key] ?? 0) == gen) {
              final prev = _cache[key];
              _put(key, SliderSnapshot(volume: prev?.volume, max: prev?.max ?? 100,
                  mute: prev?.mute ?? false, serverLabel: prev?.serverLabel,
                  error: e is SliderOfflineException ? tr('Não foi possível falar com o PC.') : '$e'.replaceFirst('Exception: ', ''),
                  updatedAt: DateTime.now()));
            }
            continue;
          }
          _syncBindings();
          if (epoch != _bindingEpoch) return;
          if (confirmed != null && !isDragging(key) && (_writeGen[key] ?? 0) == gen) {
            _put(key, _parseState(confirmed, DateTime.now()));
          }
        }
      } finally {
        if (epoch == _bindingEpoch) _writing.remove(key);
      }
    }();
  }

  /// Ensures a slider has fresh data, coalescing concurrent callers onto one request.
  Future<SliderSnapshot?> ensureLoaded(
    String target,
    Map<String, String> params, {
    Duration freshTtl = defaultFreshTtl,
    bool force = false,
  }) {
    _syncBindings();
    final normTarget = target.trim().toLowerCase();
    final cleaned = cleanParams(params);
    final key = keyFor(normTarget, cleaned);
    _meta[key] = _SliderMeta(normTarget, cleaned);

    if (!force) {
      final cached = _cache[key];
      if (cached != null &&
          cached.error == null &&
          DateTime.now().difference(cached.updatedAt) < freshTtl) {
        return SynchronousFuture<SliderSnapshot?>(cached);
      }
    }
    return refresh(normTarget, cleaned);
  }

  /// Fetches the live slider state from the PC with single-flight deduplication.
  Future<SliderSnapshot?> refresh(String target, Map<String, String> params) {
    final client = _syncBindings();
    final normTarget = target.trim().toLowerCase();
    final cleaned = cleanParams(params);
    final key = keyFor(normTarget, cleaned);
    _meta[key] = _SliderMeta(normTarget, cleaned);

    if (client == null) return SynchronousFuture<SliderSnapshot?>(_cache[key]);
    if (isDragging(key) || _writing.containsKey(key)) {
      return SynchronousFuture<SliderSnapshot?>(_cache[key]);
    }

    final existing = _inFlight[key];
    if (existing != null) return existing;

    final startGen = _writeGen[key] ?? 0;
    final epoch = _bindingEpoch;
    final task = _doRefresh(
      client: client,
      key: key,
      target: normTarget,
      params: cleaned,
      startGen: startGen,
      epoch: epoch,
    ).whenComplete(() {
      if (epoch == _bindingEpoch) _inFlight.remove(key);
    });
    _inFlight[key] = task;
    return task;
  }

  Future<SliderSnapshot?> _doRefresh({
    required DeckOSClient client,
    required String key,
    required String target,
    required Map<String, String> params,
    required int startGen,
    required int epoch,
  }) async {
    try {
      final raw = await client.getSlider(target, params);
      _syncBindings();
      if (epoch != _bindingEpoch) return null;
      if (isDragging(key) || (_writeGen[key] ?? 0) != startGen) {
        return _cache[key];
      }
      _hadOfflineError = false;
      final now = DateTime.now();
      if (raw == null) {
        // Explicit 404: target does not exist now (e.g. app closed / no media).
        final prev = _cache[key];
        final next = SliderSnapshot(
          volume: null,
          max: prev?.max ?? (target == 'discord_user' ? 200 : 100),
          mute: false,
          serverLabel: null,
          text: null,
          error: null,
          missing: true,
          updatedAt: now,
        );
        _put(key, next);
        return next;
      }
      final parsed = _parseState(raw, now);
      _put(key, parsed);
      return parsed;
    } on SliderOfflineException {
      _syncBindings();
      if (epoch != _bindingEpoch) return null;
      _hadOfflineError = true;
      // Transient offline / network error: retain last valid cached value if we have one,
      // or remain gracefully unloaded (null -> '—') on cold offline start.
      return _cache[key];
    } catch (e) {
      _syncBindings();
      if (epoch != _bindingEpoch) return null;
      if (isDragging(key) || (_writeGen[key] ?? 0) != startGen) {
        return _cache[key];
      }
      final msg = '$e'.replaceFirst('Exception: ', '');
      final prev = _cache[key];
      final next = SliderSnapshot(
        volume: null,
        max: prev?.max ?? 100,
        mute: false,
        serverLabel: prev?.serverLabel,
        text: null,
        error: msg,
        missing: false,
        updatedAt: DateTime.now(),
      );
      _put(key, next);
      return next;
    }
  }

  /// Refreshes currently cached audio slider targets (called on SignalR volume updates or
  /// after Audio-tab mixer edits so Deck sliders stay live and aligned).
  void scheduleAudioRefresh() {
    _syncBindings();
    final audioKeys = _matchingKeys(_audioTargets);
    if (audioKeys.isEmpty) return;
    _audioDebounce?.cancel();
    _audioDebounce = Timer(const Duration(milliseconds: 250), () {
      _refreshKeys(_matchingKeys(_audioTargets));
    });
  }

  /// Refreshes currently cached media seek slider targets (called on SignalR media updates).
  void scheduleMediaRefresh() {
    _syncBindings();
    final mediaKeys = _matchingKeys(const {'media'});
    if (mediaKeys.isEmpty) return;
    _mediaDebounce?.cancel();
    _mediaDebounce = Timer(const Duration(milliseconds: 250), () {
      _refreshKeys(_matchingKeys(const {'media'}));
    });
  }

  /// Clears cached slider values (e.g. on PC switch).
  void clear() {
    _bindingEpoch++;
    _pendingWrites.clear();
    _writing.clear();
    _audioDebounce?.cancel();
    _audioDebounce = null;
    _mediaDebounce?.cancel();
    _mediaDebounce = null;
    _cache.clear();
    _inFlight.clear();
    _writeGen.clear();
    _draggingCount.clear();
    _hadOfflineError = false;
    _notify();
  }

  void _disposeInternal() {
    _bindingEpoch++;
    _pendingWrites.clear();
    _writing.clear();
    _pollTimer?.cancel();
    _pollTimer = null;
    _audioDebounce?.cancel();
    _audioDebounce = null;
    _mediaDebounce?.cancel();
    _mediaDebounce = null;
    _volumeSubCleanup?.call();
    _volumeSubCleanup = null;
    _mediaSubCleanup?.call();
    _mediaSubCleanup = null;
    _reconnectCleanup?.call();
    _reconnectCleanup = null;
    _cache.clear();
    _meta.clear();
    _inFlight.clear();
    _subscribers.clear();
    _draggingCount.clear();
    _writeGen.clear();
    _boundClient = null;
    _boundSignalR = null;
    _boundPcId = null;
    _hadOfflineError = false;
    _wasDisconnected = false;
  }

  DeckOSClient? _syncBindings() {
    DeckOSClient? client;
    try {
      client = Injector.get<DeckOSClient>();
    } catch (_) {
      client = null;
    }
    SignalRService? signalR;
    try {
      signalR = Injector.get<SignalRService>();
    } catch (_) {
      signalR = null;
    }

    final pcId = PcStore.currentId;
    final clientChanged = !identical(_boundClient?.target, client);
    final pcChanged = _boundPcId != pcId || _boundBaseUrl != client?.currentBaseUrl;

    if (clientChanged || pcChanged) {
      _bindingEpoch++;
      _pendingWrites.clear();
      _writing.clear();
      _boundClient = client != null ? WeakReference<DeckOSClient>(client) : null;
      _boundPcId = pcId;
      _boundBaseUrl = client?.currentBaseUrl;
      _audioDebounce?.cancel();
      _audioDebounce = null;
      _mediaDebounce?.cancel();
      _mediaDebounce = null;
      _cache.clear();
      _inFlight.clear();
      _writeGen.clear();
      _draggingCount.clear();
      _hadOfflineError = false;
      if (clientChanged) {
        _meta.removeWhere((k, _) => !_subscribers.containsKey(k));
      }
    }

    if (!identical(_boundSignalR?.target, signalR)) {
      _volumeSubCleanup?.call();
      _volumeSubCleanup = null;
      _mediaSubCleanup?.call();
      _mediaSubCleanup = null;
      _reconnectCleanup?.call();
      _reconnectCleanup = null;
      _boundSignalR = signalR != null ? WeakReference<SignalRService>(signalR) : null;
      _wasDisconnected = false;
      if (signalR != null) {
        _bindSignalR(signalR);
      }
    }

    return client;
  }

  void _bindSignalR(SignalRService sr) {
    var firstVolume = true;
    _volumeSubCleanup = sr.volumeUpdates.subscribe((updates) {
      if (firstVolume) {
        firstVolume = false;
        return;
      }
      if (updates.isEmpty) return;
      scheduleAudioRefresh();
    });

    var firstMedia = true;
    _mediaSubCleanup = sr.mediaStateUpdates.subscribe((update) {
      if (firstMedia) {
        firstMedia = false;
        return;
      }
      if (update == null) return;
      scheduleMediaRefresh();
    });

    var wasConnected = sr.connectionStatus.value == 'Connected';
    _reconnectCleanup = effect(() {
      final status = sr.connectionStatus.value;
      final connected = status == 'Connected';
      if (!connected && wasConnected) {
        _wasDisconnected = true;
      } else if (connected && !wasConnected) {
        final shouldRefresh = _wasDisconnected || _hadOfflineError;
        _wasDisconnected = false;
        if (shouldRefresh) {
          untracked(() {
            // Refresh actively mounted sliders first, then any cached entries (bounded).
            final keys = <String>{
              ..._subscribers.keys,
              ..._cache.keys.take(12),
            };
            _refreshKeys(keys);
          });
        }
      }
      wasConnected = connected;
    });
  }

  void _ensurePollTimer() {
    if (_pollTimer?.isActive ?? false) return;
    if (_subscribers.isEmpty) return;
    _pollTimer = Timer.periodic(pollInterval, (_) {
      if (_subscribers.isEmpty) {
        _pollTimer?.cancel();
        _pollTimer = null;
        return;
      }
      _refreshKeys(_subscribers.keys.toList(growable: false));
    });
  }

  Iterable<String> _matchingKeys(Set<String> targets) {
    final keys = <String>{};
    for (final k in _subscribers.keys) {
      final meta = _meta[k];
      if (meta != null && targets.contains(meta.target)) keys.add(k);
    }
    for (final k in _cache.keys) {
      final meta = _meta[k];
      if (meta != null && targets.contains(meta.target)) keys.add(k);
    }
    return keys;
  }

  void _refreshKeys(Iterable<String> keys) {
    for (final key in keys) {
      if (isDragging(key)) continue;
      final meta = _meta[key];
      if (meta == null) continue;
      unawaited(refresh(meta.target, meta.params));
    }
  }

  void _bumpWriteGen(String key) {
    _writeGen[key] = ++_nextWriteGen;
  }

  void _put(String key, SliderSnapshot snap) {
    final prev = _cache.remove(key);
    _cache[key] = snap;
    while (_cache.length > maxEntries) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest);
      if (!_subscribers.containsKey(oldest)) {
        _meta.remove(oldest);
        if (!_inFlight.containsKey(oldest) && !_writing.containsKey(oldest)) {
          _writeGen.remove(oldest);
        }
      }
    }
    if (prev == null || !prev.sameVisibleData(snap)) {
      _notify();
    }
  }

  void _notify() {
    revision.value = revision.value + 1;
  }

  static SliderSnapshot _parseState(Map<String, dynamic> state, DateTime now) {
    return SliderSnapshot(
      volume: (state['volume'] as num?)?.round(),
      max: ((state['max'] as num?)?.round() ?? 100).clamp(1, 1 << 30),
      mute: state['mute'] == true,
      serverLabel: state['label'] as String?,
      text: state['text'] as String?,
      error: null,
      missing: false,
      updatedAt: now,
    );
  }
}
