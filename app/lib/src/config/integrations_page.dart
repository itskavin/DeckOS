import 'package:deckos/core/core.dart';
import 'package:deckos/src/studio/tally_page.dart';
import 'package:flutter/material.dart';

import 'account_integration_page.dart';
import 'discord_settings_page.dart';
import 'obs_settings_page.dart';
import 'pc_info.dart';
import 'settings_kit.dart';
import 'soundboard_settings_page.dart';
import 'tuya_settings_page.dart';

/// Lista de todas as integrações, com o atalho para a tela de cada uma.
class IntegrationsPage extends StatelessWidget {
  const IntegrationsPage({super.key});

  /// Tela de configuração pela chave usada no schema (`settings`).
  static Widget? pageFor(String? key) => switch (key) {
    'obs' => const ObsSettingsPage(),
    'discord' => const DiscordSettingsPage(),
    'tuya' => const TuyaSettingsPage(),
    'soundboard' => const SoundboardSettingsPage(),
    'homeassistant' => const AccountIntegrationPage(spec: homeAssistantSpec),
    'spotify' => const AccountIntegrationPage(spec: spotifySpec),
    'twitch' => const AccountIntegrationPage(spec: twitchSpec),
    'youtube' => const AccountIntegrationPage(spec: youTubeSpec),
    'hue' => const AccountIntegrationPage(spec: hueSpec),
    'mqtt' => const AccountIntegrationPage(spec: mqttSpec),
    'streamerbot' => const AccountIntegrationPage(spec: streamerBotSpec),
    'vtubestudio' => const AccountIntegrationPage(spec: vtubeStudioSpec),
    'vmix' => const AccountIntegrationPage(spec: vmixSpec),
    'companion' => const AccountIntegrationPage(spec: companionSpec),
    'mairlist' => const AccountIntegrationPage(spec: mairlistSpec),
    'radiodj' => const AccountIntegrationPage(spec: radioDjSpec),
    'tally' => const TallyPage(),
    _ => null,
  };

  /// Grupos da lista: título (pt) e as integrações (chave, nome, descrição em pt).
  static const _groups = [
    (
      'Transmissão',
      [
        ('discord', 'Discord', 'Mudo, canais de voz, volume por usuário'),
        ('obs', 'OBS Studio', 'Cenas, gravação, transmissão, fontes'),
        ('twitch', 'Twitch', 'Marcador, clipe, anúncio, chat e enquete'),
        ('youtube', 'YouTube', 'Chat da live e espectadores'),
        (
          'streamerbot',
          'Streamer.bot',
          'Ações do Streamer.bot, com argumentos',
        ),
        ('vtubestudio', 'VTube Studio', 'Atalhos e modelos do VTube Studio'),
      ],
    ),
    (
      'Música e som',
      [
        ('spotify', 'Spotify', 'Player, curtir, playlists e capa no botão'),
        ('soundboard', 'Soundboard', 'Sons do MyInstants: saída e volume'),
      ],
    ),
    (
      'Casa inteligente',
      [
        ('homeassistant', 'Home Assistant', 'Luzes, cenas, scripts e sensores'),
        (
          'tuya',
          'Casa inteligente (Tuya)',
          'Smart Life, Nova Digital e outras marcas',
        ),
        ('hue', 'Philips Hue', 'Luzes, salas e cenas pelo Hue Bridge'),
        ('mqtt', 'MQTT', 'Publicar mensagens no seu broker'),
      ],
    ),
    (
      'Estúdio de rádio e TV',
      [
        (
          'tally',
          'Tally e ON AIR',
          'O celular em tela cheia como luz de no ar',
        ),
        ('vmix', 'vMix', 'Corte, entradas, overlays, gravação e tally'),
        (
          'companion',
          'Companion',
          'O celular como superfície do Bitfocus Companion',
        ),
        ('mairlist', 'mAirList', 'No ar, automação, players e cartwall'),
        ('radiodj', 'RadioDJ', 'Player, AutoDJ, entrada ao vivo e carts'),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) => const _IntegrationList();
}

/// A lista, com quem está conectado (GET /api/integrations). Recarrega ao voltar de uma tela.
class _IntegrationList extends StatefulWidget {
  const _IntegrationList();

  @override
  State<_IntegrationList> createState() => _IntegrationListState();
}

class _IntegrationListState extends State<_IntegrationList> {
  Map<String, bool> _connected = {};
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
    if (PcInfo.current.value == null) PcInfo.load();
  }

  Future<void> _load() async {
    try {
      final list =
          await Injector.get<DeckOSClient>().getJson('/api/integrations')
              as List;
      if (!mounted) return;
      setState(
        () => _connected = {
          for (final i in list) '${(i as Map)['name']}': i['connected'] == true,
        },
      );
    } catch (_) {
      // PC antigo, sem a lista: fica sem os indicadores.
    }
  }

  Future<void> _open(String key) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => IntegrationsPage.pageFor(key)!));
    _load();
  }

  /// O PC sabe fazer? Soundboard depende de áudio do sistema; o resto é rede.
  bool _available(String key, PcInfo? info) => switch (key) {
    'soundboard' => info?.has('soundboard') ?? true,
    _ => true,
  };

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final info = PcInfo.current.value;
      final q = _query.trim().toLowerCase();
      final groups = [
        for (final (title, items) in IntegrationsPage._groups)
          (
            tr(title),
            [
              for (final (key, name, sub) in items)
                if (_available(key, info) &&
                    (q.isEmpty ||
                        tr(name).toLowerCase().contains(q) ||
                        tr(sub).toLowerCase().contains(q)))
                  (key, tr(name), tr(sub)),
            ],
          ),
      ].where((g) => g.$2.isNotEmpty).toList();
      final connected = _connected.entries
          .where((e) => e.value && e.key != 'soundboard')
          .length;

      return SettingsScaffold(
        title: tr('Integrações'),
        subtitle: connected == 0
            ? tr('Conecte o DeckOS aos apps que você usa.')
            : connected == 1
            ? tr('1 conectada')
            : tr('{n} conectadas', {'n': connected}),
        maxWidth: 1000,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpacing.screen,
              0,
              AppleSpacing.screen,
              AppleSpacing.lg,
            ),
            child: AppleSearchField(
              placeholder: tr('Buscar'),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          LayoutBuilder(
            builder: (context, box) {
              final grid = box.maxWidth >= 720;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (title, items) in groups)
                    grid
                        ? _GridSection(
                            header: title,
                            columns: box.maxWidth >= 940 ? 3 : 2,
                            children: [
                              for (final (key, name, sub) in items)
                                _IntegrationCard(
                                  brand: IntegrationBrand.of(key),
                                  title: name,
                                  subtitle: sub,
                                  connected: _statusOf(key),
                                  onTap: () => _open(key),
                                ),
                            ],
                          )
                        : InsetGroupedSection(
                            header: title,
                            children: [
                              for (final (key, name, sub) in items)
                                ListRow(
                                  leading: BrandChip(
                                    IntegrationBrand.of(key).icon,
                                    color: IntegrationBrand.of(key).color,
                                  ),
                                  title: name,
                                  subtitle: sub,
                                  trailing: _StatusLabel(
                                    connected: _statusOf(key),
                                  ),
                                  chevron: true,
                                  onTap: () => _open(key),
                                ),
                            ],
                          ),
                  if (groups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppleSpacing.xxl),
                      child: EmptyState(
                        icon: Icons.search_rounded,
                        title: tr('Nenhum resultado'),
                        message: tr('Tente outra palavra.'),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      );
    });
  }

  /// Conectado, não configurado, ou nulo (sem estado: soundboard, tally, PC antigo).
  bool? _statusOf(String key) {
    if (key == 'soundboard' || key == 'tally') return null;
    return _connected[key];
  }
}

