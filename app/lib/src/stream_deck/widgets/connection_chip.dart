import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/material.dart';

/// Estado da ligação com o PC, já resumido do texto do SignalR.
enum DeckLink {
  connected,
  connecting,
  reconnecting,
  offline;

  /// "Connected", "Connecting...", "Reconnecting..." (reconexão automática em
  /// andamento) ou "Reconnecting in Ns" (espera entre tentativas: o PC não responde).
  static DeckLink of(String status) {
    if (status == 'Connected') return DeckLink.connected;
    if (status.startsWith('Connecting')) return DeckLink.connecting;
    if (status == 'Reconnecting...') return DeckLink.reconnecting;
    return DeckLink.offline;
  }

  /// Ainda tentando: a bolinha pulsa.
  bool get busy => this == connecting || this == reconnecting;

  /// Verde conectado, laranja tentando, vermelho sem conexão.
  Color color(AppleColors c) => switch (this) {
        DeckLink.connected => c.green,
        DeckLink.connecting || DeckLink.reconnecting => c.orange,
        DeckLink.offline => c.red,
      };

  String get text => switch (this) {
        DeckLink.connected => tr('Conectado'),
        DeckLink.connecting => tr('Conectando…'),
        DeckLink.reconnecting => tr('Reconectando…'),
        DeckLink.offline => tr('Sem conexão'),
      };
}

/// O LED do canto do deck: só a bolinha, como nos prints do PhoneDeck. Verde parado,
/// laranja pulsando enquanto tenta, vermelho sem conexão. O toque explica o estado.
class DeckLinkDot extends StatelessWidget {
  const DeckLinkDot({super.key, this.size = 7});

  final double size;

  @override
  Widget build(BuildContext context) {
    final status = Injector.get<SignalRService>().connectionStatus.watch(context);
    final link = DeckLink.of(status);
    return Semantics(
      button: true,
      label: tr('Conexão com o PC'),
      value: link.text,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showConnectionDetails(context),
        // Área de toque bem maior que o ponto.
        child: Padding(
          padding: const EdgeInsets.all(AppleSpacing.sm),
          child: ConnectionStatusDot(link: link, size: size),
        ),
      ),
    );
  }
}

/// A bolinha de um [DeckLink], sem ler o SignalR (testável sozinha).
class ConnectionStatusDot extends StatefulWidget {
  const ConnectionStatusDot({super.key, required this.link, this.size = 7});

  final DeckLink link;
  final double size;

  @override
  State<ConnectionStatusDot> createState() => _ConnectionStatusDotState();
}

class _ConnectionStatusDotState extends State<ConnectionStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ConnectionStatusDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Pulsa só enquanto tenta, e nunca com "reduzir movimento".
  void _sync() {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.link.busy && !reduce) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.link.color(AppleColors.of(context));
    final s = widget.size;
    return SizedBox.square(
      dimension: s * 3,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = Curves.easeOut.transform(_pulse.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              // Onda que se abre e some, como o "procurando" do AirDrop.
              if (_pulse.isAnimating)
                Container(
                  width: s * (1 + 2 * t),
                  height: s * (1 + 2 * t),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.45 * (1 - t)),
                  ),
                ),
              StatusDot(color: color, size: s),
            ],
          );
        },
      ),
    );
  }
}

