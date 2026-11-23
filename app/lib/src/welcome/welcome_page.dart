import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/connection/constants.dart';
import 'package:deckos/src/services/server_discovery_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'onboarding.dart';
import 'pairing.dart';
import 'qr_viewfinder_page.dart';

/// Primeira tela de quem ainda não pareou, no molde das boas-vindas dos apps da Apple:
/// título grande, três passos com ícone e, embaixo, "Escanear código QR" e "Encontrar
/// PCs automaticamente". O app sozinho não faz nada: precisa do DeckOS rodando no PC.
/// Boa parte das instalações chega pelo APK solto, sem passar pelo README.
class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  static String get _shareText =>
      tr('Baixe o DeckOS para Windows: {url}', {'url': Constants.siteUrl});

  StreamSubscription<DiscoveredServer>? _search;
  final _scrollController = ScrollController();
  final List<DiscoveredServer> _found = [];
  bool _searching = false;
  bool _searched = false;
  bool _busy = false;

  @override
  void dispose() {
    _search?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// Rola até a lista de PCs achados para que ela não fique escondida abaixo dos passos.
  void _scrollToFound() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (target <= 0) return;
      _scrollController.animateTo(
        target,
        duration: AppleMotion.of(context, AppleMotion.normal),
        curve: AppleMotion.smooth,
      );
    });
  }

  /// Mais opções (cabo USB, chave...): a tela de configuração. Aberta a partir dela,
  /// só volta.
  void _moreOptions() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
    } else {
      nav.pushReplacementNamed('/config');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _goHome() => Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const AppleQrScanPage()),
    );
    if (raw == null || !mounted) return;
    setState(() => _busy = true);
    final ok = await pairWithQr(raw);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      _toast(tr('Esse QR não é de pareamento do DeckOS. Use o da janela "Parear dispositivo (QR)" do PC.'));
      return;
    }
    _toast(tr('Pareado com sucesso!'));
    _goHome();
  }

  void _discover() {
    _search?.cancel();
    setState(() {
      _found.clear();
      _searching = true;
      _searched = true;
    });
    _scrollToFound();
    _search = ServerDiscoveryService()
        .discover(timeout: const Duration(seconds: 5))
        .listen(
          (pc) {
            if (mounted) {
              setState(() => _found.add(pc));
              _scrollToFound();
            }
          },
          onError: (_) {},
          onDone: () {
            if (mounted) {
              setState(() => _searching = false);
              _scrollToFound();
            }
          },
        );
  }

  Future<void> _connect(String address) async {
    _search?.cancel();
    setState(() => _busy = true);
    final ok = await connectToAddress(address);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) _goHome();
  }

  Future<void> _typeAddress() async {
    final address = await showAppleSheet<String>(
      context: context,
      title: tr('Digitar o endereço'),
      builder: (_) => const _AddressSheet(),
    );
    if (address != null && address.trim().isNotEmpty && mounted) _connect(address);
  }

  Future<void> _openSite() async {
    final ok = await launchUrl(Uri.parse(Constants.siteUrl),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) _toast(tr('Não foi possível abrir o navegador.'));
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(const ClipboardData(text: Constants.siteUrl));
    if (mounted) _toast(tr('Link copiado.'));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final size = MediaQuery.sizeOf(context);
    // Em pé, os botões ficam presos embaixo (como nas boas-vindas do iOS); deitado,
    // vão no fim da lista para não comer a altura.
    final pinActions = size.height >= 560;

    final intro = <Widget>[
      const SizedBox(height: AppleSpacing.xxl),
      const AppIconMark(size: 76),
      const SizedBox(height: AppleSpacing.lg),
      Text(
        tr('Bem-vindo ao DeckOS'),
        textAlign: TextAlign.center,
        style: type.largeTitle.copyWith(color: c.label),
      ),
      const SizedBox(height: AppleSpacing.xs),
      Text(
        tr('Este celular vira um painel de botões para o seu PC. Para '
            'funcionar, ele precisa do programa DeckOS rodando no '
            'computador (Windows 10 ou 11).'),
        textAlign: TextAlign.center,
        style: type.subheadline.copyWith(color: c.secondaryLabel),
      ),
      const SizedBox(height: AppleSpacing.xxl),
      OnboardingFeatureRow(
        icon: Icons.computer_rounded,
        color: c.blue,
        title: tr('No PC, baixe o DeckOS'),
        body: tr('Abra este endereço no navegador do computador:'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SiteBox(onTap: _copyLink),
            const SizedBox(height: AppleSpacing.xs),
            Row(
              children: [
                Expanded(
                  child: SecondaryButton(
                    label: tr('Enviar link'),
                    icon: Icons.share_rounded,
                    compact: true,
                    expand: true,
                    onPressed: () =>
                        SharePlus.instance.share(ShareParams(text: _shareText)),
                  ),
                ),
                const SizedBox(width: AppleSpacing.xs),
                Expanded(
                  child: SecondaryButton(
                    label: tr('Copiar'),
                    icon: Icons.content_copy_rounded,
                    compact: true,
                    expand: true,
                    onPressed: _copyLink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppleSpacing.xs),
            Text(
              tr('Dica: "Enviar link" manda pelo WhatsApp ou e-mail para '
                  'você abrir no PC.'),
              style: type.footnote.copyWith(color: c.tertiaryLabel),
            ),
          ],
        ),
      ),
      OnboardingFeatureRow(
        icon: Icons.download_rounded,
        color: c.orange,
        title: tr('Instale e abra o DeckOS no PC'),
        body: tr('Rode o DeckOS-Setup.exe. Se o Windows avisar que o app não é '
            'reconhecido, clique em "Mais informações" → "Executar assim mesmo". '
            'Ele não abre janela: fica como um ícone na bandeja, perto do relógio. '
            'No Windows 11 o ícone pode estar escondido na setinha ^ ao lado.'),
      ),
      OnboardingFeatureRow(
        icon: Icons.qr_code_2_rounded,
        color: c.green,
        title: tr('Pareie este celular'),
        body: tr('Clique com o botão direito no ícone do DeckOS → '
            '"Parear dispositivo (QR)" e escaneie o código aqui no app. '
            'Celular e PC precisam estar na mesma rede Wi-Fi (ou ligados pelo '
            'cabo USB).'),
      ),
      if (_searched) _foundSection(c, type),
    ];

    final actions = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PrimaryButton(
          label: tr('Escanear código QR'),
          icon: Icons.qr_code_scanner_rounded,
          expand: true,
          loading: _busy,
          onPressed: _scan,
        ),
        if (!kIsWeb) ...[
          const SizedBox(height: AppleSpacing.xs),
          SecondaryButton(
            label: tr('Encontrar PCs automaticamente'),
            icon: Icons.wifi_rounded,
            expand: true,
            loading: _searching,
            onPressed: _discover,
          ),
        ],
        const SizedBox(height: AppleSpacing.xxs),
        Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton(onPressed: _typeAddress, child: Text(tr('Digitar o endereço'))),
            TextButton(onPressed: _moreOptions, child: Text(tr('Mais opções de conexão'))),
            TextButton(onPressed: _openSite, child: Text(tr('Ver o site neste celular'))),
          ],
        ),
      ],
    );

    const pad = EdgeInsets.symmetric(horizontal: AppleSpacing.xl);
    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    controller: _scrollController,
                    padding: pad,
                    children: [
                      ...intro,
                      if (!pinActions) ...[actions, const SizedBox(height: AppleSpacing.md)],
                    ],
                  ),
                ),
                if (pinActions)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppleSpacing.xl, AppleSpacing.sm, AppleSpacing.xl, AppleSpacing.xs),
                    child: actions,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// PCs achados na rede, no molde das listas do Ajustes.
  Widget _foundSection(AppleColors c, AppleTextStyles type) {
    return InsetGroupedSection(
      margin: const EdgeInsets.only(bottom: AppleSpacing.xl),
      header: tr('PCs na rede'),
      footer: !_searching && _found.isEmpty
          ? tr('Nenhum PC encontrado. Confira se o DeckOS está aberto no PC e se os dois '
              'estão na mesma rede Wi-Fi, ou escaneie o QR.')
          : null,
      children: [
        for (final pc in _found)
          ListRow(
            leading: ListRowIcon(Icons.computer_rounded, color: c.blue),
            title: pc.name ?? pc.ip,
            subtitle: [pc.address, if (pc.version != null) 'v${pc.version}'].join(' · '),
            trailing: Icon(Icons.wifi_rounded, size: 18, color: c.green),
            onTap: _busy ? null : () => _connect(pc.address),
          ),
        if (_searching)
          ListRow(
            leading: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: c.secondaryLabel,
              ),
            ),
            title: tr('Procurando PCs na rede…'),
            chevron: false,
          ),
        if (!_searching && _found.isEmpty)
          ListRow(
            leading: ListRowIcon(Icons.refresh_rounded, color: c.gray),
            title: tr('Procurar de novo'),
            onTap: _discover,
          ),
      ],
    );
  }
}

