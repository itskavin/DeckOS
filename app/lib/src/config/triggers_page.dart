import 'package:deckos/core/core.dart';
import 'package:deckos/src/studio/tally_target_field.dart';
import 'package:flutter/material.dart';

import 'settings_kit.dart';

/// Automações: um acontecimento no PC (horário, app abrindo ou fechando, volta da
/// suspensão, DeckOS iniciando) aperta um botão do deck sozinho.
class TriggersPage extends StatefulWidget {
  const TriggersPage({super.key});

  @override
  State<TriggersPage> createState() => _TriggersPageState();
}

class _TriggersPageState extends State<TriggersPage> {
  final _client = Injector.get<DeckOSClient>();
  List<Map<String, dynamic>> _triggers = [];
  List<DeckProfile> _profiles = [];
  bool _loading = true;
  Object? _error;

  static Map<String, String> get events => {
    'schedule': tr('Num horário'),
    'app_start': tr('Quando um app abrir'),
    'app_exit': tr('Quando um app fechar'),
    'resume': tr('Quando o PC voltar da suspensão'),
    'startup': tr('Quando o DeckOS iniciar'),
    'tally_on': tr('Quando um alvo do tally entrar no ar'),
    'tally_off': tr('Quando um alvo do tally sair do ar'),
  };

