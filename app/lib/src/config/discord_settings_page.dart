import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/material.dart';

import 'settings_kit.dart';

/// Configuração do plugin de Discord: o usuário cria o PRÓPRIO app no Discord
/// Developer Portal (cada um usa o seu — o RPC só funciona pro dono do app, sem
/// precisar de aprovação) e cola aqui o Client ID + Secret.
class DiscordSettingsPage extends StatefulWidget {
  const DiscordSettingsPage({super.key});

  @override
  State<DiscordSettingsPage> createState() => _DiscordSettingsPageState();
}

class _DiscordSettingsPageState extends State<DiscordSettingsPage> {
  static const redirectUri = 'http://localhost:4787/discord';

  final _idCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  bool _busy = false;

  /// O PC já tem Client ID + Secret: não precisa preencher nada para reconectar.
  bool get _secretSaved =>
      Injector.get<SignalRService>().discordState.value['configured'] == true;

  @override
  void initState() {
    super.initState();
    // Puxa o estado atual uma vez (o signal também reflete updates ao vivo).
    Injector.get<DeckOSClient>()
        .getDiscordState()
        .then((s) {
          if (s != null && mounted) {
            Injector.get<SignalRService>().discordState.value =
                Map<String, dynamic>.from(s);
            // Os campos abriam sempre vazios, e parecia que o PC tinha perdido as
            // credenciais. O Client ID vem do PC; o Secret fica lá e não é mostrado.
            final savedId = s['clientId'];
            if (savedId is String && _idCtrl.text.isEmpty) {
              _idCtrl.text = savedId;
            }
            // O hint do Secret depende do estado que acabou de chegar.
            setState(() {});
          }
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  /// Aviso no topo do formulário: resultado de salvar/conectar.
  (BannerTone, String)? _notice;

  void _show(BannerTone tone, String msg) {
    if (mounted) setState(() => _notice = (tone, msg));
  }

  Future<void> _save() async {
    final id = _idCtrl.text.trim();
    final secret = _secretCtrl.text.trim();
    if (id.isEmpty || secret.isEmpty) {
      _show(BannerTone.warning, tr('Preencha o Client ID e o Client Secret.'));
      return;
    }
    setState(() => _busy = true);
    try {
      await Injector.get<DeckOSClient>().setDiscordConfig(id, secret);
      // Não limpa o campo: antes o secret sumia ao salvar e parecia que não
      // tinha salvo. Ele fica visível (mascarado) confirmando que foi enviado.
      _show(
        BannerTone.success,
        tr('Credenciais salvas. Agora toque em "Conectar".'),
      );
    } catch (_) {
      _show(
        BannerTone.error,
        tr('Não foi possível salvar (servidor acessível?).'),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      final state = await Injector.get<DeckOSClient>().connectDiscord();
      Injector.get<SignalRService>().discordState.value =
          Map<String, dynamic>.from(state);
      _show(BannerTone.success, tr('Discord conectado!'));
    } catch (e) {
      _show(BannerTone.error, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      final res =
          await Injector.get<DeckOSClient>().postJson('/api/discord/disconnect');
      if (res is Map && mounted) {
        Injector.get<SignalRService>().discordState.value =
            Map<String, dynamic>.from(res);
      }
      _show(BannerTone.info, tr('Desconectado'));
    } catch (e) {
      _show(BannerTone.error, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget() async {
    setState(() => _busy = true);
    try {
      final res =
          await Injector.get<DeckOSClient>().deleteJson('/api/discord/config');
      if (res is Map && mounted) {
        Injector.get<SignalRService>().discordState.value =
            Map<String, dynamic>.from(res);
      }
      if (mounted) {
        _idCtrl.clear();
        _secretCtrl.clear();
      }
      _show(BannerTone.info, tr('Configuração removida.'));
    } catch (e) {
      _show(BannerTone.error, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final c = AppleColors.of(context);
      final ds = Injector.get<SignalRService>().discordState.value;
      final configured = ds['configured'] == true;
      final connected = ds['connected'] == true;
      final channel = ds['channelName'];
      return SettingsScaffold(
        title: 'Discord',
        largeTitle: false,
        maxWidth: 600,
        children: [
          IntegrationHero(
            brand: IntegrationBrand.of('discord'),
            title: 'Discord',
            state: connected
                ? LinkState.connected
                : configured
                ? LinkState.configured
                : LinkState.warning,
            status: connected
                ? tr('Conectado')
                : configured
                ? tr('Desconectado')
                : tr('Não configurado'),
            detail: connected
                ? (channel != null && '$channel'.isNotEmpty
                      ? tr('Conectado — no canal "{channel}".', {
                          'channel': channel,
                        })
                      : null)
                : configured
                ? tr(
                    'Configurado, mas desconectado. Com o Discord aberto no PC, toque em '
                    '"Conectar" (não precisa preencher os campos de novo).',
                  )
                : null,
          ),
          if (_notice != null)
            AppleBanner(
              tone: _notice!.$1,
              message: _notice!.$2,
              onDismiss: () => setState(() => _notice = null),
              margin: const EdgeInsets.fromLTRB(
                AppleSpacing.screen,
                0,
                AppleSpacing.screen,
                AppleSpacing.xl,
              ),
            ),
          SetupStepsSection(
            title: tr('Como obter o Client ID e o Secret'),
            initiallyExpanded: !configured,
            footer: tr(
              'Cada usuário usa o próprio app — o RPC do Discord só libera o dono do app, '
              'sem precisar de aprovação. Não compartilhe o seu Secret.',
            ),
            steps: [
              tr(
                'Acesse discord.com/developers/applications e clique em "New Application".',
              ),
              tr(
                'Em OAuth2, copie o Client ID e o Client Secret (Reset Secret se preciso).',
              ),
              tr(
                'Ainda em OAuth2 → Redirects, adicione o endereço abaixo e Salve:',
              ),
            ],
            stepChildren: const {2: CopyField(value: redirectUri)},
          ),
          InsetGroupedSection(
            header: tr('Credenciais'),
            children: [
              FormTextRow(
                label: 'Client ID',
                controller: _idCtrl,
                hint: tr('Cole aqui'),
                keyboardType: TextInputType.number,
              ),
              FormTextRow(
                label: 'Client Secret',
                controller: _secretCtrl,
                secure: true,
                hint: _secretSaved
                    ? tr('Salvo no PC (preencha só para trocar)')
                    : tr('Cole aqui'),
              ),
            ],
          ),
          FormActions(
            footer: tr(
              'Ao conectar pela 1ª vez, aprove a janela que abrir no Discord do PC.',
            ),
            children: [
              PrimaryButton(
                label: tr('Conectar'),
                icon: Icons.link_rounded,
                loading: _busy,
                onPressed: _busy ? null : _connect,
                expand: true,
              ),
              SecondaryButton(
                label: tr('Salvar credenciais'),
                onPressed: _busy ? null : _save,
                expand: true,
                color: c.accent,
              ),
              if (connected)
                SecondaryButton(
                  label: tr('Desconectar'),
                  color: c.orange,
                  onPressed: _busy ? null : _disconnect,
                  expand: true,
                ),
              if (configured || connected)
                SecondaryButton(
                  label: tr('Esquecer'),
                  color: c.red,
                  onPressed: _busy ? null : _forget,
                  expand: true,
                ),
            ],
          ),
        ],
      );
    });
  }
}
