import 'package:deckos/src/binding/app_binding.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/pages/splash/splash_page.dart';
import 'src/home/home_page.dart';
import 'src/config/config_page.dart';
import 'src/config/keep_awake.dart';
import 'src/welcome/welcome_page.dart';

Future<void> main() async {
  final sw = kDebugMode ? (Stopwatch()..start()) : null;
  WidgetsFlutterBinding.ensureInitialized();
  KeepAwake.ensureInitialized();
  // Carrega tema, idioma, preferência de tela ligada e PCs em paralelo antes do
  // primeiro frame. O canal nativo do wake lock roda após o primeiro frame para não
  // atrasar a abertura.
  await Future.wait([
    ThemeController.instance.load(),
    AppLanguage.load(),
    KeepAwake.load(deferApplyUntilFirstFrame: true),
    if (!kIsWeb) PcStore.load(),
  ]);
  if (sw != null) {
    debugPrint('DeckOS startup preload: ${sw.elapsedMilliseconds} ms');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DeckOSAppConfig(
      title: 'DeckOS',
      bindings: AppBinding(),
      pageBuilders: [
        FlutterGetItPageBuilder(
          page: (_) => const SplashPage(),
          path: '/',
        ),
        FlutterGetItPageBuilder(
          page: (_) => const HomePage(),
          path: '/home',
        ),
        FlutterGetItPageBuilder(
          page: (_) => const ConfigPage(),
          path: '/config',
        ),
        FlutterGetItPageBuilder(
          page: (_) => const WelcomePage(),
          path: '/welcome',
        ),
      ],
    );
  }
}
