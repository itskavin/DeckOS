import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

import 'settings_kit.dart';

/// Tema do app: preset, modo claro/escuro, cor de destaque e estilo dos botões.
/// Tudo vale na hora e fica salvo no aparelho. A prévia do deck no topo mostra o resultado.
class AppearanceSettingsPage extends StatelessWidget {
  const AppearanceSettingsPage({super.key});

  ThemeController get _ctrl => ThemeController.instance;

  void _set(ThemeSettings next) => _ctrl.update(next);

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final s = _ctrl.settings.value;
      final c = AppleColors.of(context);
      final lang = AppLanguage.choice.value;
      final langCode = AppLanguage.available.any((l) => l.code == lang)
          ? lang
          : 'auto';
      final langName =
          AppLanguage.available
              .where((l) => l.code == lang)
              .firstOrNull
              ?.name ??
          tr('Automático');
      return SettingsScaffold(
        title: tr('Aparência'),
        actions: [
          TextButton(
            onPressed: () => _set(const ThemeSettings()),
            child: Text(tr('Restaurar')),
          ),
        ],
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppleSpacing.xxl,
              AppleSpacing.xs,
              AppleSpacing.xxl,
              AppleSpacing.xxl,
            ),
            child: Center(child: SizedBox(width: 460, child: _DeckPreview())),
          ),
          _CardSection(
            header: tr('Modo'),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedControl<ThemeMode>(
                segments: {
                  ThemeMode.light: _Segment(
                    Icons.light_mode_rounded,
                    tr('Claro'),
                  ),
                  ThemeMode.dark: _Segment(
                    Icons.dark_mode_rounded,
                    tr('Escuro'),
                  ),
                  ThemeMode.system: _Segment(
                    Icons.brightness_auto_rounded,
                    tr('Sistema'),
                  ),
                },
                value: s.mode,
                onChanged: (m) => _set(s.copyWith(mode: m)),
              ),
            ),
          ),
          _CardSection(
            header: tr('Cor de destaque'),
            child: Wrap(
              spacing: AppleSpacing.sm,
              runSpacing: AppleSpacing.sm,
              children: [
                _Swatch(
                  color: s.preset.accent,
                  selected: s.accent == null,
                  tooltip: tr('Do tema'),
                  badge: Icons.auto_awesome_rounded,
                  onTap: () => _set(s.copyWith(accent: () => null)),
                ),
                for (final color in kAccentChoices)
                  _Swatch(
                    color: color,
                    selected: s.accent?.toARGB32() == color.toARGB32(),
                    onTap: () => _set(s.copyWith(accent: () => color)),
                  ),
              ],
            ),
          ),
          _CardSection(
            header: tr('Estilo dos botões'),
            footer: tr(
              'No estilo Moldura e Contorno, a cor de cada botão vira a cor do '
              'ícone e do detalhe do canto.',
            ),
            padding: const EdgeInsets.symmetric(vertical: AppleSpacing.md),
            child: SizedBox(
              height: 112,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpacing.md,
                ),
                children: [
                  _StyleCard(
                    settings: s.copyWith(tileStyle: () => null),
                    label: tr('Do tema'),
                    selected: s.tileStyle == null,
                    onTap: () => _set(s.copyWith(tileStyle: () => null)),
                  ),
                  for (final st in DeckTileStyle.values)
                    _StyleCard(
                      settings: s.copyWith(tileStyle: () => st),
                      label: st.label,
                      selected: s.tileStyle == st,
                      onTap: () => _set(s.copyWith(tileStyle: () => st)),
                    ),
                ],
              ),
            ),
          ),
          InsetGroupedSection(
            footer: tr(
              'Desligado, os botões com ícone mostram apenas o ícone. Botões sem ícone sempre mostram o texto.',
            ),
            children: [
              ListRow(
                leading: ListRowIcon(Icons.text_fields_rounded, color: c.gray),
                title: tr('Mostrar nomes nos botões'),
                trailing: AppleSwitch(
                  value: s.effectiveShowLabels,
                  onChanged: (v) => _set(s.copyWith(showLabels: () => v)),
                ),
              ),
            ],
          ),
          _CardSection(
            header: tr('Tema'),
            footer: tr(
              'Trocar de tema volta a cor de destaque e o estilo dos botões para os dele.',
            ),
            padding: const EdgeInsets.symmetric(vertical: AppleSpacing.md),
            child: SizedBox(
              height: 128,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpacing.md,
                ),
                children: [
                  for (final p in kThemePresets)
                    _PresetCard(
                      preset: p,
                      selected: p.id == s.presetId,
                      // Trocar de tema volta destaque e estilo para os dele.
                      onTap: () => _set(
                        s.copyWith(
                          presetId: p.id,
                          accent: () => null,
                          tileStyle: () => null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Um item por arquivo de idioma: idioma novo aparece aqui sozinho.
          InsetGroupedSection(
            header: tr('Idioma'),
            footer: tr('Automático segue o idioma do aparelho.'),
            children: [
              ListRow(
                leading: ListRowIcon(Icons.language_rounded, color: c.blue),
                title: tr('Idioma'),
                value: langName,
                chevron: true,
                onTap: () async {
                  final v = await showChoiceSheet<String>(
                    context: context,
                    title: tr('Idioma'),
                    selected: langCode,
                    choices: [
                      Choice('auto', tr('Automático')),
                      for (final l in AppLanguage.available)
                        Choice(l.code, l.name),
                    ],
                  );
                  if (v != null) AppLanguage.set(v);
                },
              ),
            ],
          ),
        ],
      );
    });
  }
}

