import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'obs_qr.dart';
import 'qr_scan_page.dart';
import 'settings_kit.dart';

/// Configuração do plugin do OBS: conecta no obs-websocket (embutido no OBS 28+).
class ObsSettingsPage extends StatefulWidget {
  const ObsSettingsPage({super.key});

  @override
  State<ObsSettingsPage> createState() => _ObsSettingsPageState();
}

class _ObsSettingsPageState extends State<ObsSettingsPage> {
  final _hostCtrl = TextEditingController(text: 'localhost');
  final _portCtrl = TextEditingController(text: '4455');
  final _passCtrl = TextEditingController();
  bool _busy = false;
  bool _prefilled = false;

  @override
  void initState() {
    super.initState();
    Injector.get<DeckOSClient>()
        .getObsState()
        .then((s) {
          if (s != null && mounted) {
            final map = Map<String, dynamic>.from(s);
            Injector.get<SignalRService>().obsState.value = map;
            _applyPrefill(map);
          }
        })
        .catchError((_) {});
  }

  void _applyPrefill(Map<String, dynamic> state) {
    if (_prefilled) return;
    _prefilled = true;
    final host = state['host'];
    if (host is String && host.trim().isNotEmpty) {
      _hostCtrl.text = host.trim();
    }
    final port = state['port'];
    if (port is num && port.toInt() > 0) {
      _portCtrl.text = '${port.toInt()}';
    } else if (port is String && port.trim().isNotEmpty) {
      _portCtrl.text = port.trim();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  /// Aviso no topo do formulário: resultado de salvar/conectar.
  (BannerTone, String)? _notice;

  void _show(BannerTone tone, String m) {
    if (mounted) setState(() => _notice = (tone, m));
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final port = int.tryParse(_portCtrl.text.trim()) ?? 4455;
      final host = _hostCtrl.text.trim().isEmpty
          ? 'localhost'
          : _hostCtrl.text.trim();
      await Injector.get<DeckOSClient>().setObsConfig(
        host,
        port,
        _passCtrl.text.isEmpty ? null : _passCtrl.text,
      );
      final latest = await Injector.get<DeckOSClient>().getObsState();
      if (latest != null && mounted) {
        Injector.get<SignalRService>().obsState.value =
            Map<String, dynamic>.from(latest);
      }
      _show(BannerTone.success, tr('Config salva. Agora toque em "Conectar".'));
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
      final st = await Injector.get<DeckOSClient>().connectObs();
      Injector.get<SignalRService>().obsState.value = Map<String, dynamic>.from(
        st,
      );
      _show(BannerTone.success, tr('OBS conectado!'));
    } catch (e) {
      _show(BannerTone.error, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      final res = await Injector.get<DeckOSClient>().postJson('/api/obs/disconnect');
      if (res is Map && mounted) {
        Injector.get<SignalRService>().obsState.value =
            Map<String, dynamic>.from(res);
      }
      _show(BannerTone.info, tr('OBS desconectado.'));
    } catch (e) {
      _show(BannerTone.error, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget() async {
    setState(() => _busy = true);
    try {
      final res = await Injector.get<DeckOSClient>().deleteJson('/api/obs/config');
      if (res is Map && mounted) {
        Injector.get<SignalRService>().obsState.value =
            Map<String, dynamic>.from(res);
      }
      if (mounted) {
        _hostCtrl.text = 'localhost';
        _portCtrl.text = '4455';
        _passCtrl.clear();
      }
      _show(BannerTone.info, tr('Configuração removida.'));
    } catch (e) {
      _show(BannerTone.error, friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Lê o QR "Mostrar Informações de Conexão" do OBS e já configura + conecta.
  Future<void> _scanObsQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const QrScanPage(
          acceptPrefixes: ['obsws://', 'obswss://', 'obswebsocket|'],
          title: 'OBS — aponte para o QR',
          hint:
              'No OBS: Ferramentas → Config. do Servidor WebSocket → Mostrar Informações de Conexão',
        ),
      ),
    );
    if (raw == null || !mounted) return;
    final parsed = parseObsQr(raw);
    if (parsed == null) {
      _show(BannerTone.warning, tr('QR do OBS não reconhecido.'));
      return;
    }
    setState(() {
      _hostCtrl.text = parsed.host;
      _portCtrl.text = '${parsed.port}';
      _passCtrl.text = parsed.password ?? '';
      _busy = true;
    });
    // O OBS roda na mesma máquina do backend → host fica localhost; do QR
    // aproveitamos porta e senha. Salva e conecta de uma vez.
    try {
      await Injector.get<DeckOSClient>().setObsConfig(
        parsed.host,
        parsed.port,
        parsed.password,
      );
      final st = await Injector.get<DeckOSClient>().connectObs();
      Injector.get<SignalRService>().obsState.value = Map<String, dynamic>.from(
        st,
      );
      _show(BannerTone.success, tr('OBS conectado pelo QR!'));
    } catch (e) {
      _show(BannerTone.error, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final c = AppleColors.of(context);
      final st = Injector.get<SignalRService>().obsState.value;
      final connected = st['connected'] == true;
      final configured = st['configured'] == true;
      final hasPassword = st['hasPassword'] == true;
      final scene = st['currentScene'];
      final rec = st['recording'] == true;
      final live = st['streaming'] == true;
      return SettingsScaffold(
        title: 'OBS',
        largeTitle: false,
        maxWidth: 600,
        children: [
          IntegrationHero(
            brand: IntegrationBrand.of('obs'),
            title: 'OBS Studio',
            state: connected
                ? LinkState.connected
                : configured
                    ? LinkState.configured
                    : LinkState.off,
            status: connected
                ? tr('Conectado')
                : configured
                    ? tr('Desconectado')
                    : tr('Não configurado'),
            detail: connected
                ? [
                    if (scene != null && '$scene'.isNotEmpty)
                      tr('cena "{scene}"', {'scene': scene}),
                    if (rec) tr('GRAVANDO'),
                    if (live) tr('AO VIVO'),
                  ].join(' · ')
                : tr(
                    'Desconectado. Abra o OBS, ative o obs-websocket e toque em Conectar.',
                  ),
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
          if (!kIsWeb)
            InsetGroupedSection(
              footer: tr(
                'Jeito mais fácil: no OBS, "Mostrar Informações de Conexão" e aponte a câmera.',
              ),
              children: [
                ListRow(
                  leading: ListRowIcon(
                    Icons.qr_code_scanner_rounded,
                    color: c.blue,
                  ),
                  title: tr('Ler QR do OBS'),
                  onTap: _busy ? null : _scanObsQr,
                ),
              ],
            ),
          SetupStepsSection(
            title: tr('Como ativar o obs-websocket'),
            initiallyExpanded: !connected && !configured,
            footer: tr('Sem senha? Deixe o campo vazio.'),
            steps: [
              tr(
                'No OBS (28+): menu Ferramentas → Configurações do Servidor WebSocket.',
              ),
              tr(
                'Marque "Ativar Servidor WebSocket". Anote a Porta (padrão 4455).',
              ),
              tr(
                'Se "Ativar Autenticação" estiver ligado, clique em "Mostrar Informações de Conexão" e copie a Senha.',
              ),
            ],
          ),
          InsetGroupedSection(
            header: kIsWeb ? tr('Conexão') : tr('ou manualmente'),
            children: [
              FormTextRow(
                label: 'Host',
                controller: _hostCtrl,
                hint: 'localhost',
              ),
              FormTextRow(
                label: tr('Porta'),
                controller: _portCtrl,
                hint: '4455',
                keyboardType: TextInputType.number,
              ),
              FormTextRow(
                label: tr('Senha'),
                controller: _passCtrl,
                secure: true,
                hint: hasPassword
                    ? tr('Guardado no PC (deixe vazio para manter)')
                    : null,
              ),
            ],
          ),
          FormActions(
            footer: tr(
              'O OBS precisa estar aberto. A conexão é local (ws://host:porta).',
            ),
            children: [
              PrimaryButton(
                label: connected ? tr('Conectar de novo') : tr('Conectar'),
                icon: Icons.link_rounded,
                loading: _busy,
                onPressed: _busy ? null : _connect,
                expand: true,
              ),
              SecondaryButton(
                label: tr('Salvar'),
                onPressed: _busy ? null : _save,
                expand: true,
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
