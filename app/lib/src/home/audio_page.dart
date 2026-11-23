import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';
import 'home_controller.dart';
import 'mixer_page.dart';
import 'now_playing_card.dart';

/// Tela única de áudio, no molde do Control Center: o que está tocando no topo e os
/// dispositivos com um controle vertical por app. Deitado (largura > 600), saídas e
/// entradas lado a lado; em pé, uma rolagem só (Saídas e logo abaixo Entradas).
class AudioPage extends StatelessWidget {
  final HomeController controller;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;

  /// Folga extra no fim da lista para rolar tudo acima da pílula flutuante em retrato.
  final double bottomNavClearance;

  const AudioPage({
    super.key,
    required this.controller,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    this.bottomNavClearance = 0,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        bottom: false,
        child: Watch((context) {
          final outputs = controller.outputs.value;
          final inputs = controller.inputs.value;
          final sessions = controller.mediaSessions.value.values
              .where((s) => s.id != null)
              .toList();

          final header = LargeTitleHeader(
            title: tr('Áudio'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(isFullscreen
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded),
                  color: c.label,
                  tooltip: isFullscreen ? tr('Sair da tela cheia') : tr('Tela cheia'),
                  onPressed: onToggleFullscreen,
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  color: c.label,
                  tooltip: tr('Configurações'),
                  onPressed: () => Navigator.of(context).pushNamed('/config'),
                ),
              ],
            ),
          );

          List<Widget> section(String title, List<MixerEntity> items, bool input) => [
                _SectionHeader(title),
                if (items.isEmpty)
                  _Empty(input
                      ? tr('Nenhuma entrada encontrada.')
                      : tr('Nenhuma saída encontrada.'))
                else
                  for (final e in items)
                    MixerDeviceCard(item: e, controller: controller, isInput: input),
              ];

          final nowPlaying = [
            for (final s in sessions)
              NowPlayingCard(
                session: s,
                onCommand: (cmd) => controller.sendMediaCommand(s.id!, cmd),
              ),
          ];

          return LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth > 600; // deitado/tablet
            Future<void> refresh() async {
              await controller.fetchOutputs();
              await controller.fetchInputs();
              await controller.fetchMediaSessions();
            }

            return RefreshIndicator.adaptive(
              onRefresh: refresh,
              child: ListView(
                padding: EdgeInsets.only(
                  bottom: math.max(56.0, bottomNavClearance + 16.0),
                ),
                children: [
                  header,
                  ...nowPlaying,
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                            child: Column(children: section(tr('Saídas'), outputs, false))),
                        Expanded(
                            child: Column(children: section(tr('Entradas'), inputs, true))),
                      ],
                    )
                  else ...[
                    ...section(tr('Saídas'), outputs, false),
                    const SizedBox(height: AppleSpacing.xs),
                    ...section(tr('Entradas'), inputs, true),
                  ],
                ],
              ),
            );
          });
        }),
      ),
    );
  }
}

/// Cabeçalho de seção no molde do Ajustes: caixa alta, cinza, pequeno.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppleSpacing.xxl, AppleSpacing.md, AppleSpacing.xxl, AppleSpacing.xxs),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: type.footnote.copyWith(
            color: c.secondaryLabel,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppleSpacing.xl),
      child: Center(
        child: Text(text, style: type.subheadline.copyWith(color: c.secondaryLabel)),
      ),
    );
  }
}