/// Segmento com ícone e texto.
class _Segment extends StatelessWidget {
  const _Segment(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppleSpacing.xxs + 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15),
          const SizedBox(width: AppleSpacing.xxs + 2),
          Text(label),
        ],
      ),
    );
  }
}

/// Grupo com cabeçalho e rodapé, mas com conteúdo livre (não linhas).
class _CardSection extends StatelessWidget {
  const _CardSection({
    required this.header,
    required this.child,
    this.footer,
    this.padding = const EdgeInsets.all(AppleSpacing.md),
  });

  final String header;
  final String? footer;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return InsetGroupedSection(
      header: header,
      footer: footer,
      children: [Padding(padding: padding, child: child)],
    );
  }
}

/// Um deck de exemplo dentro de um celular deitado, desenhado com o tema atual.
class _DeckPreview extends StatelessWidget {
  const _DeckPreview();

  @override
  Widget build(BuildContext context) {
    final deck = DeckTheme.of(context);
    Widget tile(
      IconData icon,
      String label,
      Color? color, {
      bool active = false,
    }) {
      return DeckTile(
        color: color,
        active: active,
        child: LayoutBuilder(
          // Segue a opção "Mostrar nomes nos botões".
          builder: (context, box) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: box.maxHeight * (deck.showLabels ? 0.36 : 0.42),
              ),
              if (deck.showLabels) ...[
                SizedBox(height: box.maxHeight * 0.04),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: box.maxHeight * 0.13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      );
    }

    final tiles = [
      tile(
        Icons.play_arrow_rounded,
        'YouTube',
        const Color(0xFFFF3B30),
      ),
      tile(
        Icons.sports_esports_rounded,
        'Discord',
        const Color(0xFF5865F2),
      ),
      tile(Icons.mic_off_rounded, tr('Mudo'), null, active: true),
      tile(Icons.volume_up_rounded, 'Volume', const Color(0xFFFFCC00)),
      tile(Icons.music_note_rounded, 'Spotify', const Color(0xFF1DB954)),
      tile(Icons.videocam_rounded, 'OBS', null),
      tile(Icons.lightbulb_rounded, tr('Luz'), const Color(0xFFFF9500)),
      tile(Icons.dark_mode_rounded, tr('Dormir'), const Color(0xFF5E5CE6)),
    ];

    return Semantics(
      label: tr('Prévia do deck'),
      child: PhoneFrame(
        screenColor: deck.background,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 10, 12, 10),
          child: Column(
            children: [
              for (var r = 0; r < 2; r++) ...[
                if (r > 0) const SizedBox(height: 7),
                Expanded(
                  child: Row(
                    children: [
                      for (var i = 0; i < 4; i++) ...[
                        if (i > 0) const SizedBox(width: 7),
                        Expanded(
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: tiles[r * 4 + i],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Borda de seleção (anel na cor de destaque) em volta de um cartão de amostra.
class _Selectable extends StatelessWidget {
  const _Selectable({
    required this.selected,
    required this.onTap,
    required this.label,
    required this.child,
    this.width = 92,
  });

  final bool selected;
  final VoidCallback onTap;
  final String label;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: ApplePressable(
        onTap: onTap,
        pressedScale: 0.96,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.only(right: AppleSpacing.sm),
            child: Column(
              children: [
                Expanded(
                  child: AnimatedContainer(
                    duration: AppleMotion.of(context, AppleMotion.fast),
                    padding: const EdgeInsets.all(3),
                    decoration: ShapeDecoration(
                      shape: AppleShapes.squircle(
                        AppleRadii.md + 3,
                        side: BorderSide(
                          color: selected ? c.accent : Colors.transparent,
                          width: 2.5,
                        ),
                      ),
                    ),
                    child: child,
                  ),
                ),
                const SizedBox(height: AppleSpacing.xs - 2),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (selected) ...[
                      Icon(
                        Icons.check_circle_rounded,
                        size: 14,
                        color: c.accent,
                      ),
                      const SizedBox(width: 3),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.caption1.copyWith(
                          color: selected ? c.label : c.secondaryLabel,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Uma tecla desenhada num estilo, sobre o fundo do deck.
class _StyleCard extends StatelessWidget {
  const _StyleCard({
    required this.settings,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ThemeSettings settings;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sample = buildAppTheme(settings, Theme.of(context).brightness);
    final deck = sample.extension<DeckTheme>() ?? DeckTheme.of(context);
    return _Selectable(
      selected: selected,
      onTap: onTap,
      label: label,
      width: 104,
      child: Theme(
        data: sample,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: deck.background,
            shape: AppleShapes.squircle(AppleRadii.md),
          ),
          child: const Padding(
            padding: EdgeInsets.all(AppleSpacing.sm),
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: DeckTile(
                  color: Color(0xFF5865F2),
                  child: Icon(Icons.mic_rounded, size: 24),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Amostra de um tema nomeado: o fundo dele com três teclas no estilo dele.
class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final ThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Mini-amostra sempre no visual escuro do preset, com o estilo de botão dele.
    final sample = buildAppTheme(
      ThemeSettings(presetId: preset.id),
      Brightness.dark,
    );
    Widget key(IconData icon, Color? color, {bool active = false}) => Expanded(
      child: AspectRatio(
        aspectRatio: 1,
        child: DeckTile(
          color: color,
          active: active,
          child: Icon(icon, size: 14),
        ),
      ),
    );
    return _Selectable(
      selected: selected,
      onTap: onTap,
      label: preset.name,
      width: 132,
      child: Theme(
        data: sample,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: preset.background,
            shape: AppleShapes.squircle(
              AppleRadii.md,
              side: BorderSide(
                color: Colors.white.withValues(alpha: 0.08),
                width: 0.5,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppleSpacing.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    key(Icons.bolt_rounded, preset.accent),
                    const SizedBox(width: 5),
                    key(Icons.mic_off_rounded, null, active: true),
                    const SizedBox(width: 5),
                    key(Icons.music_note_rounded, null),
                  ],
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    key(Icons.play_arrow_rounded, null),
                    const SizedBox(width: 5),
                    key(Icons.videocam_rounded, preset.accent),
                    const SizedBox(width: 5),
                    const Expanded(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: DeckEmptyTile(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bolinha de cor de destaque; a escolhida ganha o anel e o visto.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
    this.tooltip,
    this.badge,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;
  final IconData? badge;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final on = AppleColors.onColor(color);
    final swatch = Semantics(
      button: true,
      selected: selected,
      label: tooltip ?? tr('Cor de destaque'),
      child: ApplePressable(
        onTap: onTap,
        pressedScale: 0.9,
        child: AnimatedContainer(
          duration: AppleMotion.of(context, AppleMotion.fast),
          width: 40,
          height: 40,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? color : Colors.transparent,
              width: 2,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: c.separator, width: 0.5),
            ),
            child: selected
                ? Icon(Icons.check_rounded, color: on, size: 18)
                : (badge != null ? Icon(badge, color: on, size: 16) : null),
          ),
        ),
      ),
    );
    return tooltip == null ? swatch : Tooltip(message: tooltip!, child: swatch);
  }
}
