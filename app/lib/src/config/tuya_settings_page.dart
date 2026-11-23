import 'dart:async';
import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/material.dart';

import 'settings_kit.dart';

/// Configuração do plugin Tuya / Smart Life — cobre também as marcas que são rebrand
/// da Tuya (Nova Digital, Positivo, RSmart, Elgin, Geonav...).
///
/// O pareamento é por QR e não exige conta de desenvolvedor: o usuário informa o
/// "Código de usuário" do app e escaneia. A ressalva importante está no aviso da tela —
/// só os apps **Smart Life** e **Tuya Smart** aceitam o scan; apps de marca recusam.
class TuyaSettingsPage extends StatefulWidget {
  const TuyaSettingsPage({super.key});

  @override
  State<TuyaSettingsPage> createState() => _TuyaSettingsPageState();
}

class _TuyaSettingsPageState extends State<TuyaSettingsPage> {
  final _userCodeCtrl = TextEditingController();

  bool _busy = false;
  String? _qrBase64;
  int _secondsLeft = 0;
  Timer? _pollTimer;

  /// Aviso no topo da tela: resultado de gerar o QR, vincular, atualizar.
  (BannerTone, String)? _notice;

  @override
  void initState() {
    super.initState();
    Injector.get<DeckOSClient>()
        .getTuyaState()
        .then((s) {
          if (s != null && mounted) {
            Injector.get<SignalRService>().tuyaState.value =
                Map<String, dynamic>.from(s);
            setState(
              () => _userCodeCtrl.text = (s['userCode'] ?? '') as String,
            );
          }
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _userCodeCtrl.dispose();
    super.dispose();
  }

  void _show(BannerTone tone, String m) {
    if (mounted) setState(() => _notice = (tone, m));
  }

  Future<void> _startPairing() async {
    final code = _userCodeCtrl.text.trim();
    if (code.isEmpty) {
      _show(BannerTone.warning, tr('Informe o código de usuário primeiro.'));
      return;
    }

    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final r = await Injector.get<DeckOSClient>().startTuyaPairing(code);
      setState(() {
        _qrBase64 = r['qrPng'] as String?;
        _secondsLeft = (r['expiresInSeconds'] as num?)?.toInt() ?? 120;
      });
      _startPolling();
    } catch (e) {
      _show(BannerTone.error, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Consulta a cada 3s se o usuário já escaneou, e conta o tempo restante do QR.
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() => _secondsLeft = (_secondsLeft - 3).clamp(0, 999));

      try {
        final scanned = await Injector.get<DeckOSClient>().pollTuyaPairing();
        if (!scanned) return;

        timer.cancel();
        final state = await Injector.get<DeckOSClient>().getTuyaState();
        if (state != null && mounted) {
          Injector.get<SignalRService>().tuyaState.value =
              Map<String, dynamic>.from(state);
        }
        if (mounted) setState(() => _qrBase64 = null);
        _show(BannerTone.success, tr('Conta vinculada!'));
      } catch (e) {
        // 410 = QR expirado: para o laço e deixa o usuário gerar outro.
        timer.cancel();
        if (mounted) setState(() => _qrBase64 = null);
        _show(BannerTone.error, e.toString().replaceFirst('Exception: ', ''));
      }
    });
  }

