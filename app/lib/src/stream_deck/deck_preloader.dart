import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/layout/desktop_sidebar.dart'
    show topLevelPageOf, topLevelPages;
import 'package:deckos/src/stream_deck/slider_state_store.dart';
import 'package:deckos/src/stream_deck/widgets/slider_deck_button.dart'
    show sliderTypes;
import 'package:flutter/foundation.dart';

/// Bounded, non-blocking preloader for DeckOS page data & decoded icons.
///
/// Prewarms:
/// 1. Distinct slider targets across deck pages (prioritizing current -> adjacent -> other
///    top-level pages -> folders, and local audio/media sliders before external lights),
///    capped at [maxSliderPrewarm] with bounded concurrency ([maxConcurrency]).
/// 2. Distinct app mute states & single-flight Discord state for buttons across pages.
/// 3. Decoded base64 button icons into [LiquidGlassCache] (capped at [maxIconPrewarm],
///    yielded in small chunks so first deck render and swipes stay jank-free).
///
/// Explicitly NEVER launches Windows apps, polls installed apps, or probes AI providers.
class DeckPreloader {
  DeckPreloader._();

  static DeckPreloader _instance = DeckPreloader._();
  static DeckPreloader get instance => _instance;

  static const int maxSliderPrewarm = 12;
  static const int maxMutePrewarm = 12;
  static const int maxIconPrewarm = 48;
  static const int maxConcurrency = 3;

  static const _localSliderTargets = {
    'output',
    'input',
    'app',
    'media',
    'monitor',
    'obs',
    'discord_user',
  };

  final Map<String, Future<void>> _inFlightMute = <String, Future<void>>{};
  Future<void>? _inFlightDiscord;
  DateTime? _lastDiscordFetchAt;
  int _generation = 0;

  WeakReference<DeckOSClient>? _boundClient;
  String? _boundPcId;

  static void resetForTest() {
    _instance._generation++;
    _instance._inFlightMute.clear();
    _instance._inFlightDiscord = null;
    _instance._lastDiscordFetchAt = null;
    _instance._boundClient = null;
    _instance._boundPcId = null;
    _instance = DeckPreloader._();
  }

  /// Cancels any ongoing icon prewarm loop (e.g. when a new profile list arrives).
  void cancelPending() {
    _generation++;
  }

  /// Single-flight fetch of a process mute state, skipping if already known in SignalR.
  Future<void> ensureMuteState(String process) {
    final client = _syncBindings();
    if (client == null || process.isEmpty) return Future<void>.value();
    SignalRService sr;
    try {
      sr = Injector.get<SignalRService>();
    } catch (_) {
      return Future<void>.value();
    }
    if (sr.muteStates.value.containsKey(process)) return Future<void>.value();
    return _inFlightMute[process] ??= () async {
      try {
        final muted = await client.getMuteState(process);
        if (!identical(_boundClient?.target, client)) return;
        if (muted == null) return;
        if (!sr.muteStates.value.containsKey(process)) {
          sr.muteStates.value = {...sr.muteStates.value, process: muted};
        }
      } catch (_) {
        // Best-effort hydration; button keeps its fallback icon until next update.
      } finally {
        _inFlightMute.remove(process);
      }
    }();
  }

