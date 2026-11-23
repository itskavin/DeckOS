import 'dart:convert';
import 'dart:typed_data';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/actions/action_schema.dart';
import 'package:deckos/src/stream_deck/layout/app_icon.dart';
import 'package:deckos/src/stream_deck/layout/fuzzy.dart';
import 'package:deckos/src/config/integrations_page.dart';
import 'package:flutter/material.dart';

/// Formulário montado a partir do [ActionSchema]. Avisa o painel a cada mudança com
/// os parâmetros dos campos visíveis (os escondidos não vão para o botão).
class SchemaActionForm extends StatefulWidget {
  final ActionSchema schema;
  final Map<String, String> initial;
  final ValueChanged<Map<String, String>> onChanged;

  /// Carregamento opcional da lista de apps instalados (usado nos testes).
  final Future<List<InstalledApp>?> Function()? loadApps;

  /// Sugere o nome e o ícone (base64 PNG) do aplicativo escolhido no inspetor.
  final ValueChanged<String>? suggestLabel;
  final ValueChanged<String>? suggestIcon;

  /// Carregamento opcional do PNG do ícone do app (usado nos testes).
  final Future<Uint8List?> Function(InstalledApp app)? loadAppIcon;

  const SchemaActionForm({
    super.key,
    required this.schema,
    required this.initial,
    required this.onChanged,
    this.loadApps,
    this.suggestLabel,
    this.suggestIcon,
    this.loadAppIcon,
  });

  @override
  State<SchemaActionForm> createState() => _SchemaActionFormState();
}

class _SchemaActionFormState extends State<SchemaActionForm> {
  late final Map<String, String> _values;

  /// Opções carregadas por URL já resolvida (com os {placeholders} trocados).
  final Map<String, List<FieldOption>> _options = {};
  final Map<String, String> _errors = {};
  final Set<String> _loading = {};

  List<InstalledApp>? _installedApps;
  bool _appsLoading = false;
  bool _appsFetched = false;
  int _formRevision = 0;

  bool get _hasAppIdField =>
      widget.schema.type == 'launch_app' &&
      widget.schema.fields.any((f) => f.key == 'appId');

  @override
  void initState() {
    super.initState();
    _values = {...widget.schema.defaults(), ...widget.initial};
    if (_hasAppIdField) _loadInstalledApps();
    // O painel precisa dos valores padrão mesmo que o usuário não toque em nada.
    WidgetsBinding.instance.addPostFrameCallback((_) => _emit());
  }

  Future<void> _loadInstalledApps() async {
    if (_appsFetched || _appsLoading) return;
    _appsFetched = true;
    _appsLoading = true;
    try {
      final loader = widget.loadApps ?? () => Injector.get<DeckOSClient>().getApps();
      final apps = await loader();
      if (mounted) {
        setState(() {
          _installedApps = apps;
          _appsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _installedApps = null;
          _appsLoading = false;
        });
      }
    }
  }

  void _emit() {
    final out = <String, String>{};
    for (final f in widget.schema.fields) {
      if (!f.isVisible(_values)) continue;
      final v = _values[f.key];
      if (v != null && v.isNotEmpty) out[f.key] = v;
    }
    widget.onChanged(out);
  }

  void _set(String key, String value) {
    setState(() => _values[key] = value);
    _emit();
  }

