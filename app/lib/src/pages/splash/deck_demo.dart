import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/core/deckos_client/demo/demo_icons.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

/// Deck de demonstração para capturas de tela e revisão de design sem um PC. Só existe
/// num build com `--dart-define=DECKOS_DEMO=true`; nos builds normais a constante é
/// falsa e o compilador descarta este código (e os dados) inteiro.
const kDeckDemo = bool.fromEnvironment('DECKOS_DEMO');

/// Grava o deck de demonstração como "último deck salvo" e finge a conexão. O deck abre
/// pelo caminho offline de sempre.
Future<void> seedDeckDemo() async {
  if (!kDeckDemo) return;
  DeckButton b(String id, int row, int col, String? icon,
          {String? label, String? color, DeckAction? action, String? dyn, Map<String, String>? dp}) =>
      DeckButton(
        id: id,
        row: row,
        column: col,
        iconName: icon,
        label: label,
        backgroundColor: color,
        action: action ?? DeckAction(type: 'hotkey'),
        dynamicType: dyn,
        dynamicParameters: dp,
      );
  DeckAction media(String c) => DeckAction(type: 'media', parameters: {'command': c});
  // App: só o ícone colorido (o PNG que o configurador grava ao soltar um app).
  Future<DeckButton> app(String id, int row, int col, String name) async => DeckButton(
        id: id,
        row: row,
        column: col,
        label: name,
        iconBase64: base64Encode(await demoIconPng(name)),
        action: DeckAction(type: 'launch_app', parameters: {'path': '/Applications/$name.app'}),
      );

  var i = 0;
  final design = [
    for (final name in ['Opera', 'Chrome', 'Discord', 'VS Code', 'WhatsApp', 'Claude', 'ChatGPT', 'Music'])
      await app('d${i + 1}', i ~/ 4, i++ % 4, name),
  ];

  final profiles = [
    DeckProfile(id: 'demo-design', name: 'Design', rows: 2, columns: 4, buttons: design),
    DeckProfile(id: 'demo-system', name: 'Sistema', rows: 2, columns: 4, buttons: [
      b('s1', 0, 0, 'camera'),
      b('s2', 0, 1, 'volume_off'),
      b('s3', 0, 2, 'volume_down'),
      b('s4', 0, 3, 'volume_up'),
      b('s5', 1, 0, 'mic'),
      b('s6', 1, 1, null, action: media('previous')),
      b('s7', 1, 2, null, action: media('playpause')),
      b('s8', 1, 3, null, action: media('next')),
    ]),
    DeckProfile(id: 'demo-stream', name: 'Live', rows: 2, columns: 4, buttons: [
      b('l1', 0, 0, null,
          action: DeckAction(type: 'obs', parameters: {'operation': 'toggleRecord'})),
      b('l2', 0, 1, null,
          action: DeckAction(type: 'obs', parameters: {'operation': 'setScene', 'scene': 'Câmera'})),
      b('l3', 0, 2, null,
          color: '#5865F2',
          action: DeckAction(type: 'discord', parameters: {'operation': 'toggleMute'})),
      b('l4', 0, 3, 'apps', action: DeckAction(type: 'open_profile', parameters: {'profileId': 'demo-design'}), label: 'Apps'),
      b('l5', 1, 0, null, dyn: 'cpu_monitor'),
      b('l6', 1, 1, null, dyn: 'memory_monitor'),
      b('l7', 1, 2, null, dyn: 'clock', dp: {'showDate': 'true'}),
      b('l8', 1, 3, null, action: DeckAction(type: 'timer', parameters: {'mode': 'countdown', 'durationMin': '5'})),
    ]),
  ];
  final sp = await SharedPreferences.getInstance();
  await sp.setString(PcStore.scoped('deck_cache'),
      jsonEncode(profiles.map((p) => p.toJson()).toList()));
  // Parâmetros da URL para as capturas: ?page=demo-system abre naquele perfil,
  // ?tab=0 abre na aba Áudio, ?toast=0 esconde o aviso, ?chrome=1 mostra a barra,
  // ?light=1 usa o tema claro e ?route=welcome abre as boas-vindas.
  final q = Uri.base.queryParameters;
  await sp.setString(PcStore.scoped('deck_last_profile'), q['page'] ?? 'demo-design');
  await sp.setInt('home_tab', int.tryParse(q['tab'] ?? '') ?? 1);
  if (q['light'] == '1') {
    final t = ThemeController.instance.settings;
    t.value = t.value.copyWith(mode: ThemeMode.light);
  }

  final sr = Injector.get<SignalRService>();
  sr.connectionStatus.value = 'Connected';
  sr.obsState.value = {'recording': true, 'currentScene': 'Câmera'};
  sr.discordState.value = {'mute': true};
  sr.systemStats.value = SystemStats.fromJson({
    'cpuUsage': 37.0,
    'ramUsage': 68.0,
    'ramTotal': 16384.0,
    'ramAvailable': 5243.0,
  });
  sr.seedState('ReceiveTimerState', {
    'l8': {'mode': 'countdown', 'running': true, 'elapsedMs': 92000, 'durationMs': 300000},
    '_receivedAt': DateTime.now().millisecondsSinceEpoch,
  });
}

/// Mixer e música de demonstração para a tela de áudio.
List<MixerEntity> demoOutputs() => [
      MixerEntity(
        id: 'out1',
        volume: 72,
        mute: false,
        config: MixerConfig(),
        device: MixerMaster(id: 'out1', title: 'Alto-falantes (Realtek)', volume: 72, mute: false, channels: [
          MixerChannel(id: 1, description: 'Spotify', volume: 64, mute: false),
          MixerChannel(id: 2, description: 'Discord', volume: 85, mute: false),
          MixerChannel(id: 3, description: 'Chrome', volume: 40, mute: true),
          MixerChannel(id: 4, description: 'Steam', volume: 22, mute: false),
        ]),
      ),
    ];

List<MixerEntity> demoInputs() => [
      MixerEntity(
        id: 'in1',
        volume: 55,
        mute: false,
        config: MixerConfig(),
        device: MixerMaster(id: 'in1', title: 'Microfone (Shure MV7)', volume: 55, mute: false, channels: const []),
      ),
    ];

Map<String, MediaSession> demoMedia() => {
      'Spotify': MediaSession(
        id: 'Spotify',
        title: 'Midnight City',
        artist: 'M83',
        playbackStatus: 'Playing',
        canPlayPause: true,
        canGoNext: true,
        canGoPrevious: true,
        position: 104,
        duration: 243,
      ),
    };
