import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'button_look.dart';
import 'colors.dart';

/// Home Assistant: entidade ligada acende (com brilho e cor da luz); "só mostrar" exibe o valor.
class HomeAssistantButtonRenderer extends ButtonRenderer {
  const HomeAssistantButtonRenderer();

  static const _onStates = {
    'on', 'open', 'opening', 'playing', 'unlocked', 'home', 'heat', 'cool',
    'heat_cool', 'auto', 'dry', 'fan_only', 'cleaning', 'active',
  };

  static IconData _icon(String domain, bool on) => switch (domain) {
        'light' => on ? CupertinoIcons.lightbulb_fill : CupertinoIcons.lightbulb,
        'switch' || 'input_boolean' => on ? Icons.toggle_on : Icons.toggle_off,
        'fan' => Icons.mode_fan_off_outlined,
        'cover' => on ? Icons.blinds : Icons.blinds_closed,
        'lock' => on ? CupertinoIcons.lock_open_fill : CupertinoIcons.lock_fill,
        'media_player' => on ? Icons.play_circle : Icons.speaker,
        'climate' => CupertinoIcons.thermometer,
        'scene' => Icons.palette_outlined,
        'script' => CupertinoIcons.play_fill,
        'automation' => Icons.smart_toy_outlined,
        'sensor' || 'binary_sensor' => Icons.sensors,
        'person' || 'device_tracker' => CupertinoIcons.person_fill,
        'vacuum' => Icons.cleaning_services,
        _ => CupertinoIcons.house_fill,
      };

  @override
  Widget build(ButtonLook look) {
    final ha = Injector.get<SignalRService>().stateOf('ReceiveHomeAssistantState');
    final id = look.params['entityId'] ?? '';
    final domain = id.contains('.') ? id.split('.').first : '';
    final entities = ha['entities'] as Map? ?? const {};
    final e = entities[id] is Map ? Map<String, dynamic>.from(entities[id] as Map) : null;
    final state = '${e?['state'] ?? ''}';
    final name = (e?['name'] as String?) ??
        (id.contains('.') ? id.split('.').last : 'Home Assistant');

    if (look.op('toggle') == 'display') {
      final unit = e?['unit'] as String?;
      final value = state.isEmpty ? '—' : (unit != null ? '$state $unit' : state);
      return look.tile(
        active: false,
        icon: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ),
        label: look.ownLabel ?? name,
        keepLabel: true,
      );
    }
    final on = _onStates.contains(state);
    final brightness = e?['brightness'] as int?;
    final label = look.ownLabel ?? name;
    return look.tile(
      active: on && domain != 'scene' && domain != 'script',
      activeColor: parseHexColor(e?['color'] as String?),
      icon: look.hasOwnIcon ? look.icon() : Icon(_icon(domain, on)),
      label: on && brightness != null ? '$label · $brightness%' : label,
      keepLabel: brightness != null && on,
    );
  }
}

/// Spotify: play/pause, curtida, aleatório e repetir refletem a conta; "mostrar o que
/// está tocando" traz a capa.
class SpotifyButtonRenderer extends ButtonRenderer {
  const SpotifyButtonRenderer();

  @override
  Widget build(ButtonLook look) {
    final sp = Injector.get<SignalRService>().stateOf('ReceiveSpotifyState');
    final op = look.op('playPause');
    if (op == 'nowplaying') {
      final cover = sp['coverBase64'] as String?;
      final track = sp['track'] as String?;
      return look.tile(
        active: false,
        icon: cover != null && cover.isNotEmpty
            ? ButtonLook.cover(cover, fraction: 0.6, fallback: CupertinoIcons.music_note)
            : const Icon(CupertinoIcons.music_note),
        label: look.ownLabel ?? (track == null ? 'Spotify' : '$track\n${sp['artist'] ?? ''}'),
        keepLabel: true,
      );
    }
    final (IconData icon, bool active, String label) = switch (op) {
      'next' => (CupertinoIcons.forward_end_fill, false, tr('Próxima')),
      'previous' => (CupertinoIcons.backward_end_fill, false, tr('Anterior')),
      'like' => (
          sp['liked'] == true ? Icons.favorite : Icons.favorite_border,
          sp['liked'] == true,
          tr('Curtir'),
        ),
      'shuffle' => (Icons.shuffle, sp['shuffle'] == true, tr('Aleatório')),
      'repeat' => (
          sp['repeat'] == 'track' ? Icons.repeat_one : Icons.repeat,
          sp['repeat'] != null && sp['repeat'] != 'off',
          tr('Repetir'),
        ),
      'volume' => (
          (int.tryParse(look.params['step'] ?? '') ?? 10) < 0 ? CupertinoIcons.speaker_1_fill : CupertinoIcons.speaker_3_fill,
          false,
          sp['volume'] != null ? 'Vol ${sp['volume']}%' : 'Volume',
        ),
      'playlist' => (Icons.queue_music, false, 'Playlist'),
      _ => (sp['playing'] == true ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill, false, 'Spotify'),
    };
    return look.tile(
      active: active,
      icon: look.hasOwnIcon ? look.icon() : Icon(icon),
      label: look.ownLabel ?? label,
      keepLabel: op == 'volume',
    );
  }
}

/// Twitch e YouTube: "só mostrar" acende ao vivo, com os espectadores.
class LiveButtonRenderer extends ButtonRenderer {
  final String stateEvent;
  final IconData statusIcon;

  const LiveButtonRenderer(this.stateEvent, this.statusIcon);

  @override
  Widget build(ButtonLook look) {
    final st = Injector.get<SignalRService>().stateOf(stateEvent);
    final op = look.op('');
    final live = st['live'] == true;
    final viewers = st['viewers'];
    final (IconData icon, String label) = switch (op) {
      'marker' => (CupertinoIcons.bookmark_fill, tr('Marcador')),
      'clip' => (Icons.movie_creation_outlined, tr('Clipe')),
      'ad' => (Icons.campaign, tr('Anúncio')),
      'chat' => (Icons.chat, 'Chat'),
      'poll' => (Icons.poll_outlined, tr('Enquete')),
      'title' => (Icons.title, tr('Título')),
      _ => (
          statusIcon,
          live
              ? (viewers != null ? tr('{n} assistindo', {'n': viewers}) : tr('Ao vivo'))
              : tr('Fora do ar'),
        ),
    };
    return look.tile(
      active: op == 'status' && live,
      icon: look.hasOwnIcon ? look.icon() : Icon(icon),
      // No "só mostrar" o texto é o estado; nos outros vale o rótulo do usuário.
      label: op == 'status' ? label : (look.ownLabel ?? label),
      keepLabel: op == 'status',
    );
  }
}