  /// Ícone e cor de cada acontecimento (o chip do cartão).
  static (IconData, Color) eventStyle(AppleColors c, String? event) =>
      switch (event) {
        'app_start' => (Icons.apps_rounded, c.blue),
        'app_exit' => (Icons.disabled_by_default_rounded, c.gray),
        'resume' => (Icons.wb_twilight_rounded, c.indigo),
        'startup' => (Icons.rocket_launch_rounded, c.green),
        'tally_on' => (Icons.radio_button_checked_rounded, c.red),
        'tally_off' => (Icons.radio_button_unchecked_rounded, c.gray),
        _ => (Icons.schedule_rounded, c.orange),
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _client.getJson('/api/triggers') as List;
      final profiles = await _client.getProfiles();
      if (!mounted) return;
      setState(() {
        _triggers = list
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _profiles = profiles;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  Future<void> _save() async {
    try {
      final saved = await _client.putJson('/api/triggers', _triggers);
      // Mantém os IDs gerados pelo servidor para que "Testar agora" funcione na hora.
      if (saved is List && mounted) {
        setState(() {
          _triggers = saved
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        });
      }
    } catch (e) {
      if (mounted) {
        _snack(
          tr('Não deu para salvar: {reason}', {'reason': friendlyError(e)}),
        );
      }
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  String _buttonName(Map<String, dynamic> t) {
    final p = _profiles.where((p) => p.id == t['profileId']).firstOrNull;
    final b = p?.buttons.where((b) => b.id == t['buttonId']).firstOrNull;
    if (p == null || b == null) return tr('(botão apagado)');
    return '${p.name} · ${b.label?.isNotEmpty == true ? b.label : tr('sem rótulo')}';
  }

  static List<String> get dayNames => [
    tr('Dom'),
    tr('Seg'),
    tr('Ter'),
    tr('Qua'),
    tr('Qui'),
    tr('Sex'),
    tr('Sáb'),
  ];

  /// "1-5", "0,6", "5-1" → conjunto de dias (0 = domingo). Vazio = todo dia.
  static Set<int> parseDays(String text) {
    final out = <int>{};
    for (final part in text.split(',')) {
      final range = part.trim().split('-');
      final a = int.tryParse(range[0]);
      if (a == null || a < 0 || a > 6) continue;
      final b = range.length == 2
          ? (int.tryParse(range[1]) ?? a).clamp(0, 6)
          : a;
      if (a <= b) {
        for (var d = a; d <= b; d++) {
          out.add(d);
        }
      } else {
        for (var d = a; d <= 6; d++) {
          out.add(d);
        }
        for (var d = 0; d <= b; d++) {
          out.add(d);
        }
      }
    }
    return out;
  }

  static String _daysText(String? days) {
    final set = parseDays(days ?? '');
    if (set.isEmpty || set.length == 7) return tr('todo dia');
    if (set.length == 5 && !set.contains(0) && !set.contains(6)) {
      return tr('dias úteis');
    }
    if (set.length == 2 && set.contains(0) && set.contains(6)) {
      return tr('fim de semana');
    }
    return (set.toList()..sort()).map((d) => dayNames[d]).join(', ');
  }

  /// O "Quando" do cartão, em uma linha.
  String _when(Map<String, dynamic> t) {
    final event = t['event'] as String? ?? 'schedule';
    return switch (event) {
      'schedule' =>
        '${t['time'] ?? '--:--'} · ${_daysText(t['days'] as String?)}',
      'app_start' || 'app_exit' => '${events[event]}: ${t['app'] ?? ''}',
      'tally_on' || 'tally_off' =>
        '${events[event]}: ${t['targetLabel'] ?? t['target'] ?? ''}',
      _ => events[event] ?? event,
    };
  }

  /// O "Quando" do cartão sem repetir o título: sem nome próprio, o título já é o
  /// acontecimento e a linha fica só com o detalhe (horário, app, alvo); nulo = nada a
  /// acrescentar.
  String? _whenLine(Map<String, dynamic> t) {
    if ((t['name'] as String?)?.isNotEmpty == true) return _when(t);
    final event = t['event'] as String? ?? 'schedule';
    return switch (event) {
      'schedule' =>
        '${t['time'] ?? '--:--'} · ${_daysText(t['days'] as String?)}',
      'app_start' || 'app_exit' => '${t['app'] ?? ''}',
      'tally_on' || 'tally_off' => '${t['targetLabel'] ?? t['target'] ?? ''}',
      _ => null,
    };
  }

  Future<void> _edit([Map<String, dynamic>? existing]) async {
    final result = await showSettingsSheet<Map<String, dynamic>>(
      context: context,
      title: existing == null ? tr('Nova automação') : tr('Automação'),
      builder: (_) => _TriggerEditor(
        initial: existing ?? {'event': 'schedule', 'enabled': true},
        profiles: _profiles,
      ),
    );
    if (result == null) return;
    setState(() {
      if (existing != null) {
        _triggers[_triggers.indexOf(existing)] = result;
      } else {
        _triggers.add(result);
      }
    });
    await _save();
  }

  Future<void> _run(Map<String, dynamic> t) async {
    final id = t['id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      _snack(tr('Salve a automação e confira se o botão ainda existe.'));
      return;
    }
    try {
      await _client.postJson('/api/triggers/$id/run');
      _snack(tr('Botão apertado.'));
    } catch (_) {
      _snack(tr('Salve a automação e confira se o botão ainda existe.'));
    }
  }

  Future<void> _delete(Map<String, dynamic> t) async {
    final ok = await showAppleDialog<bool>(
      context: context,
      title: tr('Excluir automação?'),
      actions: [
        AppleDialogAction(label: tr('Cancelar'), value: false),
        AppleDialogAction(
          label: tr('Excluir'),
          value: true,
          isDestructive: true,
        ),
      ],
    );
    if (ok != true) return;
    setState(() => _triggers.remove(t));
    await _save();
  }

  Future<void> _menu(Map<String, dynamic> t) async {
    final c = AppleColors.of(context);
    final choice = await showSettingsSheet<String>(
      context: context,
      title: _title(t),
      builder: (sheet) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: AppleSpacing.xs),
        children: [
          InsetGroupedSection(
            children: [
              ListRow(
                leading: ListRowIcon(Icons.play_arrow_rounded, color: c.green),
                title: tr('Testar agora'),
                onTap: () => Navigator.of(sheet).pop('run'),
              ),
              ListRow(
                leading: ListRowIcon(Icons.edit_outlined, color: c.blue),
                title: tr('Editar'),
                onTap: () => Navigator.of(sheet).pop('edit'),
              ),
              ListRow(
                title: tr('Excluir'),
                destructive: true,
                onTap: () => Navigator.of(sheet).pop('delete'),
              ),
            ],
          ),
        ],
      ),
    );
    if (choice == 'run') _run(t);
    if (choice == 'edit') _edit(t);
    if (choice == 'delete') _delete(t);
  }

  String _title(Map<String, dynamic> t) =>
      (t['name'] as String?)?.isNotEmpty == true
      ? t['name'] as String
      : events[t['event']] ?? '';

  @override
  Widget build(BuildContext context) {
    final ready = !_loading && _error == null;
    return SettingsScaffold(
      title: tr('Automações'),
      subtitle: tr(
        'Uma automação aperta um botão do deck sozinha quando algo acontece '
        'no PC. Crie antes o botão com a ação desejada.',
      ),
      actions: [
        if (ready)
          IconButton(
            tooltip: tr('Nova automação'),
            icon: const Icon(Icons.add_rounded),
            onPressed: () => _edit(),
          ),
      ],
      bottom: ready && _triggers.isNotEmpty
          ? PrimaryButton(
              label: tr('Nova automação'),
              icon: Icons.add_rounded,
              onPressed: () => _edit(),
              expand: true,
            )
          : null,
      children: [
        if (_loading)
          Padding(
            padding: const EdgeInsets.all(AppleSpacing.xxl),
            child: Center(
              child: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: AppleColors.of(context).secondaryLabel,
                ),
              ),
            ),
          )
        else if (_error != null)
          AppleBanner.error(
            _error!,
            title: tr('O PC não respondeu.'),
            onRetry: _load,
            margin: const EdgeInsets.symmetric(horizontal: AppleSpacing.screen),
          )
        else if (_triggers.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppleSpacing.xxl),
            child: EmptyState(
              icon: Icons.bolt_rounded,
              title: tr('Nenhuma automação ainda.'),
              message: tr(
                'Apertar um botão sozinho num horário, quando um app abrir…',
              ),
              action: PrimaryButton(
                label: tr('Nova automação'),
                icon: Icons.add_rounded,
                onPressed: () => _edit(),
              ),
            ),
          )
        else
          for (final t in _triggers)
            _TriggerCard(
              title: _title(t),
              when: _whenLine(t),
              action: _buttonName(t),
              style: eventStyle(AppleColors.of(context), t['event'] as String?),
              enabled: t['enabled'] != false,
              onToggle: (v) {
                setState(() => t['enabled'] = v);
                _save();
              },
              onTap: () => _edit(t),
              onMore: () => _menu(t),
            ),
      ],
    );
  }
}

