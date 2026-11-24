import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'settings_kit.dart';

/// Only shown in the companion's same-machine configurator; server checks this too.
class PairedDevicesPage extends StatefulWidget {
  const PairedDevicesPage({super.key});
  @override
  State<PairedDevicesPage> createState() => _PairedDevicesPageState();
}

class _PairedDevicesPageState extends State<PairedDevicesPage> {
  List<dynamic> _devices = [];
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list =
          await Injector.get<DeckOSClient>().getJson('/api/pairing/devices')
              as List;
      if (mounted)
        setState(() {
          _devices = list;
          _error = null;
        });
    } catch (_) {
      if (mounted)
        setState(() => _error = tr('Open these settings on the PC itself.'));
    }
  }

  Future<void> _copyCode() async {
    final result =
        await Injector.get<DeckOSClient>().getJson('/api/pairing/qr') as Map;
    await Clipboard.setData(ClipboardData(text: result['code'] as String));
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Pairing code copied. Use it within 3 minutes and keep it private.',
            ),
          ),
        ),
      );
  }

  Future<void> _revoke(Map device) async {
    final confirmed = await showAppleDialog<bool>(
      context: context,
      title: tr('Revoke this device?'),
      message: tr(
        'It will disconnect immediately and need a new pairing code.',
      ),
      actions: [
        AppleDialogAction(label: tr('Cancelar'), value: false),
        AppleDialogAction(
          label: tr('Revoke device'),
          value: true,
          isDestructive: true,
        ),
      ],
    );
    if (confirmed != true) return;
    await Injector.get<DeckOSClient>().deleteJson(
      '/api/pairing/devices/${device['id']}',
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: tr('Paired devices'),
    children: [
      if (_error != null) Text(_error!),
      Text(
        tr(
          'Only pair while looking at this PC. Codes expire after 3 minutes and work once.',
        ),
      ),
      const SizedBox(height: AppleSpacing.md),
      PrimaryButton(
        label: tr('Copy secure pairing code'),
        onPressed: _copyCode,
        expand: true,
      ),
      for (final device in _devices)
        ListTile(
          title: Text('${device['name']}'),
          subtitle: Text('${device['created']}'),
          trailing: TextButton(
            onPressed: () => _revoke(device as Map),
            child: Text(tr('Revoke device')),
          ),
        ),
    ],
  );
}
