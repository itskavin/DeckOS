import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// "Manter a tela ligada": mantém o celular aceso enquanto o app está em primeiro plano
/// (Deck, Áudio, Ajustes) e libera o bloqueio ao ir para segundo plano ou fechar.
///
/// Ligado por padrão no aparelho (o deck fica ao lado do monitor); o usuário pode
/// desligar em Ajustes e a escolha fica salva. Observa o ciclo de vida do app uma única
/// vez, sem depender de reconstrução de rota e sem bloquear o primeiro frame no startup.
class KeepAwake {
  KeepAwake._();

  static const _key = 'keep_screen_on';

  /// Padrão quando o usuário ainda não escolheu: manter aceso em primeiro plano.
  static const bool defaultEnabled = true;

  static final enabled = signal(defaultEnabled);

  static _KeepAwakeLifecycleObserver? _observer;
  static bool _isForeground = true;
  static bool? _lastApplied;
  static bool _postFrameScheduled = false;

  /// Gancho para testes: substitui [WakelockPlus.toggle].
  @visibleForTesting
  static Future<void> Function(bool enable)? toggleOverride;

  /// Gancho para testes: simula se está no configurador desktop do navegador.
  @visibleForTesting
  static bool? isConfiguratorOverride;

  static bool get _isConfigurator =>
      isConfiguratorOverride ?? WebMode.configurator;

  static bool get isForeground => _isForeground;

  /// Deve manter a tela acesa agora? (preferência ligada + app em primeiro plano + modo deck).
  static bool get shouldHoldWakeLock =>
      enabled.value && _isForeground && !_isConfigurator;

  /// Registra o observador de ciclo de vida do app (idempotente).
  static void ensureInitialized() {
    if (_observer != null) return;
    final binding = WidgetsBinding.instance;
    final current = binding.lifecycleState;
    _isForeground = current == null || current == AppLifecycleState.resumed;
    _observer = _KeepAwakeLifecycleObserver();
    binding.addObserver(_observer!);
  }

  /// Lê a preferência salva e agenda a aplicação do wake lock sem bloquear o primeiro frame.
  static Future<void> load({bool deferApplyUntilFirstFrame = false}) async {
    ensureInitialized();
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_key) ?? defaultEnabled;
    } catch (_) {}
    if (deferApplyUntilFirstFrame) {
      _scheduleAfterFirstFrame();
    } else {
      restore();
    }
  }

  static Future<void> set(bool value) async {
    ensureInitialized();
    enabled.value = value;
    restore();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (_) {}
  }

  /// Volta ao que o usuário escolheu (as telas de estúdio ligam a tela enquanto abertas)
  /// respeitando o estado de primeiro/segundo plano do app.
  static void restore() {
    ensureInitialized();
    _sync(force: true);
  }

  static void _onLifecycleChanged(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    _isForeground = active;
    // Ao voltar para o primeiro plano, reaplica mesmo se o último estado conhecido era true:
    // o Android/navegador pode soltar o wake lock ao ir para o fundo ou recriar a janela.
    _sync(force: active);
  }

  static void _scheduleAfterFirstFrame() {
    if (_postFrameScheduled) return;
    _postFrameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _postFrameScheduled = false;
      _sync(force: true);
    });
  }

  static void _sync({bool force = false}) {
    final want = shouldHoldWakeLock;
    if (!force && _lastApplied == want) return;
    _lastApplied = want;
    final toggle = toggleOverride;
    final Future<void> op = toggle != null
        ? toggle(want)
        : WakelockPlus.toggle(enable: want);
    // Sem await: chamada de canal de plataforma não bloqueia startup nem UI.
    // Sem suporte no aparelho (navegador antigo): a tela só pode apagar sozinha.
    unawaited(op.catchError((_) {}));
  }

  /// Restaura estado interno entre testes.
  @visibleForTesting
  static void resetForTest() {
    if (_observer != null) {
      WidgetsBinding.instance.removeObserver(_observer!);
      _observer = null;
    }
    enabled.value = defaultEnabled;
    _isForeground = true;
    _lastApplied = null;
    _postFrameScheduled = false;
    toggleOverride = null;
    isConfiguratorOverride = null;
  }
}

class _KeepAwakeLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    KeepAwake._onLifecycleChanged(state);
  }
}
