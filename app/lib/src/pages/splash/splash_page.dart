import 'dart:async';

import 'package:deckos/src/connection/browser_url.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/welcome/pairing.dart';
import 'package:deckos/src/connection/constants.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/core/core.dart';
import 'package:deckos/src/welcome/browser_pair_page.dart';
import 'deck_demo.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  SplashPageState createState() => SplashPageState();
}

class SplashPageState extends State<SplashPage> {
  /// Indicador de espera: só aparece se a conexão passar de 600 ms. Abrir rápido não
  /// pisca um spinner na tela.
  bool _slow = false;
  Timer? _slowTimer;

  @override
  void initState() {
    super.initState();
    _slowTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _slow = true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkConfig());
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkConfig() async {
    // Build de demonstração (capturas de tela): abre o deck de exemplo sem PC.
    if (kDeckDemo) {
      Injector.get<DeckOSClient>().setBaseUrl(kIsWeb ? Uri.base.origin : 'http://127.0.0.1:1');
      await seedDeckDemo();
      final route = Uri.base.queryParameters['route'] == 'welcome' ? '/welcome' : '/home';
      if (mounted) Navigator.of(context).pushReplacementNamed(route);
      return;
    }
    if (kIsWeb) {
      // O web é servido pelo próprio PC: no PC a chave vem pelo loopback (sem QR); de
      // outro aparelho, do QR "Abrir no navegador" (?pair=) ou do que ficou salvo.
      final client = Injector.get<DeckOSClient>();
      final signalR = Injector.get<SignalRService>();
      final origin = Uri.base.origin;
      client.setBaseUrl(origin);
      String? key;
      if (WebMode.onPcLoopback) {
        try {
          final resp = await Dio().get('$origin/api/pairing/local-key');
          key = (resp.data is Map) ? resp.data['key'] as String? : null;
        } catch (_) {}
      }
      var rejected = false;
      if (key == null && WebMode.deck) {
        final sp = await SharedPreferences.getInstance();
        final fromUrl = Uri.splitQueryString(Uri.base.fragment)['pair'];
        if (fromUrl != null && fromUrl.isNotEmpty) {
          clearPairingFromUrl();
          try {
            final r = await Dio(BaseOptions(followRedirects: false)).post('$origin/api/pairing/exchange',
              data: {'token': fromUrl, 'name': 'DeckOS browser'});
            await sp.setString(Constants.apiKeyKey, (r.data as Map)['credential'] as String);
          } catch (_) { rejected = true; }
        }
        key = sp.getString(Constants.apiKeyKey);
        if (key != null) {
          client.setApiKey(key);
          if (!await client.checkKey()) {
            await sp.remove(Constants.apiKeyKey);
            key = null;
            rejected = true;
          }
        }
        if (key == null) {
          if (!mounted) return;
          Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => BrowserPairPage(rejected: rejected)));
          return;
        }
      }
      client.setApiKey(key);
      // Conecta em segundo plano para abrir o deck imediatamente sem travar no handshake.
      unawaited(signalR.init(origin, apiKey: key));
      if (mounted) Navigator.of(context).pushReplacementNamed('/home');
      return;
    }
    // Lista de PCs pareados (migra o PC único das versões antigas).
    SavedPc? pc;
    try { pc = await PcStore.current(); }
    catch (_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/welcome');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Secure storage is unavailable. Unlock your phone and restart DeckOS. Your saved data has been kept.'))));
      return;
    }
    if (pc != null && !pc.needsRepair && mounted) {
      await activatePc(pc);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/home');
    } else if (mounted) {
      // Ainda não pareou: explica que precisa do DeckOS no PC antes de pedir o IP.
      Navigator.of(context).pushReplacementNamed('/welcome');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Scaffold(
      backgroundColor: c.background,
      body: Stack(
        alignment: Alignment.center,
        children: [
          // Ícone do app que surge suavemente na abertura.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: AppleMotion.of(context, const Duration(milliseconds: 520)),
            curve: AppleMotion.snappy,
            builder: (context, t, child) => Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.scale(scale: 0.90 + 0.10 * t, child: child),
            ),
            child: Semantics(
              label: 'DeckOS',
              image: true,
              // O logo já traz os próprios cantos transparentes: sem recorte.
              child: Image.asset('assets/images/logo.png', width: 112, height: 112),
            ),
          ),
          Positioned(
            bottom: 96,
            child: AnimatedOpacity(
              opacity: _slow ? 1 : 0,
              duration: AppleMotion.of(context, AppleMotion.normal),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.secondaryLabel,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