/// Folha para digitar o IP do PC ("192.168.0.10" ou "192.168.0.10:4787").
class _AddressSheet extends StatefulWidget {
  const _AddressSheet();

  @override
  State<_AddressSheet> createState() => _AddressSheetState();
}

class _AddressSheetState extends State<_AddressSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _done() => Navigator.of(context).pop(_ctrl.text.trim());

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppleSpacing.screen, AppleSpacing.xs, AppleSpacing.screen, AppleSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('O endereço aparece no menu do ícone do DeckOS, perto do relógio do PC.'),
            textAlign: TextAlign.center,
            style: type.subheadline.copyWith(color: c.secondaryLabel),
          ),
          const SizedBox(height: AppleSpacing.md),
          TextField(
            controller: _ctrl,
            autofocus: true,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _done(),
            style: type.body.copyWith(
                color: c.label, fontFeatures: const [FontFeature.tabularFigures()]),
            decoration: InputDecoration(
              hintText: '192.168.0.10',
              filled: true,
              fillColor: c.tertiaryGroupedBackground,
              prefixIcon: Icon(Icons.computer_rounded, color: c.secondaryLabel),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppleRadii.sm),
                borderSide: BorderSide(color: c.separator),
              ),
            ),
          ),
          const SizedBox(height: AppleSpacing.md),
          ValueListenableBuilder(
            valueListenable: _ctrl,
            builder: (context, v, _) => PrimaryButton(
              label: tr('Conectar'),
              expand: true,
              onPressed: v.text.trim().isEmpty ? null : _done,
            ),
          ),
        ],
      ),
    );
  }
}

/// O endereço em destaque, fácil de ler e digitar no PC. Tocar copia.
class _SiteBox extends StatelessWidget {
  final VoidCallback onTap;

  const _SiteBox({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Semantics(
      button: true,
      child: ApplePressable(
        onTap: onTap,
        pressedScale: 0.98,
        haptic: false,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
          decoration: BoxDecoration(
            color: c.secondaryGroupedBackground,
            borderRadius: BorderRadius.circular(AppleRadii.md),
            border: Border.all(color: c.separator, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  Constants.siteDisplay,
                  textAlign: TextAlign.center,
                  style: type.title3.copyWith(color: c.accent, letterSpacing: 0.2),
                ),
              ),
              const SizedBox(width: AppleSpacing.xs),
              Icon(Icons.content_copy_rounded, size: 18, color: c.tertiaryLabel),
            ],
          ),
        ),
      ),
    );
  }
}
