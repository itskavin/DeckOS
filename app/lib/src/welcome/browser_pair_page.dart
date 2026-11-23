import 'package:deckos/core/core.dart';
import 'package:deckos/src/connection/constants.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'onboarding.dart';

/// Deck no navegador sem chave: explica como parear pelo QR "Abrir no navegador" do PC.
/// Também aceita a chave digitada, para quem não tem câmera à mão.
class BrowserPairPage extends StatefulWidget {
  /// A chave guardada foi recusada pelo PC (trocada ou de outro PC).
  final bool rejected;

  const BrowserPairPage({super.key, this.rejected = false});

  @override
  State<BrowserPairPage> createState() => _BrowserPairPageState();
}

class _BrowserPairPageState extends State<BrowserPairPage> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.rejected) {
      _error = tr('O PC recusou a chave salva neste navegador. Pareie de novo.');
    }
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _useKey() async {
    final key = _key.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = Injector.get<DeckOSClient>();
    client.setApiKey(key);
    if (!await client.checkKey()) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = tr('O PC não aceitou essa chave. Confira se copiou ela inteira, sem espaços.');
        });
      }
      return;
    }
    await (await SharedPreferences.getInstance()).setString(Constants.apiKeyKey, key);
    if (!mounted) return;
    // O splash refaz a conexão (SignalR) com a chave nova.
    Navigator.of(context).pushReplacementNamed('/');
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                  AppleSpacing.xl, AppleSpacing.xxl, AppleSpacing.xl, AppleSpacing.xl),
              children: [
                const AppIconMark(size: 72),
                const SizedBox(height: AppleSpacing.lg),
                Text(
                  tr('Usar este aparelho como deck'),
                  textAlign: TextAlign.center,
                  style: type.largeTitle.copyWith(color: c.label),
                ),
                const SizedBox(height: AppleSpacing.xxl),
                OnboardingFeatureRow(
                  icon: Icons.qr_code_scanner_rounded,
                  color: c.green,
                  title: tr('Pareie pelo QR'),
                  body: tr('No PC, clique com o botão direito no ícone do DeckOS → '
                      '"Parear dispositivo (QR)" → "Abrir no navegador" e aponte a '
                      'câmera deste aparelho para o código.'),
                ),
                OnboardingFeatureRow(
                  icon: Icons.keyboard_rounded,
                  color: c.blue,
                  title: tr('Ou digite a chave mostrada na janela de pareamento:'),
                  body: tr('O texto depois de "Chave:" na janela de pareamento do PC.'),
                  child: TextField(
                    controller: _key,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: type.body.copyWith(color: c.label),
                    decoration: InputDecoration(
                      hintText: tr('Chave'),
                      filled: true,
                      fillColor: c.secondaryGroupedBackground,
                      prefixIcon: Icon(Icons.lock_outline_rounded, color: c.secondaryLabel, size: 18),
                    ),
                    onSubmitted: (_) => _useKey(),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppleSpacing.md),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: type.footnote.copyWith(color: c.red)),
                  ),
                PrimaryButton(
                  label: tr('Conectar'),
                  icon: Icons.link_rounded,
                  expand: true,
                  loading: _busy,
                  onPressed: _useKey,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