  /// Single-flight fetch of Discord state, coalescing multiple Discord buttons on a page
  /// and skipping redundant fetches when SignalR or a recent fetch already hydrated it.
  Future<void> ensureDiscordState({bool force = false}) {
    final client = _syncBindings();
    if (client == null) return Future<void>.value();
    SignalRService sr;
    try {
      sr = Injector.get<SignalRService>();
    } catch (_) {
      return Future<void>.value();
    }
    final last = _lastDiscordFetchAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 5)) {
      return Future<void>.value();
    }
    // If SignalR already pushed a live state containing extra fields (or connected=true),
    // avoid firing redundant GETs on every page swipe.
    final current = sr.discordState.value;
    if (!force &&
        (current['connected'] == true || current.length > 3)) {
      return Future<void>.value();
    }
    return _inFlightDiscord ??= () async {
      final before = sr.discordState.value;
      try {
        final s = await client.getDiscordState();
        if (!identical(_boundClient?.target, client)) return;
        _lastDiscordFetchAt = DateTime.now();
        // Preserve newer state pushed by SignalR or optimistic tap while GET was in flight.
        if (s != null && identical(sr.discordState.value, before)) {
          sr.discordState.value = Map<String, dynamic>.from(s);
        }
      } catch (_) {
        // Best-effort hydration.
      } finally {
        _inFlightDiscord = null;
      }
    }();
  }

  /// Schedules bounded background prewarming of page data & icons for [profiles].
  /// Always yields so it never blocks the first frame or page render.
  void prewarm({
    required List<DeckProfile> profiles,
    DeckProfile? current,
    bool network = true,
    bool decodeImages = true,
  }) {
    if (profiles.isEmpty || WebMode.configurator) return;
    _syncBindings();

    final gen = ++_generation;
    final ordered = prioritizeProfiles(profiles, current);

    final localSliders = <({String key, String target, Map<String, String> params})>[];
    final externalSliders = <({String key, String target, Map<String, String> params})>[];
    final seenSliderKeys = <String>{};
    final muteProcesses = <String>[];
    final seenMutes = <String>{};
    var hasDiscord = false;
    final iconBase64s = <String>[];
    final seenIcons = <String>{};

    for (final profile in ordered) {
      for (final btn in profile.buttons) {
        if (sliderTypes.contains(btn.dynamicType) &&
            seenSliderKeys.length < maxSliderPrewarm) {
          final target = (btn.dynamicParameters?['target'] ?? 'output').trim().toLowerCase();
          final params = SliderStateStore.cleanParams(btn.dynamicParameters);
          final key = SliderStateStore.keyFor(target, params);
          if (seenSliderKeys.add(key)) {
            final entry = (key: key, target: target, params: params);
            if (_localSliderTargets.contains(target)) {
              localSliders.add(entry);
            } else {
              externalSliders.add(entry);
            }
          }
        }

        final action = btn.action;
        if (action != null) {
          if (action.type == 'mixer' && seenMutes.length < maxMutePrewarm) {
            final op = (action.parameters['operation'] ?? 'toggleMute').toLowerCase();
            final proc = action.parameters['processName']?.trim() ?? '';
            if (proc.isNotEmpty && op.contains('mute') && seenMutes.add(proc)) {
              muteProcesses.add(proc);
            }
          } else if (action.type == 'discord') {
            hasDiscord = true;
          }
        }

        if (iconBase64s.length < maxIconPrewarm) {
          final b64 = btn.iconBase64;
          if (b64 != null && b64.isNotEmpty && seenIcons.add(b64)) {
            iconBase64s.add(b64);
          }
        }
        if (iconBase64s.length < maxIconPrewarm) {
          final activeB64 = btn.activeIconBase64;
          if (activeB64 != null && activeB64.isNotEmpty && seenIcons.add(activeB64)) {
            iconBase64s.add(activeB64);
          }
        }
      }
    }

    if (network) {
      final sliderQueue = [...localSliders, ...externalSliders];
      if (sliderQueue.isNotEmpty) {
        unawaited(_prewarmSliders(sliderQueue, gen));
      }
      if (muteProcesses.isNotEmpty) {
        unawaited(_prewarmMutes(muteProcesses, gen));
      }
      if (hasDiscord) {
        unawaited(ensureDiscordState());
      }
    }

    if (iconBase64s.isNotEmpty) {
      unawaited(_prewarmIcons(iconBase64s, gen, decodeImages: decodeImages));
    }
  }

  /// Orders profiles: current page -> adjacent top-level pages -> remaining top-level pages
  /// -> sub-profiles (folders), preserving deduplicated order.
  @visibleForTesting
  static List<DeckProfile> prioritizeProfiles(
    List<DeckProfile> profiles,
    DeckProfile? current,
  ) {
    if (profiles.length <= 1) return profiles;
    final top = topLevelPages(profiles);
    final ordered = <DeckProfile>[];
    final added = <String>{};

    void add(DeckProfile? p) {
      if (p != null && added.add(p.id)) ordered.add(p);
    }

    add(current);
    final currentTop = current != null ? topLevelPageOf(profiles, current) : null;
    final curIdx = currentTop != null
        ? top.indexWhere((p) => p.id == currentTop.id)
        : 0;
    if (curIdx >= 0 && curIdx < top.length) {
      add(top[curIdx]);
      if (curIdx + 1 < top.length) add(top[curIdx + 1]);
      if (curIdx - 1 >= 0) add(top[curIdx - 1]);
    }
    for (final p in top) {
      add(p);
    }
    for (final p in profiles) {
      add(p);
    }
    return ordered;
  }

  Future<void> _prewarmSliders(
    List<({String key, String target, Map<String, String> params})> items,
    int gen,
  ) async {
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < items.length && gen == _generation) {
        final item = items[cursor++];
        try {
          await SliderStateStore.instance.ensureLoaded(item.target, item.params);
        } catch (_) {
          // Errors are tracked per-target inside SliderStateStore; never fail the batch.
        }
      }
    }

    final workers = items.length < maxConcurrency ? items.length : maxConcurrency;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  }

  Future<void> _prewarmMutes(List<String> processes, int gen) async {
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < processes.length && gen == _generation) {
        final proc = processes[cursor++];
        await ensureMuteState(proc);
      }
    }

    final workers = processes.length < maxConcurrency ? processes.length : maxConcurrency;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  }

  Future<void> _prewarmIcons(
    List<String> base64List,
    int gen, {
    required bool decodeImages,
  }) async {
    // Yield first so startup / page transition frames paint without contention.
    await Future<void>.microtask(() {});
    for (var i = 0; i < base64List.length; i++) {
      if (gen != _generation) return;
      final bytes = LiquidGlassCache.decodeBase64(base64List[i]);
      if (decodeImages && bytes != null) {
        final key = LiquidGlassCache.keyOf(bytes);
        if (!LiquidGlassCache.has(key)) {
          // Fire-and-forget GPU/codec decode (deduplicated inside LiquidGlassCache._pending)
          // so we don't block fake-async test frames while still warming real device frames.
          unawaited(LiquidGlassCache.ofBytes(bytes));
        }
      }
      if (i % 2 == 1) {
        await Future<void>.microtask(() {});
      }
    }
  }

  DeckOSClient? _syncBindings() {
    DeckOSClient? client;
    try {
      client = Injector.get<DeckOSClient>();
    } catch (_) {
      client = null;
    }
    final pcId = PcStore.currentId;
    if (!identical(_boundClient?.target, client) || _boundPcId != pcId) {
      _boundClient = client != null ? WeakReference<DeckOSClient>(client) : null;
      _boundPcId = pcId;
      _generation++;
      _inFlightMute.clear();
      _inFlightDiscord = null;
      _lastDiscordFetchAt = null;
    }
    return client;
  }
}