/// Explica a conexão numa folha do iOS: o que está acontecendo, o que fazer e, recolhidos,
/// os dados técnicos.
Future<void> showConnectionDetails(BuildContext context) {
  final signalR = Injector.get<SignalRService>();
  final status = signalR.connectionStatus.value;
  final url = signalR.currentUrl.value;
  final link = DeckLink.of(status);
  final viaUsb = url.contains('127.0.0.1') && !WebMode.configurator;
  final explain = switch (link) {
    DeckLink.connected => viaUsb
        ? tr('Tudo certo: este aparelho fala com o PC pelo cabo USB.')
        : tr('Tudo certo: os botões e os dados ao vivo estão chegando do PC.'),
    DeckLink.connecting => tr('Procurando o PC. Leva alguns segundos.'),
    DeckLink.reconnecting => tr(
        'A conexão caiu e está voltando sozinha. Se demorar, confira se o PC está ligado e na mesma rede.'),
    DeckLink.offline => tr(
        'O PC não está respondendo. Confira se o DeckOS está aberto nele (ícone perto do relógio) '
        'e se os dois estão na mesma rede Wi-Fi. Enquanto isso, o último deck salvo continua aqui.'),
  };
  return showAppleSheet(
    context: context,
    title: tr('Conexão com o PC'),
    builder: (ctx) {
      final c = AppleColors.of(ctx);
      final type = AppleTextStyles.of(ctx);
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppleSpacing.screen, 0, AppleSpacing.screen, AppleSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ConnectionStatusDot(link: link, size: 10),
                const SizedBox(width: AppleSpacing.xs),
                Expanded(
                  child: Text(
                    link == DeckLink.connected && _ConnectionChipState._pcName != null
                        ? tr('Conectado a {pc}', {'pc': _ConnectionChipState._pcName})
                        : link.text,
                    style: type.headline,
                  ),
                ),
                if (viaUsb) Icon(Icons.usb_rounded, size: 18, color: c.secondaryLabel),
              ],
            ),
            const SizedBox(height: AppleSpacing.xs),
            Text(explain, style: type.subheadline.copyWith(color: c.secondaryLabel)),
            const SizedBox(height: AppleSpacing.md),
            Theme(
              // Sem as linhas que o ExpansionTile põe em volta quando abre.
              data: Theme.of(ctx).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(tr('Detalhes técnicos'),
                    style: type.footnote.copyWith(color: c.secondaryLabel)),
                children: [
                  SelectableText(
                    tr('Status: {status}\n\nURL: {url}\n\nÚltimos dados:\n{data}', {
                      'status': status,
                      'url': url,
                      'data': signalR.lastDebugData.value,
                    }),
                    style: type.caption1.copyWith(color: c.secondaryLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Estado da conexão com o PC, com texto e bolinha (não só cor): "Conectado ao PC-SALA",
/// "Conectando…", "Reconectando…" ou "Sem conexão". O toque explica o que fazer; os dados
/// técnicos ficam recolhidos para quem precisar. Usado no configurador do PC; no celular
/// o deck mostra só o [DeckLinkDot].
class ConnectionChip extends StatefulWidget {
  /// Só a bolinha e uma palavra (barra estreita).
  final bool compact;

  const ConnectionChip({super.key, this.compact = false});

  @override
  State<ConnectionChip> createState() => _ConnectionChipState();
}

class _ConnectionChipState extends State<ConnectionChip> {
  static String? _pcName;

  @override
  void initState() {
    super.initState();
    if (_pcName == null) loadPcName().then((_) => mounted ? setState(() {}) : null);
  }

  @override
  Widget build(BuildContext context) {
    final signalR = Injector.get<SignalRService>();
    final link = DeckLink.of(signalR.connectionStatus.watch(context));
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final color = link.color(c);
    final text = link == DeckLink.connected && !widget.compact && _pcName != null
        ? tr('Conectado a {pc}', {'pc': _pcName})
        : link.text;

    return Semantics(
      button: true,
      label: text,
      child: Tooltip(
        message: text,
        child: ApplePressable(
          pressedScale: 0.96,
          haptic: false,
          onTap: () => showConnectionDetails(context),
          child: Container(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
            decoration: ShapeDecoration(
              color: color.withValues(alpha: 0.12),
              shape: StadiumBorder(side: AppleShapes.hairline(color.withValues(alpha: 0.35))),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConnectionStatusDot(link: link, size: 7),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    text,
                    overflow: TextOverflow.ellipsis,
                    style: type.footnote.copyWith(fontWeight: FontWeight.w600, color: c.label),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Busca o nome do PC (como aparece no Windows) uma vez; os selos mostram quando chega.
Future<String?> loadPcName() async {
  if (_ConnectionChipState._pcName != null) return _ConnectionChipState._pcName;
  try {
    final info = await Injector.get<DeckOSClient>().getJson('/api/system/info');
    final name = (info is Map) ? info['name'] as String? : null;
    if (name != null && name.isNotEmpty) _ConnectionChipState._pcName = name;
  } catch (_) {}
  return _ConnectionChipState._pcName;
}
