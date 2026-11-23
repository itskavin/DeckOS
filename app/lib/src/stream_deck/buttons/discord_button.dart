import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../deck_preloader.dart';
import 'button_look.dart';

/// Discord: mudo, ensurdecer, canal atual e modo de voz refletem o estado real.
class DiscordButtonRenderer extends ButtonRenderer {
  const DiscordButtonRenderer();

  @override
  void init(ButtonLook look) {
    unawaited(DeckPreloader.instance.ensureDiscordState());
  }

  @override
  Widget build(ButtonLook look) {
    final ds = Injector.get<SignalRService>().discordState.value;
    final params = look.params;
    final op = look.op('toggleMute');
    IconData icon;
    var active = false;
    String label;

    if (op.contains('deaf')) {
      active = ds['deaf'] == true;
      icon = active ? CupertinoIcons.headphones : CupertinoIcons.headphones;
      label = tr('Ensurdecer');
    } else if (op == 'joinchannel') {
      final channel = params['channelId'];
      active = channel != null && channel.isNotEmpty && ds['channelId'] == channel;
      icon = active ? CupertinoIcons.headphones : CupertinoIcons.arrow_right_to_line;
      label = (params['channelName']?.isNotEmpty ?? false) ? params['channelName']! : tr('Canal');
    } else if (op == 'disconnect' || op == 'leavechannel') {
      icon = CupertinoIcons.phone_down_fill;
      label = tr('Sair');
    } else if (op.contains('inputvolume')) {
      icon = op.contains('up') ? CupertinoIcons.mic_fill : CupertinoIcons.mic;
      label = op.contains('up') ? 'Mic +' : 'Mic −';
    } else if (op.contains('outputvolume')) {
      icon = op.contains('up') ? CupertinoIcons.speaker_3_fill : CupertinoIcons.speaker_1_fill;
      label = op.contains('up') ? tr('Som +') : tr('Som −');
    } else if (op.contains('voicemode') || op.contains('ptt')) {
      active = ds['voiceMode'] == 'PUSH_TO_TALK';
      icon = active ? Icons.record_voice_over : Icons.graphic_eq;
      label = active ? 'PTT' : tr('Voz');
    } else if (op.startsWith('usermute')) {
      icon = CupertinoIcons.person_crop_circle_badge_xmark;
      label = (params['userName']?.isNotEmpty ?? false) ? params['userName']! : tr('Mutar');
    } else if (op == 'uservolume') {
      icon = CupertinoIcons.person_fill;
      label = (params['userName']?.isNotEmpty ?? false) ? params['userName']! : 'Vol';
    } else {
      active = ds['mute'] == true;
      icon = active ? CupertinoIcons.mic_slash_fill : CupertinoIcons.mic_fill;
      label = tr('Mutar');
    }
    return look.tile(active: active, icon: Icon(icon), label: look.ownLabel ?? label);
  }

  @override
  void optimisticTap(ButtonLook look, SignalRService signalR) {
    // Só os liga/desliga; entrar em canal, volume etc. esperam o PC.
    final op = look.op('toggleMute');
    final cur = Map<String, dynamic>.from(signalR.discordState.value);
    // Como o Discord faz: ensurdecer também muta, e desmutar tira o surdo. Sem isso o
    // botão de mudo ficava errado até a confirmação do PC.
    if (op == 'togglemute') {
      cur['mute'] = !(cur['mute'] == true);
      if (cur['mute'] == false) cur['deaf'] = false;
    } else if (op.contains('deaf')) {
      cur['deaf'] = !(cur['deaf'] == true);
      if (cur['deaf'] == true) cur['mute'] = true;
    } else if (op.contains('voicemode') || op.contains('ptt')) {
      cur['voiceMode'] = cur['voiceMode'] == 'PUSH_TO_TALK' ? 'VOICE_ACTIVITY' : 'PUSH_TO_TALK';
    } else {
      return;
    }
    signalR.discordState.value = cur;
  }
}