/// "Conectado ✓" em verde ou "Não configurado" em cinza.
class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.connected});
  final bool? connected;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    if (connected == null) return const SizedBox.shrink();
    if (connected!) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(tr('Conectado'), style: type.footnote.copyWith(color: c.green)),
          const SizedBox(width: 4),
          Icon(
            Icons.check_circle_rounded,
            size: 16,
            color: c.green,
          ),
        ],
      );
    }
    return Text(
      tr('Não configurado'),
      style: type.footnote.copyWith(color: c.tertiaryLabel),
    );
  }
}

/// Grupo em grade (tela larga): cabeçalho como o das listas e cartões lado a lado.
class _GridSection extends StatelessWidget {
  const _GridSection({
    required this.header,
    required this.columns,
    required this.children,
  });

  final String header;
  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpacing.screen,
        0,
        AppleSpacing.screen,
        AppleSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpacing.md,
              0,
              AppleSpacing.md,
              AppleSpacing.xs,
            ),
            child: Text(
              header,
              style: type.footnote.copyWith(
                color: c.secondaryLabel,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, box) {
              const gap = AppleSpacing.sm;
              final w = (box.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final ch in children) SizedBox(width: w, child: ch),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _IntegrationCard extends StatelessWidget {
  const _IntegrationCard({
    required this.brand,
    required this.title,
    required this.subtitle,
    required this.connected,
    required this.onTap,
  });

  final IntegrationBrand brand;
  final String title;
  final String subtitle;
  final bool? connected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return ApplePressable(
      onTap: onTap,
      pressedScale: 0.97,
      child: Container(
        constraints: const BoxConstraints(minHeight: 132),
        padding: const EdgeInsets.all(AppleSpacing.md),
        decoration: BoxDecoration(
          color: c.secondaryGroupedBackground,
          borderRadius: BorderRadius.circular(AppleRadii.lg),
          border: Border.all(color: c.separator, width: 1),
          boxShadow: c.isDark ? null : AppleShadows.card(Brightness.light),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                BrandChip(brand.icon, color: brand.color, size: 38),
                const SizedBox(width: AppleSpacing.xs),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _StatusLabel(connected: connected),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppleSpacing.md),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.headline.copyWith(color: c.label),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: type.footnote.copyWith(color: c.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
