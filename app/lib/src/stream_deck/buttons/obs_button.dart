import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/studio/tally_page.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'button_look.dart';

/// OBS: cena atual, gravando, ao vivo, câmera virtual, replay e pausa refletem o OBS.
class ObsButtonRenderer extends ButtonRenderer {
  const ObsButtonRenderer();

  @override
  Widget build(ButtonLook look) {
    final ds = Injector.get<SignalRService>().obsState.value;
    final params = look.params;
    String named(String key, String fallback) =>
        (params[key]?.isNotEmpty ?? false) ? params[key]! : fallback;

    final op = look.op('setScene');
    final scene = params['scene'] ?? '';
    final inProgram = scene.isNotEmpty && ds['currentScene'] == scene;
    final inPreview = scene.isNotEmpty && !inProgram && ds['previewScene'] == scene;
    // Cena: vermelho no programa (ou a cor escolhida no botão), verde no preview.
    final Color? stateColor = op != 'setscene'
        ? null
        : inPreview
            ? tallyPreviewColor
            : look.activeColor ?? tallyProgramColor;

    final (IconData icon, bool active, String label) = switch (op) {
      'setscene' => (
          CupertinoIcons.film,
          inProgram || inPreview,
          named('scene', tr('Cena')),
        ),
      'togglerecord' => (
          CupertinoIcons.largecircle_fill_circle,
          ds['recording'] == true,
          ds['recording'] == true ? tr('Gravando') : tr('Gravar'),
        ),
      'togglestream' => (
          Icons.sensors,
          ds['streaming'] == true,
          ds['streaming'] == true ? tr('No ar') : 'Live',
        ),
      'togglevirtualcam' => (CupertinoIcons.videocam_fill, ds['virtualCam'] == true, tr('Câmera virtual')),
      'togglereplaybuffer' => (CupertinoIcons.arrow_counterclockwise, ds['replayBuffer'] == true, 'Replay buffer'),
      'savereplay' => (CupertinoIcons.tray_arrow_down_fill, false, tr('Salvar replay')),
      'toggleinputmute' => (CupertinoIcons.mic_slash_fill, false, named('inputName', tr('Mutar fonte'))),
      'togglesourcevisibility' => (CupertinoIcons.eye_fill, false, named('sourceName', tr('Fonte'))),
      'togglefilter' => (Icons.auto_fix_high, false, named('filterName', tr('Filtro'))),
      'togglerecordpause' => (
          ds['recordPaused'] == true ? CupertinoIcons.play_fill : CupertinoIcons.pause_fill,
          ds['recordPaused'] == true,
          ds['recordPaused'] == true ? tr('Retomar') : tr('Pausar gravação'),
        ),
      'createchapter' => (CupertinoIcons.bookmark_fill, false, tr('Capítulo')),
      'screenshot' => (CupertinoIcons.camera_fill, false, tr('Captura')),
      _ => (CupertinoIcons.videocam_fill, false, 'OBS'),
    };
    return look.tile(
      active: active,
      activeColor: stateColor,
      icon: Icon(icon),
      label: look.ownLabel ?? label,
      keepLabel: const {
        'setscene',
        'toggleinputmute',
        'togglesourcevisibility',
        'togglefilter',
      }.contains(op),
    );
  }
}
