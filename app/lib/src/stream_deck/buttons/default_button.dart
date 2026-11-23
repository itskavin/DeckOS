import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'button_look.dart';

/// Botões sem visual próprio: atalho, abrir app, multi-ação, webhook, Steam (com a capa)...
class DefaultButtonRenderer extends ButtonRenderer {
  const DefaultButtonRenderer();

  @override
  Widget build(ButtonLook look) {
    final b = look.button;
    // Jogo da Steam: a capa ocupa o botão, não 32 px.
    final cover = look.type == 'steam' && (b.iconBase64?.isNotEmpty ?? false);
    return look.tile(
      active: false,
      icon: cover
          ? ButtonLook.cover(b.iconBase64!, fallback: Icons.sports_esports)
          : look.icon(),
      label: look.ownLabel,
    );
  }
}

/// Mídia: tocar/pausar reflete o que está tocando no Windows.
class MediaButtonRenderer extends ButtonRenderer {
  const MediaButtonRenderer();

  String _command(ButtonLook look) => (look.params['command'] ?? 'playpause').toLowerCase();

  bool _isPlayPause(String c) => c == 'playpause' || c == 'toggle';

  @override
  Widget build(ButtonLook look) {
    final c = _command(look);
    final IconData icon;
    final String label;
    switch (c) {
      case 'next':
        (icon, label) = (CupertinoIcons.forward_fill, tr('Próxima'));
      case 'previous':
        (icon, label) = (CupertinoIcons.backward_fill, tr('Anterior'));
      case 'stop':
        (icon, label) = (CupertinoIcons.stop_fill, tr('Parar'));
      case 'pause':
        (icon, label) = (CupertinoIcons.pause_fill, 'Pause');
      case 'play':
        (icon, label) = (CupertinoIcons.play_fill, 'Play');
      default:
        // O "play/pause" dos controles do sistema; tocando, ganha o brilho de ligado.
        (icon, label) = (CupertinoIcons.playpause_fill, 'Play/Pause');
    }
    return Semantics(
      label: look.ownLabel == null ? label : null,
      child: look.tile(
        active: false,
        icon: look.icon(fallback: icon),
        label: look.ownLabel,
      ),
    );
  }

  @override
  void optimisticTap(ButtonLook look, SignalRService signalR) {
    if (_isPlayPause(_command(look))) signalR.mediaPlaying.value = !signalR.mediaPlaying.value;
  }
}

/// Mixer: o mudo de um app reflete o estado real; volume de dispositivo usa o ícone da operação.
class MixerButtonRenderer extends ButtonRenderer {
  const MixerButtonRenderer();

  /// Processo do botão de mudo de app, ou null.
  String? _muteProcess(ButtonLook look) {
    final op = look.op('toggleMute');
    final process = look.params['processName'];
    return process != null && process.isNotEmpty && op.contains('mute') ? process : null;
  }

  @override
  void init(ButtonLook look) {
    final process = _muteProcess(look);
    if (process == null) return;
    try {
      final sr = Injector.get<SignalRService>();
      if (sr.muteStates.value.containsKey(process)) return;
      Injector.get<DeckOSClient>().getMuteState(process).then((muted) {
        if (muted == null) return;
        sr.muteStates.value = {...sr.muteStates.value, process: muted};
      }).catchError((_) {});
    } catch (_) {}
  }

  @override
  Widget build(ButtonLook look) {
    final process = _muteProcess(look);
    if (process != null) {
      final muted = Injector.get<SignalRService>().muteStates.value[process];
      return look.tile(
        active: muted == true,
        icon: muted == null
            ? look.icon()
            : Icon(muted ? CupertinoIcons.speaker_slash_fill : CupertinoIcons.speaker_3_fill),
        label: look.ownLabel,
      );
    }
    final hasDevice = (look.params['deviceId'] ?? '').isNotEmpty;
    final IconData? volumeIcon = !hasDevice
        ? null
        : switch (look.op('')) {
            'volumeup' => CupertinoIcons.speaker_3_fill,
            'volumedown' => CupertinoIcons.speaker_1_fill,
            'setvolume' => CupertinoIcons.slider_horizontal_3,
            _ => null,
          };
    return look.tile(
      active: false,
      icon: look.icon(fallback: volumeIcon),
      label: look.ownLabel,
    );
  }

  @override
  void optimisticTap(ButtonLook look, SignalRService signalR) {
    final process = _muteProcess(look);
    if (process == null) return;
    final op = look.op('toggleMute');
    final now = signalR.muteStates.value[process] == true;
    signalR.muteStates.value = {
      ...signalR.muteStates.value,
      process: op == 'mute' ? true : (op == 'unmute' ? false : !now),
    };
  }
}