  /// Troca {chave} pelo valor atual; null se alguma dependência ainda está vazia.
  String? _resolve(String source) {
    var missing = false;
    final url = source.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      final v = _values[m.group(1)!] ?? '';
      if (v.isEmpty) missing = true;
      return Uri.encodeQueryComponent(v);
    });
    return missing ? null : url;
  }

  Future<void> _fetch(String url, {bool force = false}) async {
    if (_loading.contains(url) || (!force && _options.containsKey(url))) return;
    setState(() {
      _loading.add(url);
      _errors.remove(url);
    });
    try {
      final data = await Injector.get<DeckOSClient>().getJson(url);
      final list = (data is List ? data : const [])
          .map(FieldOption.fromJson)
          .where((o) => o.value.isNotEmpty)
          .toList();
      if (mounted) setState(() => _options[url] = list);
    } catch (e) {
      if (mounted) {
        setState(() {
          _options[url] = const [];
          _errors[url] = _errorText(e);
        });
      }
    } finally {
      if (mounted) setState(() => _loading.remove(url));
    }
  }

  String _errorText(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['error'] is String) return data['error'] as String;
    }
    return tr('Não foi possível carregar a lista.');
  }

  @override
  Widget build(BuildContext context) {
    final schema = widget.schema;
    final muted = TextStyle(
        fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant);

    final children = <Widget>[
      if (schema.settings != null && schema.stateEvent != null)
        IntegrationWarning(schema: schema),
      if (schema.description != null) ...[
        Text(schema.description!, style: muted.copyWith(fontSize: 12)),
        const SizedBox(height: 12),
      ],
    ];

    for (final f in schema.fields) {
      if (!f.isVisible(_values)) continue;
      children
        ..add(_field(f))
        ..add(const SizedBox(height: 12));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _field(ActionField f) {
    if (widget.schema.type == 'launch_app' && f.key == 'appId') {
      return _appIdField(f);
    }
    switch (f.kind) {
      case 'select':
        return f.optionsSource != null ? _dynamicSelect(f) : _select(f, f.options);
      case 'toggle':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label),
          subtitle: f.help != null ? Text(f.help!) : null,
          value: _values[f.key] == 'true',
          onChanged: (v) => _set(f.key, v ? 'true' : 'false'),
        );
      case 'number':
        return _number(f);
      case 'multiline':
        return _text(f, maxLines: 5);
      default:
        return _text(f);
    }
  }

  /// Linha somente leitura para o aplicativo salvo (nome + ícone de /api/apps, com fallback para o ID).
  Widget _appIdField(ActionField f) {
    final savedId = (_values[f.key] ?? '').trim();
    final apps = _installedApps;
    InstalledApp? resolved;
    if (savedId.isNotEmpty && apps != null) {
      for (final app in apps) {
        if (app.id == savedId) {
          resolved = app;
          break;
        }
      }
    }

    final scheme = Theme.of(context).colorScheme;
    final hasApps = apps != null && apps.isNotEmpty;

    final Widget leading;
    final Widget title;
    if (resolved != null) {
      leading = AppIconView(app: resolved, size: 28);
      title = Text(
        resolved.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      );
    } else if (savedId.isNotEmpty) {
      leading = Icon(Icons.apps_rounded, size: 24, color: scheme.onSurfaceVariant);
      title = Text(
        tr('ID salvo: {id}', {'id': savedId}),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurfaceVariant),
      );
    } else {
      leading = Icon(Icons.apps_rounded, size: 24, color: scheme.onSurfaceVariant);
      title = Text(
        tr('Nenhum aplicativo selecionado'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurfaceVariant),
      );
    }

    return InputDecorator(
      key: ValueKey('f_${f.key}_row'),
      decoration: _decoration(f),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(child: title),
          if (_appsLoading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            if (savedId.isNotEmpty)
              IconButton(
                tooltip: tr('Limpar seleção'),
                icon: const Icon(Icons.close, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () => _set(f.key, ''),
              ),
            if (hasApps)
              TextButton(
                onPressed: () => _openAppPicker(context, apps),
                child: Text(savedId.isEmpty ? tr('Escolher') : tr('Trocar')),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _openAppPicker(BuildContext context, List<InstalledApp> apps) async {
    final picked = await showDialog<InstalledApp>(
      context: context,
      builder: (_) => _InstalledAppPickerDialog(apps: apps, currentId: _values['appId']),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _values['appId'] = picked.id;
      _values['path'] = picked.path;
      _values['arguments'] = picked.arguments ?? '';
      _formRevision++;
    });
    _emit();
    // Preenche o rótulo e o ícone real do app, como ao arrastar da biblioteca.
    widget.suggestLabel?.call(picked.name);
    if (widget.suggestIcon != null) {
      try {
        final loader = widget.loadAppIcon ?? AppIconCache.pngForButton;
        final png = await loader(picked);
        if (mounted &&
            png != null &&
            png.isNotEmpty &&
            _values['appId'] == picked.id) {
          widget.suggestIcon!(base64Encode(png));
        }
      } catch (_) {}
    }
  }

  InputDecoration _decoration(ActionField f, {String? helper, Widget? suffix}) =>
      InputDecoration(
        labelText: f.label,
        hintText: f.hint,
        helperText: helper ?? f.help,
        helperMaxLines: 3,
        suffixText: f.unit,
        suffixIcon: suffix,
        border: const OutlineInputBorder(),
      );

  Widget _text(ActionField f, {int maxLines = 1}) => TextFormField(
        key: ValueKey('f_${f.key}_$_formRevision'),
        initialValue: _values[f.key] ?? '',
        minLines: maxLines > 1 ? 3 : 1,
        maxLines: maxLines,
        decoration: _decoration(f),
        onChanged: (v) => _set(f.key, v),
      );

  Widget _number(ActionField f) {
    final current = double.tryParse(_values[f.key] ?? '') ?? f.min ?? 0;
    final min = f.min, max = f.max;
    // Faixa curta e limitada: slider. O resto (segundos, ms...) é digitado.
    if (min != null && max != null && max - min <= 200) {
      final v = current.clamp(min, max).toDouble();
      final unit = f.unit ?? '';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${f.label}: ${_fmt(v)}$unit'),
          Slider(
            value: v,
            min: min,
            max: max,
            divisions: (max - min).round().clamp(1, 200),
            label: '${_fmt(v)}$unit',
            onChanged: (n) => _set(f.key, _fmt(n)),
          ),
          if (f.help != null)
            Text(f.help!,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      );
    }
    return TextFormField(
      key: ValueKey('f_${f.key}'),
      initialValue: _values[f.key] ?? '',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: _decoration(f),
      onChanged: (v) => _set(f.key, v.replaceAll(',', '.')),
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

  Widget _select(ActionField f, List<FieldOption> options,
      {String? helper, Widget? suffix}) {
    final value = _values[f.key];
    final known = options.any((o) => o.value == value);
    return DropdownButtonFormField<String>(
      key: ValueKey('f_${f.key}_${options.length}'),
      value: (value != null && value.isNotEmpty) ? value : null,
      isExpanded: true,
      decoration: _decoration(f, helper: helper, suffix: suffix),
      items: [
        ...options.map((o) => DropdownMenuItem(
            value: o.value,
            child: Text(o.label, overflow: TextOverflow.ellipsis))),
        // Valor salvo que a lista não traz (fonte apagada, OBS fechado): continua
        // selecionável, senão salvar de novo apagaria a configuração sem aviso.
        if (value != null && value.isNotEmpty && !known)
          DropdownMenuItem(
              value: value,
              child: Text(tr('{value} (salvo)', {'value': value}), overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) {
        if (v == null) return;
        _set(f.key, v);
        // Campos que dependem deste (ex.: filtros de uma fonte) recarregam sozinhos
        // no próximo build, pela URL nova.
      },
    );
  }

  Widget _dynamicSelect(ActionField f) {
    final url = _resolve(f.optionsSource!);
    if (url == null) {
      return InputDecorator(
        decoration: _decoration(f, helper: tr('Escolha o campo acima primeiro.')),
        child: const SizedBox(height: 20),
      );
    }
    if (!_options.containsKey(url)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fetch(url));
    }

    final options = _options[url] ?? const [];
    final loading = _loading.contains(url);
    final error = _errors[url];
    final refresh = loading
        ? const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
          )
        : IconButton(
            tooltip: tr('Recarregar a lista'),
            icon: const Icon(Icons.refresh),
            onPressed: () => _fetch(url, force: true),
          );

    // Sem lista (erro ou vazia) e o campo aceita texto livre: deixa digitar.
    if (options.isEmpty && !loading && (f.allowCustom || error != null)) {
      return TextFormField(
        key: ValueKey('f_${f.key}_text'),
        initialValue: _values[f.key] ?? '',
        decoration: _decoration(f,
            helper: error != null ? tr('{error} Digite o nome.', {'error': error}) : f.help,
            suffix: refresh),
        onChanged: (v) => _set(f.key, v),
      );
    }

    return _select(f, options,
        helper: options.isEmpty && !loading ? tr('Lista vazia.') : f.help,
        suffix: refresh);
  }
}

/// Seletor com busca dos aplicativos instalados vindos de /api/apps.
class _InstalledAppPickerDialog extends StatefulWidget {
  final List<InstalledApp> apps;
  final String? currentId;

  const _InstalledAppPickerDialog({required this.apps, this.currentId});

  @override
  State<_InstalledAppPickerDialog> createState() => _InstalledAppPickerDialogState();
}

class _InstalledAppPickerDialogState extends State<_InstalledAppPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = filterApps(widget.apps, _query);
    return AlertDialog(
      title: Text(tr('Escolher aplicativo')),
      content: SizedBox(
        width: 420,
        height: 380,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: tr('Buscar'),
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        widget.apps.isEmpty
                            ? tr('Nenhum app encontrado no PC')
                            : tr('Nada com "{q}"', {'q': _query.trim()}),
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, i) {
                        final app = filtered[i];
                        final selected = app.id == widget.currentId;
                        return ListTile(
                          dense: true,
                          selected: selected,
                          leading: AppIconView(app: app, size: 28),
                          title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(app.path, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: selected ? const Icon(Icons.check, size: 18) : null,
                          onTap: () => Navigator.of(context).pop(app),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('Cancelar')),
        ),
      ],
    );
  }
}

/// Aviso de integração desconectada, com atalho para a tela de configuração.
class IntegrationWarning extends StatelessWidget {
  final ActionSchema schema;

  const IntegrationWarning({super.key, required this.schema});

  static Widget? settingsPage(String? key) => IntegrationsPage.pageFor(key);

  @override
  Widget build(BuildContext context) {
    final signalR = Injector.get<SignalRService>();
    return Watch((context) {
      // Lê o signal certo para o Watch se inscrever nele.
      signalR.obsState.value;
      signalR.discordState.value;
      signalR.tuyaState.value;
      signalR.actionStates.value;
      final state = signalR.stateOf(schema.stateEvent!);
      if (state['connected'] == true) return const SizedBox.shrink();

      final page = settingsPage(schema.settings);
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.orange, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr('{name} não está conectado — esta ação não funciona até conectar.',
                    {'name': schema.title}),
                style: const TextStyle(fontSize: 12),
              ),
            ),
            if (page != null)
              TextButton(
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => page)),
                child: Text(tr('Configurar')),
              ),
          ],
        ),
      );
    });
  }
}
