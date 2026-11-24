import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:deckos/src/connection/constants.dart';
import 'package:deckos/src/connection/usb_route.dart';
import 'package:deckos/src/services/server_discovery_service.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/backup/backup_buttons.dart';
import 'package:deckos/src/ai_limits/ai_limits_models.dart';
import 'package:deckos/src/ai_limits/ai_limits_settings_page.dart';
import 'package:deckos/src/ai_limits/ai_limits_store.dart';
import 'package:deckos/src/config/integrations_page.dart';
import 'package:deckos/src/config/triggers_page.dart';
import 'package:deckos/src/config/pc_switcher.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'appearance_settings_page.dart';
import 'keep_awake.dart';
import 'pc_info.dart';
import 'qr_scan_page.dart';
import 'settings_kit.dart';
import 'privacy_notice_page.dart';
import 'paired_devices_page.dart';
import '../welcome/welcome_page.dart';
import '../welcome/pairing.dart';

const _repoUrl = 'https://github.com/itskavin/DeckOS';

/// Ajustes do app, no jeito do Ajustes do iPhone: o PC conectado no topo e os grupos
/// (Deck, Aparência, Integrações, Automações, Conexão, Sobre), com busca.
class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});

  @override
  ConfigPageState createState() => ConfigPageState();
}

class ConfigPageState extends State<ConfigPage> {
  final _ipController = TextEditingController();
  final _keyController = TextEditingController();
  String _query = '';
  List<SavedPc> _pcs = [];
  int? _connectedIntegrations;
  int? _activeTriggers;

  ThemeController get _theme => ThemeController.instance;

  @override
  void initState() {
    super.initState();
    _loadIP();
    KeepAwake.load();
    PcInfo.load();
    _loadCounts();
  }

  Future<void> _loadIP() async {
    final prefs = await SharedPreferences.getInstance();
    List<SavedPc> pcs;
    try { pcs = await PcStore.load(); }
    catch (_) { if (mounted) _snack(tr('Secure storage is unavailable. Unlock your phone and restart DeckOS. Your saved data has been kept.')); return; }
    // PC migrado da versão antiga ainda sem nome: pergunta ao PC em uso.
    final current = pcs.where((p) => p.id == PcStore.currentId).firstOrNull;
    if (current != null &&
        (current.name == 'PC' || current.name == current.ip)) {
      await fetchPcName(current);
      pcs = await PcStore.load();
    }
    if (!mounted) return;
    setState(() {
      _pcs = pcs;
      _ipController.text = prefs.getString(Constants.ipAddrKey) ?? '';
      _keyController.text = ''; // Credentials are never displayed or stored in plain preferences.
    });
  }

  /// Contagens à direita de Integrações e Automações. PC fora ou antigo: sem número.
  Future<void> _loadCounts() async {
    final client = Injector.get<DeckOSClient>();
    try {
      final list = await client.getJson('/api/integrations') as List;
      final n = list
          .where(
            (i) => (i as Map)['connected'] == true && i['name'] != 'soundboard',
          )
          .length;
      if (mounted) setState(() => _connectedIntegrations = n);
    } catch (_) {}
    try {
      final list = await client.getJson('/api/triggers') as List;
      final n = list.where((t) => (t as Map)['enabled'] != false).length;
      if (mounted) setState(() => _activeTriggers = n);
    } catch (_) {}
    AiLimitsStore.instance.ensureInitialized();
  }

  String? _aiLimitsSummary(AiLimitsSnapshot? snap) {
    if (snap == null) return null;
    if (snap.sources.isEmpty) return tr('Não configurado');
    final enabled = snap.enabledAccounts.length;
    if (snap.attentionSourceCount > 0 && enabled == 0) {
      return tr('Atenção');
    }
    if (enabled == 1) return tr('1 conta');
    if (enabled > 1) return tr('{n} contas', {'n': '$enabled'});
    final s = snap.sources.length;
    return s == 1 ? tr('1 fonte') : tr('{n} fontes', {'n': '$s'});
  }