  Future<void> _refreshDevices() async {
    setState(() => _busy = true);
    try {
      final state = await Injector.get<DeckOSClient>().refreshTuyaDevices();
      Injector.get<SignalRService>().tuyaState.value =
          Map<String, dynamic>.from(state);
      _show(BannerTone.success, tr('Dispositivos atualizados.'));
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
          await Injector.get<DeckOSClient>().postJson('/api/tuya/disconnect');
      if (res is Map && mounted) {
        Injector.get<SignalRService>().tuyaState.value =
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
          await Injector.get<DeckOSClient>().deleteJson('/api/tuya/config');
      if (res is Map && mounted) {
        Injector.get<SignalRService>().tuyaState.value =
            Map<String, dynamic>.from(res);
      }
      if (mounted) {
        _userCodeCtrl.clear();
        setState(() => _qrBase64 = null);
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
    final c = AppleColors.of(context);
    final state = Injector.get<SignalRService>().tuyaState.watch(context);
    final paired = state['paired'] == true;
    final pushOn = state['push'] == true;
    final devices = (state['devices'] as List? ?? const []);
    const gutter = EdgeInsets.fromLTRB(
      AppleSpacing.screen,
      0,
      AppleSpacing.screen,
      AppleSpacing.xl,
    );

    return SettingsScaffold(
      title: 'Tuya / Smart Life',
      largeTitle: false,
      maxWidth: 600,
      children: [
        IntegrationHero(
          brand: IntegrationBrand.of('tuya'),
          title: 'Tuya / Smart Life',
          state: paired ? LinkState.connected : LinkState.off,
          status: paired ? tr('Conta vinculada') : tr('Não vinculado'),
          detail: paired
              ? tr('{count} dispositivo(s) · estado ao vivo {state}', {
                  'count': devices.length,
                  'state': pushOn ? tr('ativo') : tr('reconectando...'),
                })
              : tr(
                  'Vincule sua conta Smart Life para usar botões de casa inteligente.',
                ),
        ),
        if (_notice != null)
          AppleBanner(
            tone: _notice!.$1,
            message: _notice!.$2,
            onDismiss: () => setState(() => _notice = null),
            margin: gutter,
          ),
        if (!paired || _qrBase64 != null) ...[
          SetupStepsSection(
            title: tr('Onde achar o código de usuário'),
            steps: [
              tr('Aba "Eu" (canto inferior direito)'),
              tr('Ícone de engrenagem (canto superior direito)'),
              tr('"Conta e segurança"'),
              tr('Role até o fim: "Código de usuário"'),
            ],
            footer: tr('No app Smart Life (ou Tuya Smart).'),
          ),
          InsetGroupedSection(
            header: tr('Vincular conta'),
            children: [
              FormTextRow(
                label: tr('Código de usuário'),
                controller: _userCodeCtrl,
                hint: tr('ex.: BxYZNPJ'),
              ),
            ],
          ),
          FormActions(
            children: [
              PrimaryButton(
                label: _qrBase64 == null
                    ? tr('Gerar QR')
                    : tr('Gerar outro QR'),
                icon: Icons.qr_code_2_rounded,
                loading: _busy && _qrBase64 == null,
                onPressed: _busy ? null : _startPairing,
                expand: true,
              ),
            ],
          ),
        ],
        if (_qrBase64 != null) _qrSection(c),
        if (paired) ...[
          _devicesSection(c, devices),
          FormActions(
            children: [
              SecondaryButton(
                label: tr('Desconectar'),
                color: c.orange,
                onPressed: _busy ? null : _disconnect,
                expand: true,
              ),
              SecondaryButton(
                label: tr('Esquecer'),
                color: c.red,
                onPressed: _busy ? null : _forget,
                expand: true,
              ),
            ],
          ),
        ],
        AppleBanner(
          tone: BannerTone.warning,
          title: tr('Usa app de marca?'),
          message: tr(
            'O scan só funciona nos apps Smart Life e Tuya Smart. Apps de marca '
            '(Nova Digital, Positivo, RSmart...) recusam com "please use the '
            'designated app to scan the code".\n\n'
            'Solução: remova o aparelho do app da marca e pareie de novo pelo '
            'Smart Life — é o mesmo hardware, funciona igual. Compartilhar o '
            'dispositivo não resolve.',
          ),
          margin: gutter,
        ),
      ],
    );
  }

  Widget _qrSection(AppleColors c) {
    final type = AppleTextStyles.of(context);
    return InsetGroupedSection(
      header: tr('Escaneie com o app Smart Life'),
      footer: tr('Aba "Home" → ícone de scan no topo direito.'),
      children: [
        Padding(
          padding: const EdgeInsets.all(AppleSpacing.lg),
          child: Column(
            children: [
              // O PNG vem pronto do backend (QRCoder): o app não tem lib de gerar QR.
              ClipRSuperellipse(
                borderRadius: BorderRadius.circular(AppleRadii.md),
                child: ColoredBox(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(AppleSpacing.xs),
                    child: Image.memory(
                      base64Decode(_qrBase64!),
                      width: 224,
                      height: 224,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppleSpacing.sm),
              Text(
                _secondsLeft > 0
                    ? tr('Expira em {seconds}s', {'seconds': _secondsLeft})
                    : tr('Expirado — gere outro'),
                style: type.footnote.copyWith(
                  color: _secondsLeft > 20 ? c.secondaryLabel : c.orange,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _devicesSection(AppleColors c, List<dynamic> devices) {
    return InsetGroupedSection(
      header: tr('Dispositivos'),
      footer: tr(
        'Atualizar consome cota da API da Tuya — use só ao adicionar aparelhos.',
      ),
      children: [
        for (final d in devices)
          Builder(
            builder: (context) {
              final device = d as Map;
              final online = device['online'] == true;
              return ListRow(
                leading: ListRowIcon(
                  Icons.lightbulb_rounded,
                  color: online ? c.yellow : c.gray,
                ),
                title: '${device['name']}',
                subtitle: '${device['productName'] ?? device['category']}',
                value: online ? 'online' : 'offline',
              );
            },
          ),
        if (devices.isEmpty)
          ListRow(
            title: tr(
              'Nenhum dispositivo. Se acabou de adicionar um no app, toque em atualizar.',
            ),
          ),
        ListRow(
          leading: ListRowIcon(Icons.refresh_rounded, color: c.blue),
          title: tr('Buscar novos dispositivos na conta'),
          enabled: !_busy,
          onTap: _busy ? null : _refreshDevices,
          trailing: _busy
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.secondaryLabel,
                  ),
                )
              : null,
        ),
      ],
    );
  }
}
