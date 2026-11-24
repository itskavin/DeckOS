import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show DeviceGestureSettings;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:deckos/src/connection/browser_url.dart';
import 'package:deckos/src/connection/constants.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'home_controller.dart';
import 'home_nav.dart';
import 'audio_page.dart';
import 'mixer_page.dart' show MixerLoading;
import '../pages/splash/deck_demo.dart';
import '../stream_deck/stream_deck_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final controller = HomeController();
  // Abre no Deck (é para isso que se abre o app); lembra a última aba usada.
  static const _tabKey = 'home_tab';

  PageController _pageController = PageController(initialPage: 1);
  final GlobalKey _bodyKey = GlobalKey();
  int selectedIndex = 1;

  /// Controles do deck visíveis agora; quando somem por inatividade, a barra de abas some junto.
  bool _deckChromeVisible = !(kDeckDemo && Uri.base.queryParameters['chrome'] != '1');

  /// Aba do deck à mostra: a barra de status some nela.
  final _deckTab = signal(true);
  void Function()? _deckOnlyCleanup;

  @override
  void initState() {
    super.initState();
    // Modo só deck abre em tela cheia (e sai dela quando é desligado). Roda já na
    // primeira vez, com o valor carregado no startup.
    _deckOnlyCleanup = effect(() {
      final deckOnly = ThemeController.instance.deckOnly.value;
      untracked(() {
        controller.isFullscreen.value = deckOnly;
        if (deckOnly) {
          _deckChromeVisible = true;
        } else if (!_pageController.hasClients &&
            _pageController.initialPage != selectedIndex) {
          final old = _pageController;
          _pageController = PageController(initialPage: selectedIndex);
          old.dispose();
        }
      });
    });
    // No web o foco é configurar o deck; não precisa do polling de mixer.
    if (kDeckDemo) {
      controller.outputs.value = demoOutputs();
      controller.inputs.value = demoInputs();
      controller.mediaSessions.value = demoMedia();
    } else if (WebMode.isDevice) {
      controller.startPolling();
    }
    SharedPreferences.getInstance().then((sp) {
      final tab = sp.getInt(_tabKey);
      if (tab != null && tab != selectedIndex && mounted) {
        if (_pageController.hasClients) {
          setState(() => selectedIndex = tab);
          _deckTab.value = tab == 1;
          _pageController.jumpToPage(tab);
        } else {
          final old = _pageController;
          _pageController = PageController(initialPage: tab);
          old.dispose();
          setState(() => selectedIndex = tab);
          _deckTab.value = tab == 1;
        }
      }
    });
  }

  @override
  void dispose() {
    _deckOnlyCleanup?.call();
    controller.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onDeckChromeChanged(bool visible) {
    if (!mounted || _deckChromeVisible == visible) return;
    setState(() => _deckChromeVisible = visible);
  }

  /// Abas: Áudio e Deck (o texto passa pelo tr).
  static const _tabs = [
    HomeNavDestination(index: 0, icon: Icons.tune_rounded, labelKey: 'Áudio'),
    HomeNavDestination(index: 1, icon: Icons.grid_view_rounded, labelKey: 'Deck'),
  ];

  @override
  Widget build(BuildContext context) {
    // No navegador (configurador no PC), abre direto no editor de deck.
    if (WebMode.configurator) {
      return StreamDeckPage(
        onToggleFullscreen: () {},
        isFullscreen: false,
      );
    }

    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final textScale = HomeNavMetrics.textScaleOf(context);
    final landscape = size.width > size.height && size.height < 600;
    final portraitInset = HomeNavMetrics.portraitInset(safe.bottom, textScale);
    final landscapeInset = HomeNavMetrics.landscapeInset(safe.left, textScale);

    final body = KeyedSubtree(
      key: _bodyKey,
      child: Watch((context) {
        final deckOnly = ThemeController.instance.deckOnly.value;
        final isFullscreen = controller.isFullscreen.value;
        final err = controller.error.value ?? '';
        // 401/403 = pareamento inválido: retry só falha de novo. Oferece voltar
        // ao pareamento para não prender o usuário nesta tela. Outros erros (PC
        // desligado) não bloqueiam: o deck abre com o último perfil salvo.
        final isAuthError = err.contains('401') || err.contains('403') || err.contains('HandshakeException') || err.contains('CERTIFICATE_VERIFY_FAILED');
        if (isAuthError) {
          return Container(
            color: AppleColors.of(context).groupedBackground,
            child: EmptyState(
              icon: Icons.lock_outline_rounded,
              title: tr('Pareie de novo'),
              message: tr(
                  'O PC não reconheceu este aparelho (a chave mudou ou é de outro PC).\nPareie de novo pelo QR.'),
              action: PrimaryButton(
                label: tr('Refazer pareamento'),
                icon: Icons.qr_code_scanner_rounded,
                onPressed: () async {
                  // No navegador, refazer é esquecer a chave e voltar à tela do QR.
                  if (kIsWeb) {
                    await (await SharedPreferences.getInstance())
                        .remove(Constants.apiKeyKey);
                  }
                  if (!context.mounted) return;
                  Navigator.of(context)
                      .pushReplacementNamed(kIsWeb ? '/' : '/config');
                },
              ),
            ),
          );
        }

        // Deck à mostra (aba do deck, só deck ou tela cheia): modo imersivo.
        if (kIsWeb) setBrowserFullscreen(isFullscreen);
        if (isFullscreen || deckOnly || _deckTab.value) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        } else {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        }

        if (deckOnly) {
          return StreamDeckPage(
            onToggleFullscreen: controller.toggleFullscreen,
            isFullscreen: isFullscreen,
            onChromeVisibilityChanged: _onDeckChromeChanged,
          );
        }

        final showNavStructure = !isFullscreen;
        final audioLoading =
            controller.isLoading.value && controller.outputs.value.isEmpty;

        // A espera do mixer fica restrita à aba de Áudio: o Deck abre na hora do cache.
        // Em retrato a lista rola por trás da pílula translúcida com folga no fim; em
        // paisagem o trilho compacto reserva só a margem lateral necessária sem duplicar
        // a área segura da esquerda no SafeArea interno do AudioPage.
        final reserveLeft = landscape && showNavStructure;
        final Widget audioTab = MediaQuery.removePadding(
          context: context,
          removeLeft: reserveLeft,
          child: Padding(
            padding: EdgeInsets.only(
              left: reserveLeft ? landscapeInset : 0,
            ),
            child: audioLoading
                ? const MixerLoading()
                : Column(
                    children: [
                      if (err.isNotEmpty)
                        _AudioOfflineBanner(onRetry: controller.fetchOutputs),
                      Expanded(
                        child: AudioPage(
                          controller: controller,
                          isFullscreen: isFullscreen,
                          onToggleFullscreen: controller.toggleFullscreen,
                          bottomNavClearance:
                              (!landscape && showNavStructure) ? portraitInset : 0,
                        ),
                      ),
                    ],
                  ),
          ),
        );

        final baseMedia = MediaQuery.of(context);
        final deckTouchSlop = math.max(
          baseMedia.gestureSettings.touchSlop ?? 0,
          kDeckTouchSlop,
        );
        return MediaQuery(
          data: baseMedia.copyWith(
            gestureSettings: DeviceGestureSettings(touchSlop: deckTouchSlop),
          ),
          child: PageView(
            controller: _pageController,
            physics: const DeckPagePhysics(),
            onPageChanged: (index) {
              setState(() {
                selectedIndex = index;
              });
              _deckTab.value = index == 1;
              SharedPreferences.getInstance().then((sp) => sp.setInt(_tabKey, index));
            },
            children: [
              MediaQuery(data: baseMedia, child: audioTab),
              StreamDeckPage(
                onToggleFullscreen: controller.toggleFullscreen,
                isFullscreen: isFullscreen,
                onChromeVisibilityChanged: _onDeckChromeChanged,
                bottomNavInset:
                    (!landscape && showNavStructure) ? portraitInset : 0,
                leftNavInset:
                    (landscape && showNavStructure) ? landscapeInset : 0,
              ),
            ],
          ),
        );
      }),
    );

    // Positioned.fill fica sempre como filho direto do Stack (nunca devolvemos
    // SizedBox.shrink() solto como único filho não-posicionado, senão o Stack
    // encolhe para 0×0 em modo Só o deck / tela cheia e deixa a tela preta).
    final navOverlay = Positioned.fill(
      child: Watch((context) {
        final isFullscreen = controller.isFullscreen.value;
        final deckOnly = ThemeController.instance.deckOnly.value;
        if (isFullscreen || deckOnly) return const SizedBox.shrink();

        // Na aba de Áudio a barra fica sempre visível (exceto sob teclado virtual em retrato);
        // no Deck acompanha a inatividade de 5 s sem deixar alvos fantasmas.
        final visible = (selectedIndex == 0 || _deckChromeVisible) &&
            (!keyboardOpen || landscape);
        final slideDuration = AppleMotion.of(context, AppleMotion.slow);
        final fadeDuration = AppleMotion.of(context, AppleMotion.normal);

        if (!landscape) {
          return Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(
                left: HomeNavMetrics.portraitHorizontalMargin,
                right: HomeNavMetrics.portraitHorizontalMargin,
                bottom: safe.bottom + HomeNavMetrics.portraitBottomMargin,
              ),
              child: IgnorePointer(
                ignoring: !visible,
                child: AnimatedSlide(
                  offset: visible ? Offset.zero : const Offset(0, 1.35),
                  duration: slideDuration,
                  curve: AppleMotion.smooth,
                  child: AnimatedOpacity(
                    opacity: visible ? 1 : 0,
                    duration: fadeDuration,
                    child: HomeBottomPillNav(
                      key: const ValueKey('home-bottom-nav'),
                      destinations: _tabs,
                      selectedIndex: selectedIndex,
                      onSelected: _goToTab,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        // Celular deitado: cápsula lateral enxuta centrada verticalmente, sobreposta sem
        // empurrar nem redimensionar as teclas.
        return Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(
              top: safe.top + AppleSpacing.xs,
              bottom: safe.bottom + AppleSpacing.xs,
              left: HomeNavMetrics.sideRailLeft(safe.left),
            ),
            child: IgnorePointer(
              ignoring: !visible,
              child: AnimatedSlide(
                offset: visible ? Offset.zero : const Offset(-1.5, 0),
                duration: slideDuration,
                curve: AppleMotion.smooth,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: fadeDuration,
                  child: SingleChildScrollView(
                    clipBehavior: Clip.none,
                    physics: const ClampingScrollPhysics(),
                    child: HomeSidePillNav(
                      key: const ValueKey('home-side-nav'),
                      destinations: _tabs,
                      selectedIndex: selectedIndex,
                      onSelected: _goToTab,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );

    // Stack(fit: expand) mantém o tamanho do corpo constante e sempre em tela cheia
    // mesmo quando o overlay de navegação é ocultado (tela cheia / Só o deck).
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          body,
          navOverlay,
        ],
      ),
    );
  }

  void _goToTab(int val) {
    final d = AppleMotion.of(context, AppleMotion.slow);
    if (_pageController.hasClients) {
      if (d == Duration.zero) {
        _pageController.jumpToPage(val);
      } else {
        _pageController.animateToPage(val, duration: d, curve: AppleMotion.smooth);
      }
    }
    setState(() => selectedIndex = val);
    _deckTab.value = val == 1;
    SharedPreferences.getInstance().then((sp) => sp.setInt(_tabKey, val));
  }
}

/// O PC não respondeu ao pedir o mixer: aviso discreto no topo com "tentar de novo".
class _AudioOfflineBanner extends StatelessWidget {
  const _AudioOfflineBanner({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return ColoredBox(
      color: c.groupedBackground,
      child: SafeArea(
        bottom: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(
              AppleSpacing.md, AppleSpacing.xs, AppleSpacing.md, 0),
          padding: const EdgeInsets.only(left: AppleSpacing.sm),
          decoration: BoxDecoration(
            color: c.orange.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppleRadii.md),
            border: Border.all(color: c.orange.withValues(alpha: 0.28), width: 1),
          ),
          child: Row(
            children: [
              Icon(Icons.wifi_off_rounded, size: 18, color: c.orange),
              const SizedBox(width: AppleSpacing.xs),
              Expanded(
                child: Text(
                  tr('O PC não respondeu. Confira se o DeckOS está aberto nele.'),
                  style: type.footnote.copyWith(color: c.label),
                ),
              ),
              TextButton(onPressed: onRetry, child: Text(tr('Tentar novamente'))),
            ],
          ),
        ),
      ),
    );
  }
}