  SavedPc? get _currentPc =>
      _pcs.where((p) => p.id == PcStore.currentId).firstOrNull;

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) _loadCounts();
  }

  // ---- PCs ----

  Future<void> _renamePc(SavedPc pc) async {
    final ctrl = TextEditingController(text: pc.name);
    final name = await showAppleDialog<String>(
      context: context,
      title: tr('Nome do PC'),
      content: Padding(
        padding: const EdgeInsets.only(top: AppleSpacing.sm),
        child: TextField(
          controller: ctrl,
          autofocus: true,
          style: AppleTextStyles.of(
            context,
          ).body.copyWith(color: AppleColors.of(context).label),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: AppleColors.of(context).tertiaryFill,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
      ),
      actions: [
        AppleDialogAction(label: tr('Cancelar')),
        AppleDialogAction(
          label: tr('Salvar'),
          isDefault: true,
          value: '\u0000',
        ),
      ],
    );
    final value = name == '\u0000' ? ctrl.text.trim() : name;
    ctrl.dispose();
    if (value == null || value.isEmpty) return;
    await PcStore.rename(pc.id, value);
    _loadIP();
  }

  Future<void> _removePc(SavedPc pc) async {
    final ok = await showAppleDialog<bool>(
      context: context,
      title: tr('Esquecer "{name}"?', {'name': pc.name}),
      message: tr('Para usar este PC de novo, pareie com o QR dele.'),
      actions: [
        AppleDialogAction(label: tr('Cancelar'), value: false),
        AppleDialogAction(
          label: tr('Esquecer'),
          value: true,
          isDestructive: true,
        ),
      ],
    );
    if (ok != true) return;
    final wasCurrent = pc.id == PcStore.currentId;
    await PcStore.remove(pc.id);
    if (wasCurrent) {
      await Injector.get<SignalRService>().dispose();
      Injector.get<DeckOSClient>().setApiKey(null);
    }
    final next = await PcStore.current();
    if (!mounted) return;
    if (wasCurrent && next != null) {
      await switchToPc(context, next);
    } else {
      _loadIP();
    }
  }

  /// Folha com os PCs pareados: tocar troca de PC; o (i) renomeia ou esquece.
  Future<void> _showPcSheet() async {
    final action = await showSettingsSheet<void Function()>(
      context: context,
      title: tr('PCs pareados'),
      builder: (sheet) {
        final c = AppleColors.of(sheet);
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(top: AppleSpacing.xs),
          children: [
            if (_pcs.isNotEmpty)
              InsetGroupedSection(
                footer: tr(
                  'Para acrescentar outro PC, pareie com o QR dele (ou digite o IP abaixo).',
                ),
                children: [
                  for (final pc in _pcs)
                    ListRow(
                      leading: ListRowIcon(
                        Icons.computer_rounded,
                        color: pc.id == PcStore.currentId ? c.accent : c.gray,
                      ),
                      title: pc.name,
                      subtitle: pc.needsRepair ? tr('Re-pair securely') : pc.baseUrl,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (pc.id == PcStore.currentId)
                            Icon(
                              Icons.check_rounded,
                              size: 20,
                              color: c.accent,
                            ),
                          IconButton(
                            tooltip: tr('Opções'),
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.more_horiz_rounded,
                              color: c.secondaryLabel,
                              size: 22,
                            ),
                            onPressed: () =>
                                Navigator.of(sheet).pop(() => _pcOptions(pc)),
                          ),
                        ],
                      ),
                      onTap: pc.id == PcStore.currentId
                          ? null
                          : () => Navigator.of(
                              sheet,
                            ).pop(() => switchToPc(context, pc)),
                    ),
                ],
              ),
            InsetGroupedSection(
              children: [
                ListRow(
                  leading: ListRowIcon(
                    Icons.qr_code_scanner_rounded,
                    color: c.blue,
                  ),
                  title: tr('Parear (QR)'),
                  onTap: () => Navigator.of(sheet).pop(_pairWithQr),
                ),
                ListRow(
                  leading: ListRowIcon(Icons.keyboard_rounded, color: c.teal),
                  title: tr('Digitar o IP do PC'),
                  onTap: () => Navigator.of(sheet).pop(_showManualSheet),
                ),
              ],
            ),
          ],
        );
      },
    );
    action?.call();
  }

  Future<void> _pcOptions(SavedPc pc) async {
    final choice = await showSettingsSheet<String>(
      context: context,
      title: pc.name,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: AppleSpacing.xs),
        children: [
          InsetGroupedSection(
            children: [
              ListRow(
                title: tr('Renomear'),
                onTap: () => Navigator.of(sheet).pop('rename'),
              ),
              ListRow(
                title: tr('Esquecer este PC'),
                destructive: true,
                onTap: () => Navigator.of(sheet).pop('remove'),
              ),
            ],
          ),
        ],
      ),
    );
    if (choice == 'rename') _renamePc(pc);
    if (choice == 'remove') _removePc(pc);
  }

  /// Procura o PC na rede. Devolve o IP achado, ou nulo.
  Future<String?> _discover() async {
    final result = await ServerDiscoveryService().findServers(
      '255.255.255.255',
      5,
    );
    return result == 'Not Found' ? null : result;
  }

  Future<void> _showManualSheet() async {
    final ip = await showSettingsSheet<String>(
      context: context,
      title: tr('Digitar o IP do PC'),
      builder: (_) => _ManualPcSheet(
        controller: _ipController,
        keyController: _keyController,
        discover: _discover,
      ),
    );
    if (ip != null && mounted) await _saveAndGoBack();
  }

  Future<void> _saveAndGoBack() async {
    final ok = await connectToAddress(_ipController.text.trim());
    if (!mounted) return;
    if (!ok) { _snack(pairingFailure); return; }
    Navigator.of(context).pushReplacementNamed('/home');
  }

  Future<void> _pairWithQr() async {
    final result = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (result == null || !mounted) return;
    final ok = await pairWithQr(result);
    if (!mounted) return;
    if (!ok) { _snack(pairingFailure); return; }
    _snack(tr('Pareado com sucesso!'));
    Navigator.of(context).pushReplacementNamed('/home');
  }

  /// Deck no navegador: esquece a chave e volta ao pareamento.
  Future<void> _forgetBrowser() async {
    final ok = await showAppleDialog<bool>(
      context: context,
      title: tr('Esquecer este PC?'),
      message: tr('Este navegador está pareado com o PC.'),
      actions: [
        AppleDialogAction(label: tr('Cancelar'), value: false),
        AppleDialogAction(
          label: tr('Esquecer'),
          value: true,
          isDestructive: true,
        ),
      ],
    );
    if (ok != true) return;
    await (await SharedPreferences.getInstance()).remove(Constants.apiKeyKey);
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false);
  }

  Future<void> _usbInfo() async {
    final pc = _currentPc;
    final retry = await showAppleDialog<bool>(
      context: context,
      title: tr('Conexão USB'),
      message: tr(
        'Com a Conexão USB ligada no PC e a depuração USB no celular, o app usa o cabo '
        'sozinho: funciona sem Wi-Fi e tem menos atraso.',
      ),
      actions: [
        AppleDialogAction(label: tr('OK'), value: false),
        if (pc != null)
          AppleDialogAction(
            label: tr('Verificar de novo'),
            value: true,
            isDefault: true,
          ),
      ],
    );
    if (retry == true && pc != null && mounted) await switchToPc(context, pc);
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      _snack(tr('Não foi possível abrir o link.'));
    }
  }

  // ---- Linhas ----

  static String _fold(String s) {
    const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
    const to = 'aaaaaeeeeiiiiooooouuuucn';
    final lower = s.toLowerCase();
    final b = StringBuffer();
    for (final ch in lower.split('')) {
      final i = from.indexOf(ch);
      b.write(i < 0 ? ch : to[i]);
    }
    return b.toString();
  }

  _Item _row({
    required String title,
    required IconData icon,
    required Color color,
    String? subtitle,
    String? value,
    Widget? trailing,
    VoidCallback? onTap,
    String keywords = '',
  }) => _Item(
    _fold('$title ${subtitle ?? ''} $keywords'),
    ListRow(
      leading: ListRowIcon(icon, color: color),
      title: title,
      subtitle: subtitle,
      value: value,
      trailing: trailing,
      onTap: onTap,
      chevron: onTap != null && trailing == null ? true : null,
    ),
  );

  List<_Section> _sections(BuildContext context) {
    final c = AppleColors.of(context);
    final info = PcInfo.current.value;
    final s = _theme.settings.value;
    final lang = AppLanguage.choice.value;
    final langName =
        AppLanguage.available.where((l) => l.code == lang).firstOrNull?.name ??
        tr('Padrão (inglês)');
    final client = Injector.get<DeckOSClient>();

    return [
      _Section(
        tr('Deck'),
        tr(
          'Só o deck esconde o controle de áudio e abre o deck em tela cheia.',
        ),
        [
          _row(
            title: tr('Só o deck'),
            icon: Icons.fullscreen_rounded,
            color: c.blue,
            keywords: 'layout tela cheia audio',
            trailing: AppleSwitch(
              value: _theme.deckOnly.value,
              onChanged: _theme.setDeckOnly,
            ),
          ),
          if (info?.has('foreground.autoProfile') ?? true)
            _row(
              title: tr('Seguir o app em foco'),
              icon: Icons.auto_awesome_rounded,
              color: c.purple,
              keywords: 'perfil automatico',
              trailing: AppleSwitch(
                value: _theme.autoProfile.value,
                onChanged: _theme.setAutoProfile,
              ),
            ),
          _row(
            title: tr('Vibrar ao tocar'),
            icon: Icons.vibration_rounded,
            color: c.pink,
            value: _theme.haptics.value.label,
            keywords: 'vibracao haptics',
            onTap: () async {
              final h = await showChoiceSheet<Haptics>(
                context: context,
                title: tr('Vibrar ao tocar'),
                footer: tr('Também vibra forte quando um timer termina.'),
                selected: _theme.haptics.value,
                choices: [for (final h in Haptics.values) Choice(h, h.label)],
              );
              if (h != null) _theme.setHaptics(h);
            },
          ),
          _row(
            title: tr('Manter a tela ligada'),
            icon: Icons.light_mode_rounded,
            color: c.orange,
            keywords: 'apagar bloqueio wakelock',
            trailing: AppleSwitch(
              value: KeepAwake.enabled.value,
              onChanged: KeepAwake.set,
            ),
          ),
        ],
      ),
      _Section(tr('Aparência'), null, [
        _row(
          title: tr('Aparência'),
          icon: Icons.palette_rounded,
          color: c.indigo,
          value: s.preset.name,
          keywords: 'tema cores escuro claro estilo botoes destaque',
          onTap: () => _push(const AppearanceSettingsPage()),
        ),
        _row(
          title: tr('Idioma'),
          icon: Icons.language_rounded,
          color: c.blue,
          value: langName,
          keywords: 'language idioma',
          onTap: () async {
            final v = await showChoiceSheet<String>(
              context: context,
              title: tr('Idioma'),
              footer: tr('O padrão é inglês. Selecione outro idioma para alterá-lo.'),
              selected: AppLanguage.available.any((l) => l.code == lang)
                  ? lang
                  : 'auto',
              choices: [
                Choice('auto', tr('Padrão (inglês)')),
                for (final l in AppLanguage.available) Choice(l.code, l.name),
              ],
            );
            if (v != null) AppLanguage.set(v);
          },
        ),
      ]),
      _Section(tr('Integrações'), null, [
        _row(
          title: tr('Limites de IA'),
          subtitle: tr('Claude, Codex, CLIProxyAPI e assinaturas conectadas'),
          icon: Icons.speed_rounded,
          color: c.orange,
          value: _aiLimitsSummary(AiLimitsStore.instance.snapshot.value),
          keywords:
              'ai limits limites ia quota cota claude codex gemini copilot cliproxyapi usage uso',
          onTap: () => _push(const AiLimitsSettingsPage()),
        ),
        _row(
          title: tr('Integrações'),
          subtitle: info == null || info.isWindows
              ? tr(
                  'Discord, OBS, Spotify, Twitch, Home Assistant, Hue, Voicemeeter e mais',
                )
              : tr('Discord, OBS, Spotify, Twitch, Home Assistant, Hue e mais'),
          icon: Icons.hub_rounded,
          color: c.green,
          value: switch (_connectedIntegrations) {
            null || 0 => null,
            1 => tr('1 conectada'),
            final n => tr('{n} conectadas', {'n': n}),
          },
          keywords:
              'discord obs spotify twitch youtube hue mqtt tuya companion vmix tally',
          onTap: () => _push(const IntegrationsPage()),
        ),
      ]),
      _Section(tr('Automações'), null, [
        _row(
          title: tr('Automações'),
          subtitle: tr(
            'Apertar um botão sozinho num horário, quando um app abrir…',
          ),
          icon: Icons.bolt_rounded,
          color: c.yellow,
          value: switch (_activeTriggers) {
            null || 0 => null,
            1 => tr('1 ativa'),
            final n => tr('{n} ativas', {'n': n}),
          },
          keywords: 'gatilho trigger horario',
          onTap: () => _push(const TriggersPage()),
        ),
      ]),
      _Section(tr('Conexão'), null, [
        if (WebMode.onPcLoopback)
          _row(title: tr('Paired devices'), icon: Icons.verified_user_rounded,
            color: c.blue, keywords: 'pair revoke security', onTap: () => _push(const PairedDevicesPage())),
        if (kIsWeb)
          _row(
            title: tr('Esquecer'),
            subtitle: tr('Este navegador está pareado com o PC.'),
            icon: Icons.link_off_rounded,
            color: c.red,
            keywords: 'pareamento chave',
            onTap: _forgetBrowser,
          )
        else ...[
          _row(
            title: tr('PCs pareados'),
            icon: Icons.computer_rounded,
            color: c.gray,
            value: _pcs.isEmpty ? null : '${_pcs.length}',
            keywords: 'trocar renomear esquecer',
            onTap: _showPcSheet,
          ),
          _row(
            title: tr('Parear (QR)'),
            icon: Icons.qr_code_scanner_rounded,
            color: c.blue,
            keywords: 'qr camera',
            onTap: _pairWithQr,
          ),
          _row(
            title: tr('Digitar o IP do PC'),
            icon: Icons.keyboard_rounded,
            color: c.teal,
            keywords: 'ip servidor endereco pesquisar',
            onTap: _showManualSheet,
          ),
          if (UsbRoute.isSupported)
            _row(
              title: tr('Conexão USB'),
              icon: Icons.usb_rounded,
              color: c.green,
              value: UsbRoute.isUsb(client.baseUrl)
                  ? tr('Cabo USB')
                  : tr('Wi-Fi'),
              keywords: 'cabo adb',
              onTap: _usbInfo,
            ),
          _row(
            title: tr('Ainda não instalou no PC? Veja como'),
            icon: Icons.help_outline_rounded,
            color: c.gray,
            keywords: 'instalar ajuda',
            onTap: () => _push(const WelcomePage()),
          ),
        ],
      ]),
      _Section(tr('Backup'), null, [
        _row(
          title: tr('Backup do deck'),
          icon: Icons.archive_rounded,
          color: c.blue,
          keywords: 'exportar importar stream deck arquivo',
          onTap: () => _push(const _BackupPage()),
        ),
      ]),
      _Section(tr('Sobre'), null, [
        _row(
          title: tr('Privacidade e conexão local'),
          icon: Icons.privacy_tip_outlined,
          color: c.blue,
          keywords: 'privacy dados camera rede segurança',
          onTap: () => _push(const PrivacyNoticePage()),
        ),
        if (info?.version != null)
          _row(
            title: tr('DeckOS no PC'),
            icon: Icons.info_outline_rounded,
            color: c.gray,
            value: info!.version,
            keywords: 'versao',
          ),
        _row(
          title: tr('Documentação'),
          icon: Icons.menu_book_rounded,
          color: c.orange,
          keywords: 'ajuda docs',
          onTap: () => _open('$_repoUrl#readme'),
        ),
        _row(
          title: 'GitHub',
          icon: Icons.code_rounded,
          color: c.isDark ? const Color(0xFF3F3F46) : const Color(0xFF18181B),
          keywords: 'codigo fonte bug',
          onTap: () => _open(_repoUrl),
        ),
        _row(
          title: tr('Licenças'),
          icon: Icons.description_outlined,
          color: c.gray,
          keywords: 'open source',
          onTap: () =>
              showLicensePage(context: context, applicationName: 'DeckOS'),
        ),
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final q = _fold(_query.trim());
      final sections = [
        for (final s in _sections(context))
          (
            s,
            q.isEmpty
                ? s.items
                : s.items.where((i) => i.search.contains(q)).toList(),
          ),
      ].where((e) => e.$2.isNotEmpty).toList();
      return SettingsScaffold(
        title: tr('Ajustes'),
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
          if (q.isEmpty)
            _PcHeaderCard(
              pc: _currentPc,
              info: PcInfo.current.value,
              onSwitch: kIsWeb ? null : _showPcSheet,
              onPair: _pairWithQr,
              onManual: _showManualSheet,
            ),
          for (final (s, items) in sections)
            InsetGroupedSection(
              header: s.header,
              footer: q.isEmpty ? s.footer : null,
              children: [for (final i in items) i.row],
            ),
          if (sections.isEmpty)
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
    });
  }

  @override
  void dispose() {
    _ipController.dispose();
    _keyController.dispose();
    super.dispose();
  }
}

class _Item {
  const _Item(this.search, this.row);
  final String search;
  final Widget row;
}

class _Section {
  const _Section(this.header, this.footer, this.items);
  final String header;
  final String? footer;
  final List<_Item> items;
}

/// Cartão do PC conectado (como o cartão da conta no topo do Ajustes): nome, sistema, IP e
/// o estado da conexão ao vivo. Sem PC pareado, convida a parear.
class _PcHeaderCard extends StatelessWidget {
  const _PcHeaderCard({
    required this.pc,
    required this.info,
    required this.onSwitch,
    required this.onPair,
    required this.onManual,
  });

  final SavedPc? pc;
  final PcInfo? info;
  final VoidCallback? onSwitch;
  final VoidCallback onPair;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final paired = kIsWeb || pc != null;

    final Widget body;
    if (!paired) {
      body = Column(
        children: [
          BrandChip(Icons.computer_rounded, color: c.gray, size: 60),
          const SizedBox(height: AppleSpacing.sm),
          Text(
            tr('Nenhum PC conectado'),
            style: type.title3.copyWith(color: c.label),
          ),
          const SizedBox(height: AppleSpacing.xxs),
          Text(
            tr('Pareie com o QR do PC ou digite o IP.'),
            textAlign: TextAlign.center,
            style: type.subheadline.copyWith(color: c.secondaryLabel),
          ),
          const SizedBox(height: AppleSpacing.md),
          PrimaryButton(
            label: tr('Parear (QR)'),
            icon: Icons.qr_code_scanner_rounded,
            onPressed: onPair,
            expand: true,
          ),
          const SizedBox(height: AppleSpacing.xs),
          SecondaryButton(
            label: tr('Digitar o IP do PC'),
            onPressed: onManual,
            expand: true,
          ),
        ],
      );
    } else {
      final name = pc?.name ?? info?.name ?? Uri.base.host;
      final ip = pc != null ? pc!.ip : Uri.base.host;
      final os = info?.osLabel;
      body = Watch((context) {
        final status = Injector.get<SignalRService>().connectionStatus.value;
        final (color, label) = switch (status) {
          'Connected' => (c.green, tr('Conectado')),
          'Reconnecting' || 'Connecting' => (c.orange, tr('Conectando…')),
          _ => (c.red, tr('Desconectado')),
        };
        return Row(
          children: [
            BrandChip(
              Icons.computer_rounded,
              color: c.accent,
              size: 54,
            ),
            const SizedBox(width: AppleSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.title3.copyWith(color: c.label),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [if (os != null) os, ip].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.subheadline.copyWith(color: c.secondaryLabel),
                  ),
                  const SizedBox(height: AppleSpacing.xxs + 2),
                  Row(
                    children: [
                      StatusDot(color: color, glow: status == 'Connected'),
                      const SizedBox(width: AppleSpacing.xs - 2),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: type.footnote.copyWith(
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (onSwitch != null) ...[
              const SizedBox(width: AppleSpacing.xs),
              SecondaryButton(
                label: tr('Trocar de PC'),
                compact: true,
                onPressed: onSwitch,
              ),
            ],
          ],
        );
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpacing.screen,
        0,
        AppleSpacing.screen,
        AppleSpacing.xl,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.secondaryGroupedBackground,
          borderRadius: BorderRadius.circular(AppleRadii.lg),
          border: Border.all(color: c.separator, width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppleSpacing.md),
          child: body,
        ),
      ),
    );
  }
}

/// Digitar o IP do PC (e opcionalmente a chave da janela de pareamento), ou procurar na rede.
class _ManualPcSheet extends StatefulWidget {
  const _ManualPcSheet({
    required this.controller,
    required this.keyController,
    required this.discover,
  });

  final TextEditingController controller;
  final TextEditingController keyController;
  final Future<String?> Function() discover;

  @override
  State<_ManualPcSheet> createState() => _ManualPcSheetState();
}

class _ManualPcSheetState extends State<_ManualPcSheet> {
  bool _searching = false;
  (BannerTone, String)? _banner;

  Future<void> _find() async {
    setState(() {
      _searching = true;
      _banner = null;
    });
    try {
      final ip = await widget.discover();
      if (!mounted) return;
      if (ip != null) {
        widget.controller.text = ip;
        _banner = (
          BannerTone.success,
          tr('Servidor encontrado: {server}', {'server': ip}),
        );
      } else {
        _banner = (BannerTone.warning, tr('Servidor não encontrado'));
      }
    } catch (e) {
      _banner = (BannerTone.error, friendlyError(e));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _save() {
    final ip = widget.controller.text.trim();
    if (ip.isEmpty) {
      setState(
        () => _banner = (BannerTone.error, tr('Por favor insira um IP válido')),
      );
      return;
    }
    Navigator.of(context).pop(ip);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: AppleSpacing.xs),
      children: [
        InsetGroupedSection(
          footer: tr('Copy the complete secure pairing code from the PC. It expires after 3 minutes.'),
          children: [
            FormTextRow(
              label: tr('Secure pairing code'),
              controller: widget.controller,
              hint: 'deckos://pair?v=2&…',
              keyboardType: TextInputType.url,
            ),

          ],
        ),
        if (_banner != null)
          AppleBanner(
            tone: _banner!.$1,
            message: _banner!.$2,
            margin: const EdgeInsets.fromLTRB(
              AppleSpacing.screen,
              0,
              AppleSpacing.screen,
              AppleSpacing.md,
            ),
          ),
        FormActions(
          children: [
            PrimaryButton(label: tr('Salvar'), onPressed: _save, expand: true),
            SecondaryButton(
              label: tr('Pesquisar Servidor'),
              icon: Icons.search_rounded,
              loading: _searching,
              onPressed: _searching ? null : _find,
              expand: true,
            ),
          ],
        ),
      ],
    );
  }
}

/// Exportar e importar os perfis (os botões ficam no [BackupButtons]).
class _BackupPage extends StatelessWidget {
  const _BackupPage();

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: tr('Backup'),
      children: const [
        InsetGroupedSection(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: AppleSpacing.md),
              child: BackupButtons(),
            ),
          ],
        ),
      ],
    );
  }
}
