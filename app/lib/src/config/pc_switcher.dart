import 'package:deckos/core/core.dart';
import 'package:deckos/src/connection/usb_route.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/material.dart';

/// Troca o PC em uso e reabre o app nele (deck, catálogo e estados vêm do novo PC).
Future<void> switchToPc(BuildContext context, SavedPc pc) async {
  await PcStore.select(pc);
  final baseUrl = await UsbRoute.pick(pc.baseUrl, apiKey: pc.apiKey);
  final client = Injector.get<DeckOSClient>();
  client.setBaseUrl(baseUrl);
  client.setApiKey(pc.apiKey);
  await Injector.get<SignalRService>().updateUrl(baseUrl, apiKey: pc.apiKey);
  if (context.mounted) {
    Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
  }
}

/// Pede o nome do PC (nome do Windows) e guarda, se o PC ainda tem o nome provisório.
Future<void> fetchPcName(SavedPc pc) async {
  if (pc.name != pc.ip && pc.name != 'PC') return;
  try {
    final r = await Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
        headers: {if (pc.apiKey != null) 'X-API-Key': pc.apiKey},
      ),
    ).get('${pc.baseUrl}/api/system/info');
    final name = (r.data is Map) ? r.data['name'] as String? : null;
    if (name != null && name.isNotEmpty) await PcStore.rename(pc.id, name);
  } catch (_) {}
}

/// Botão da barra do deck para trocar de PC. Só aparece com mais de um PC pareado.
class PcMenuButton extends StatefulWidget {
  const PcMenuButton({super.key});

  @override
  State<PcMenuButton> createState() => _PcMenuButtonState();
}

class _PcMenuButtonState extends State<PcMenuButton> {
  List<SavedPc> _pcs = [];

  @override
  void initState() {
    super.initState();
    PcStore.load().then((list) {
      if (mounted) setState(() => _pcs = list);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_pcs.length < 2) return const SizedBox.shrink();
    final c = AppleColors.of(context);
    return PopupMenuButton<SavedPc>(
      icon: Icon(Icons.computer_rounded, size: 21, color: c.label),
      tooltip: tr('Trocar de PC'),
      onSelected: (pc) {
        if (pc.id != PcStore.currentId) switchToPc(context, pc);
      },
      itemBuilder: (_) => [
        for (final pc in _pcs)
          PopupMenuItem(
            value: pc,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: ListRowIcon(
                Icons.computer_rounded,
                color: pc.id == PcStore.currentId ? c.accent : c.gray,
              ),
              title: Text(pc.name),
              subtitle: Text(pc.ip),
              trailing: pc.id == PcStore.currentId
                  ? Icon(
                      Icons.check_rounded,
                      color: c.accent,
                      size: 20,
                    )
                  : null,
            ),
          ),
      ],
    );
  }
}
