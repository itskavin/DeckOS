import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

import 'pc_info.dart';
import 'settings_kit.dart';

/// Configuração da soundboard (MyInstants): escolhe o dispositivo de saída "cabo"
/// (que vai pro Discord/OBS via VB-Cable/Voicemeeter) e um "monitor" opcional (pra você
/// ouvir), além do volume. O backend toca os sons nesses dispositivos.
class SoundboardSettingsPage extends StatefulWidget {
  const SoundboardSettingsPage({super.key});

  @override
  State<SoundboardSettingsPage> createState() => _SoundboardSettingsPageState();
}

class _SoundboardSettingsPageState extends State<SoundboardSettingsPage> {
  bool _loading = true;
  bool _busy = false;
  List<Map<String, String>> _devices = [];
  String? _cableDeviceId;
  String? _monitorDeviceId;
  bool _monitorEnabled = false;
  double _volume = 100;

  /// Aviso no topo da tela: resultado de salvar.
  (BannerTone, String)? _notice;

  @override
  void initState() {
    super.initState();
    _load();
    if (PcInfo.current.value == null) PcInfo.load();
  }

  Future<void> _load() async {
    final client = Injector.get<DeckOSClient>();
    try {
      final devices = await client.getSoundDevices();
      final cfg = await client.getSoundboardConfig();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        if (cfg != null) {
          _cableDeviceId = (cfg['cableDeviceId'] as String?)?.isEmpty ?? true
              ? null
              : cfg['cableDeviceId'] as String?;
          _monitorDeviceId =
              (cfg['monitorDeviceId'] as String?)?.isEmpty ?? true
              ? null
              : cfg['monitorDeviceId'] as String?;
          _monitorEnabled = cfg['monitorEnabled'] == true;
          _volume = ((cfg['volume'] as num?)?.toDouble() ?? 100).clamp(0, 100);
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _show(BannerTone tone, String m) {
    if (mounted) setState(() => _notice = (tone, m));
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await Injector.get<DeckOSClient>().saveSoundboardConfig(
        cableDeviceId: _cableDeviceId,
        monitorDeviceId: _monitorDeviceId,
        monitorEnabled: _monitorEnabled,
        volume: _volume.round(),
      );
      _show(BannerTone.success, tr('Configuração da soundboard salva.'));
    } catch (_) {
      _show(
        BannerTone.error,
        tr('Não foi possível salvar (servidor acessível?).'),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopTest() async {
    try {
      await Injector.get<DeckOSClient>().stopSounds();
    } catch (_) {}
  }

  /// Nome do dispositivo para a linha; um id salvo que sumiu (cabo desligado) aparece cru.
  String _deviceName(String? id, {required bool allowNull}) {
    if (id == null) {
      return allowNull ? tr('Dispositivo padrão do Windows') : tr('Escolher');
    }
    final d = _devices.where((d) => d['id'] == id).firstOrNull;
    return d?['name'] ?? id;
  }

  Future<void> _pickDevice({
    required String title,
    required String? value,
    required bool allowNull,
    required ValueChanged<String?> onChanged,
  }) async {
    // A folha não devolve nulo como escolha: o "padrão" vai como este marcador.
    const none = '\u0000';
    final v = await showChoiceSheet<String>(
      context: context,
      title: title,
      selected: value ?? (allowNull ? none : null),
      choices: [
        if (allowNull) Choice(none, tr('Dispositivo padrão do Windows')),
        for (final d in _devices)
          Choice(d['id'] ?? '', d['name'] ?? d['id'] ?? ''),
      ],
    );
    if (v == null) return;
    setState(() => onChanged(v == none ? null : v));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    const gutter = EdgeInsets.fromLTRB(
      AppleSpacing.screen,
      0,
      AppleSpacing.screen,
      AppleSpacing.xl,
    );
    return Watch((context) {
      // Escolher a saída exige o áudio do Windows; nos outros sistemas toca na saída padrão.
      final devicesOk = PcInfo.current.value?.has('soundboard.devices') ?? true;
      return SettingsScaffold(
        title: 'Soundboard',
        largeTitle: false,
        maxWidth: 600,
        children: [
          IntegrationHero(
            brand: IntegrationBrand.of('soundboard'),
            title: 'Soundboard',
            state: LinkState.configured,
            status: tr('Volume: {percent}%', {'percent': _volume.round()}),
            detail: tr('Sons do MyInstants: saída e volume'),
          ),
          if (_notice != null)
            AppleBanner(
              tone: _notice!.$1,
              message: _notice!.$2,
              onDismiss: () => setState(() => _notice = null),
              margin: gutter,
            ),
          if (_loading)
            Padding(
              padding: const EdgeInsets.all(AppleSpacing.xl),
              child: Center(
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: c.secondaryLabel,
                  ),
                ),
              ),
            )
          else ...[
            if (devicesOk) ...[
              SetupStepsSection(
                title: tr('Como levar o som pro Discord / live'),
                initiallyExpanded: _cableDeviceId == null,
                footer: tr(
                  'Quer sua voz + os sons juntos no Discord? Use o Voicemeeter pra mixar mic + soundboard '
                  'numa saída virtual só. Na live/OBS mic e cabo entram como fontes separadas.',
                ),
                steps: [
                  tr('Instale o VB-Cable (grátis) e reinicie o PC.'),
                  tr(
                    'Aqui, escolha a saída "cabo" = "CABLE Input (VB-Audio Virtual Cable)".',
                  ),
                  tr(
                    'No Discord: Configurações de Voz → Dispositivo de entrada = "CABLE Output".',
                  ),
                  tr(
                    'No OBS: adicione uma "Captura de Entrada de Áudio" do "CABLE Output".',
                  ),
                ],
              ),
              InsetGroupedSection(
                header: tr('Saída'),
                footer: tr(
                  'Ex.: "CABLE Input" (VB-Cable). Vazio = dispositivo padrão do Windows.',
                ),
                children: [
                  ListRow(
                    leading: ListRowIcon(
                      Icons.alt_route_rounded,
                      color: c.orange,
                    ),
                    title: tr('Saída "cabo" (vai pro Discord/OBS)'),
                    subtitle: _deviceName(_cableDeviceId, allowNull: true),
                    chevron: true,
                    onTap: () => _pickDevice(
                      title: tr('Saída "cabo" (vai pro Discord/OBS)'),
                      value: _cableDeviceId,
                      allowNull: true,
                      onChanged: (v) => _cableDeviceId = v,
                    ),
                  ),
                  ListRow(
                    leading: ListRowIcon(
                      Icons.headphones_rounded,
                      color: c.blue,
                    ),
                    title: tr('Tocar também no monitor'),
                    subtitle: tr('Pra você ouvir o som (fone/alto-falante)'),
                    trailing: AppleSwitch(
                      value: _monitorEnabled,
                      onChanged: (v) => setState(() => _monitorEnabled = v),
                    ),
                  ),
                  if (_monitorEnabled)
                    ListRow(
                      leading: ListRowIcon(Icons.hearing_rounded, color: c.teal),
                      title: tr('Saída "monitor"'),
                      subtitle: _deviceName(_monitorDeviceId, allowNull: false),
                      chevron: true,
                      onTap: () => _pickDevice(
                        title: tr('Saída "monitor"'),
                        value: _monitorDeviceId,
                        allowNull: false,
                        onChanged: (v) => _monitorDeviceId = v,
                      ),
                    ),
                ],
              ),
            ] else
              AppleBanner(
                tone: BannerTone.info,
                message: tr(
                  'Neste PC os sons tocam na saída de áudio padrão do sistema.',
                ),
                margin: gutter,
              ),
            InsetGroupedSection(
              header: tr('Volume'),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppleSpacing.md,
                    vertical: AppleSpacing.xxs,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.volume_down_rounded,
                        size: 18,
                        color: c.secondaryLabel,
                      ),
                      Expanded(
                        child: Slider(
                          value: _volume,
                          min: 0,
                          max: 100,
                          divisions: 100,
                          label: '${_volume.round()}%',
                          onChanged: (v) => setState(() => _volume = v),
                        ),
                      ),
                      Icon(
                        Icons.volume_up_rounded,
                        size: 18,
                        color: c.secondaryLabel,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            FormActions(
              children: [
                PrimaryButton(
                  label: tr('Salvar'),
                  loading: _busy,
                  onPressed: _busy ? null : _save,
                  expand: true,
                ),
                SecondaryButton(
                  label: tr('Parar tudo'),
                  icon: Icons.stop_rounded,
                  onPressed: _busy ? null : _stopTest,
                  expand: true,
                ),
              ],
            ),
          ],
        ],
      );
    });
  }
}