/// Cartão de uma automação: chip do acontecimento, nome, interruptor, e as linhas
/// "Quando" e "Fazer".
class _TriggerCard extends StatelessWidget {
  const _TriggerCard({
    required this.title,
    required this.when,
    required this.action,
    required this.style,
    required this.enabled,
    required this.onToggle,
    required this.onTap,
    required this.onMore,
  });

  final String title;
  final String? when;
  final String action;
  final (IconData, Color) style;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    Widget line(String label, IconData icon, Color color, String text) => Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: AppleSpacing.xs),
        Text(
          label,
          style: type.footnote.copyWith(
            color: c.secondaryLabel,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: AppleSpacing.xs - 2),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: type.subheadline.copyWith(color: c.label),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpacing.screen,
        0,
        AppleSpacing.screen,
        AppleSpacing.sm,
      ),
      child: ApplePressable(
        onTap: onTap,
        onLongPress: onMore,
        pressedScale: 0.98,
        child: AnimatedOpacity(
          duration: AppleMotion.of(context, AppleMotion.normal),
          opacity: enabled ? 1 : 0.55,
          child: Container(
            padding: const EdgeInsets.fromLTRB(
              AppleSpacing.md,
              AppleSpacing.sm,
              AppleSpacing.sm,
              AppleSpacing.md,
            ),
            decoration: BoxDecoration(
              color: c.secondaryGroupedBackground,
              borderRadius: BorderRadius.circular(AppleRadii.lg),
              border: Border.all(color: c.separator, width: 1),
              boxShadow: c.isDark ? null : AppleShadows.card(Brightness.light),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    BrandChip(style.$1, color: style.$2, size: 32),
                    const SizedBox(width: AppleSpacing.sm),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.headline.copyWith(color: c.label),
                      ),
                    ),
                    IconButton(
                      tooltip: tr('Opções'),
                      visualDensity: VisualDensity.compact,
                      onPressed: onMore,
                      icon: Icon(
                        Icons.more_horiz_rounded,
                        color: c.secondaryLabel,
                        size: 22,
                      ),
                    ),
                    AppleSwitch(value: enabled, onChanged: onToggle),
                  ],
                ),
                const SizedBox(height: AppleSpacing.sm),
                if (when != null) ...[
                  line(tr('Quando'), style.$1, c.secondaryLabel, when!),
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 2, bottom: 2),
                    child: Icon(
                      Icons.arrow_downward_rounded,
                      size: 13,
                      color: c.tertiaryLabel,
                    ),
                  ),
                ],
                line(
                  tr('Fazer'),
                  Icons.grid_view_rounded,
                  c.accent,
                  action,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Editor de uma automação, numa folha: nome, Quando (e o detalhe do acontecimento) e o
/// botão a apertar. Devolve a automação pronta (via Navigator.pop) ao salvar.
class _TriggerEditor extends StatefulWidget {
  final Map<String, dynamic> initial;
  final List<DeckProfile> profiles;

  const _TriggerEditor({required this.initial, required this.profiles});

  @override
  State<_TriggerEditor> createState() => _TriggerEditorState();
}

class _TriggerEditorState extends State<_TriggerEditor> {
  late final Map<String, dynamic> _t = Map.of(widget.initial);
  late final _appCtrl = TextEditingController(text: _t['app'] as String? ?? '');

  String get _event => _t['event'] as String? ?? 'schedule';

  /// "perfil|botão" de todos os botões com ação.
  Map<String, String> get _buttons => {
    for (final p in widget.profiles)
      for (final b in p.buttons.where(
        (b) => b.action != null && b.action!.type != 'none',
      ))
        '${p.id}|${b.id}':
            '${p.name} · ${b.label?.isNotEmpty == true ? b.label : tr('sem rótulo')}',
  };

  List<(String, String)> _apps = [];

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  @override
  void dispose() {
    _appCtrl.dispose();
    super.dispose();
  }

  /// Apps com janela aberta no PC agora, para escolher sem digitar o nome do processo.
  Future<void> _loadApps() async {
    try {
      final list =
          await Injector.get<DeckOSClient>().getJson('/api/system/apps')
              as List;
      if (!mounted) return;
      setState(
        () => _apps = [
          for (final e in list)
            ('${(e as Map)['value']}', '${e['label'] ?? e['value']}'),
        ],
      );
    } catch (_) {}
  }

  /// Seletor de horário multiplataforma (24 h).
  Future<void> _pickTime() async {
    final parts = (_t['time'] as String? ?? '').split(':');
    final initial = TimeOfDay(
      hour: parts.length == 2 ? (int.tryParse(parts[0]) ?? 9).clamp(0, 23) : 9,
      minute: parts.length == 2 ? (int.tryParse(parts[1]) ?? 0).clamp(0, 59) : 0,
    );
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null || !mounted) return;
    String two(int v) => v.toString().padLeft(2, '0');
    setState(() => _t['time'] = '${two(picked.hour)}:${two(picked.minute)}');
  }

  /// Dias da semana como chips responsivos; guarda no formato do PC ("1,2,3", 0 = domingo).
  Widget _daysPicker(AppleColors c) {
    final type = AppleTextStyles.of(context);
    final names = _TriggersPageState.dayNames;
    final days = _TriggersPageState.parseDays(_t['days'] as String? ?? '');
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpacing.md,
        AppleSpacing.sm,
        AppleSpacing.md,
        AppleSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('Dias da semana'), style: type.body.copyWith(color: c.label)),
          const SizedBox(height: AppleSpacing.sm),
          Wrap(
            spacing: AppleSpacing.xs,
            runSpacing: AppleSpacing.xs,
            children: [
              for (var d = 0; d < 7; d++)
                Builder(
                  builder: (context) {
                    final on = days.isEmpty || days.contains(d);
                    return Semantics(
                      button: true,
                      selected: on,
                      label: names[d],
                      excludeSemantics: true,
                      child: ApplePressable(
                        pressedScale: 0.92,
                        onTap: () => setState(() {
                          final next = days.isEmpty
                              ? {0, 1, 2, 3, 4, 5, 6}
                              : {...days};
                          on ? next.remove(d) : next.add(d);
                          // Todos marcados = todo dia (campo vazio).
                          _t['days'] = next.length == 7 || next.isEmpty
                              ? ''
                              : (next.toList()..sort()).join(',');
                        }),
                        child: AnimatedContainer(
                          duration: AppleMotion.of(context, AppleMotion.fast),
                          constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: on ? c.accent : c.tertiaryFill,
                            borderRadius: BorderRadius.circular(AppleRadii.sm),
                            border: Border.all(
                              color: on ? c.accent : c.separator,
                              width: 1,
                            ),
                          ),
                          child: Text(
                            names[d].characters.take(3).toString(),
                            style: type.caption1.copyWith(
                              color: on ? c.onAccent : c.label,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickApp() async {
    final v = await showChoiceSheet<String>(
      context: context,
      title: tr('Aplicativo'),
      footer: tr('Abra o app no PC para ele aparecer na lista.'),
      selected: _t['app'] as String?,
      choices: [for (final a in _apps) Choice(a.$1, a.$2, subtitle: a.$1)],
    );
    if (v == null) return;
    setState(() {
      _t['app'] = v;
      _appCtrl.text = v;
    });
  }

  Future<void> _pickEvent() async {
    final c = AppleColors.of(context);
    final v = await showChoiceSheet<String>(
      context: context,
      title: tr('Quando'),
      selected: _event,
      choices: [
        for (final e in _TriggersPageState.events.entries)
          Choice(
            e.key,
            e.value,
            leading: () {
              final (icon, color) = _TriggersPageState.eventStyle(c, e.key);
              return ListRowIcon(icon, color: color);
            }(),
          ),
      ],
    );
    if (v != null) setState(() => _t['event'] = v);
  }

  Future<void> _pickButton(Map<String, String> buttons, String selected) async {
    final v = await showChoiceSheet<String>(
      context: context,
      title: tr('Apertar o botão'),
      selected: selected,
      choices: [for (final e in buttons.entries) Choice(e.key, e.value)],
    );
    if (v == null) return;
    setState(() {
      final parts = v.split('|');
      _t['profileId'] = parts[0];
      _t['buttonId'] = parts[1];
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final buttons = _buttons;
    final selected = '${_t['profileId']}|${_t['buttonId']}';
    final (eventIcon, eventColor) = _TriggersPageState.eventStyle(c, _event);
    // Não deixa salvar uma automação que nunca dispararia.
    final valid =
        buttons.containsKey(selected) &&
        (_event != 'schedule' || (_t['time'] as String? ?? '').isNotEmpty) &&
        (!(_event == 'app_start' || _event == 'app_exit') ||
            (_t['app'] as String? ?? '').isNotEmpty) &&
        (!(_event == 'tally_on' || _event == 'tally_off') ||
            (_t['target'] as String? ?? '').isNotEmpty);
    final time = _t['time'] as String?;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: AppleSpacing.xs),
      children: [
        InsetGroupedSection(
          children: [
            FormTextRow(
              label: tr('Nome'),
              initialValue: _t['name'] as String? ?? '',
              hint: tr('Nome (opcional)'),
              onChanged: (v) => _t['name'] = v.trim(),
            ),
          ],
        ),
        InsetGroupedSection(
          header: tr('Quando'),
          children: [
            ListRow(
              leading: ListRowIcon(eventIcon, color: eventColor),
              title: _TriggersPageState.events[_event] ?? _event,
              chevron: true,
              onTap: _pickEvent,
            ),
            if (_event == 'schedule') ...[
              ListRow(
                title: tr('Horário'),
                value: time?.isNotEmpty == true ? time! : tr('Escolher'),
                chevron: true,
                onTap: _pickTime,
              ),
              _daysPicker(c),
            ],
            if (_event == 'app_start' || _event == 'app_exit') ...[
              FormTextRow(
                label: tr('Aplicativo'),
                controller: _appCtrl,
                hint: tr('Escolha um app aberto ou digite o nome'),
                onChanged: (v) => setState(() => _t['app'] = v.trim()),
              ),
              ListRow(
                leading: ListRowIcon(
                  Icons.apps_rounded,
                  color: c.blue,
                ),
                title: tr('Escolher entre os apps abertos'),
                enabled: _apps.isNotEmpty,
                chevron: true,
                onTap: _apps.isEmpty ? null : _pickApp,
              ),
            ],
            if (_event == 'tally_on' || _event == 'tally_off')
              Padding(
                padding: const EdgeInsets.all(AppleSpacing.sm),
                child: TallyTargetField(
                  value: _t['target'] as String?,
                  onChanged: (id, label) => setState(() {
                    _t['target'] = id;
                    _t['targetLabel'] = label;
                  }),
                ),
              ),
          ],
        ),
        InsetGroupedSection(
          header: tr('Fazer'),
          footer: buttons.isEmpty
              ? tr('Crie antes o botão com a ação desejada.')
              : null,
          children: [
            ListRow(
              leading: ListRowIcon(
                Icons.touch_app_rounded,
                color: c.accent,
              ),
              title: tr('Apertar o botão'),
              subtitle: buttons[selected] ?? tr('Escolher'),
              chevron: true,
              enabled: buttons.isNotEmpty,
              onTap: buttons.isEmpty
                  ? null
                  : () => _pickButton(buttons, selected),
            ),
          ],
        ),
        FormActions(
          children: [
            PrimaryButton(
              label: tr('Salvar'),
              onPressed: valid ? () => Navigator.pop(context, _t) : null,
              expand: true,
            ),
            SecondaryButton(
              label: tr('Cancelar'),
              onPressed: () => Navigator.pop(context),
              expand: true,
            ),
          ],
        ),
      ],
    );
  }
}
