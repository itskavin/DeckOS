# Sistema de design Apple (DeckOS)

Guia curto para quem redesenha telas. Referência visual: PhoneDeck (phonedeck.io) —
teclas squircle escuras sobre preto, listas no estilo do Ajustes do iPhone, barras de
vidro, títulos grandes.

```dart
import 'package:deckos/core/ui/apple_ui.dart'; // tokens + componentes
import 'package:deckos/core/core.dart';        // tr(), DeckTheme, ThemeController...
```

## Regras

- **Não use números soltos** para cor, espaço, raio ou duração: use os tokens abaixo.
- **Cor vem de `AppleColors.of(context)`**, nunca `Colors.grey`/hex no widget. Funciona
  no claro, no escuro e nos temas antigos (Neon, OLED...).
- **Texto vem de `AppleTextStyles.of(context)`** (`.largeTitle`, `.body`...). Os estilos
  não trazem cor: aplique `copyWith(color: c.secondaryLabel)`.
- **Canto contínuo**: `AppleShapes.squircle(r)` em `ShapeDecoration`/`shape:`, e
  `ClipRSuperellipse` para recortar. Evite `BorderRadius` + `BoxDecoration` em superfícies.
- Todo texto visível passa por `tr('texto em pt')` e precisa de chave em
  `assets/i18n/{en,es,hi}.json` (o teste `i18n_test` cobra). Não escreva `tr('...')`
  em comentário: o teste lê comentários também.
- O tema já deixa os widgets do Material com cara de iOS (sem ripple, transição do iOS,
  switch/slider do iOS, `Card` = grupo do Ajustes, `AppBar` centralizada, bottom sheet
  com alça). Use os componentes daqui quando existirem; Material puro continua ok.

## Tokens

### Cores — `AppleColors.of(context)` (ThemeExtension)

| Campo | Escuro | Claro | Uso |
|---|---|---|---|
| `background` | `#000000` | `#FFFFFF` | fundo de tela comum |
| `groupedBackground` | `#000000` | `#F2F2F7` | fundo de tela com listas agrupadas (= `scaffoldBackgroundColor`) |
| `secondaryGroupedBackground` | `#1C1C1E` | `#FFFFFF` | cartões, grupos de lista, sheets (= `colorScheme.surface`) |
| `tertiaryGroupedBackground` | `#2C2C2E` | `#F2F2F7` | um degrau acima: campos, menus, diálogos |
| `separator` / `opaqueSeparator` | `#545458`@60% / `#38383A` | `#3C3C43`@29% / `#C6C6C8` | linhas finas |
| `label` / `secondaryLabel` / `tertiaryLabel` / `quaternaryLabel` | branco → 60/30/18% | preto → 60/30/18% | hierarquia de texto |
| `fill` / `secondaryFill` / `tertiaryFill` | cinzas translúcidos | idem | trilhos, chips, campo de busca, realce de toque |
| `barBackground` | `#1C1C1E`@78% | `#F9F9F9`@85% | tinta das barras de vidro |
| `accent` / `onAccent` | systemBlue `#0A84FF` | `#007AFF` | destaque (o usuário pode trocar) |
| `blue green red orange yellow pink purple indigo teal gray` | cores de sistema | idem | estados (verde = conectado, vermelho = mudo/erro) |

`AppleSystemColors.blueDark`, `.greenLight`... são as mesmas cores como constantes.
`AppleColors.onColor(c)` devolve preto ou branco legível sobre `c`.

### Espaço — `AppleSpacing`
`xxs 4 · xs 8 · sm 12 · md 16 · lg 20 · xl 24 · xxl 32 · screen 16` (margem lateral).

### Raios — `AppleRadii`
`xs 7` (ícone de linha) · `sm 10` (campo, segmentado) · `md 12` (grupos, cartões,
botões quadrados) · `lg 16` · `xl 22` (diálogos, painéis) · `sheet 20` ·
`tileFactor 0.24` (raio da tecla = lado × 0,24).

### Formas — `AppleShapes`
- `squircle(r, {side})` → `RoundedSuperellipseBorder`
- `topSquircle(r)` → só cantos de cima
- `tileRadius(side)` → raio de uma tecla
- `hairline(color)` → `BorderSide` de 0,5

### Sombras — `AppleShadows`
`card(brightness)` · `floating(brightness)` · `tile` (const).

### Movimento — `AppleMotion`
- Durações: `fast` 120 ms (afundar), `normal` 250 ms (troca de estado), `slow` 400 ms (sheets).
- Curvas de mola: `smooth` (sem quique), `snappy` (quique leve), `bouncy`; `easeOut`.
- `AppleMotion.of(context, d)` → `Duration.zero` com "reduzir movimento" ligado. Use sempre.
- `SpringCurve(bounce: 0.2)` para uma mola sob medida.

### Tipografia — `AppleTextStyles.of(context)`
| estilo | tamanho/peso |
|---|---|
| `largeTitle` | 34 bold |
| `title1` / `title2` / `title3` | 28 bold / 22 bold / 20 semibold |
| `headline` | 17 semibold |
| `body` | 17 |
| `callout` | 16 |
| `subheadline` | 15 |
| `footnote` | 13 |
| `caption1` / `caption2` | 12 / 11 |

Fonte: SF do sistema no iPhone/Mac nativos; `Inter` no Android, Windows e web
(`appleFontFamily()`). O `TextTheme` do Material já foi mapeado nesta escala
(`titleMedium` = headline, `bodyLarge` = body, `bodyMedium` = subheadline,
`bodySmall` = footnote...).

## Componentes

### `DeckSquircleTile` — a tecla do deck
```dart
DeckSquircleTile(
  icon: CupertinoIcons.mic_fill,   // ou image: MemoryImage(bytes), ou child: ...
  label: tr('Microfone'),          // opcional
  color: buttonColor,              // tinge fundo + glifo; cinza/nulo = neutra
  active: muted,                   // pinta de activeColor (padrão: DeckTheme.activeColor)
  onTap: send,
  onLongPress: edit,               // mola 0.94 + vibração leve ao encostar
)
```
`DeckTile` (molecules/deck_tile.dart) já usa esta tecla quando o estilo é
`DeckTileStyle.squircle` (o padrão) — telas que usam `DeckTile` não precisam mudar.
`DeckSquircleEmptyTile` / `DeckEmptyTile` = slot vazio.

### `ApplePressable`
Envolve qualquer coisa tocável: encolhe (`pressedScale`, padrão 0.94) e volta com mola;
`haptic: true` vibra conforme a preferência do usuário.

### `PageDots`
```dart
PageDots(count: pages.length, index: current, onTap: goTo) // cápsula branca na atual
```

### `StatusDot` / `LivePill`
```dart
StatusDot()                                   // verde com halo; color: c.red para offline
LivePill()                                    // "LIVE" verde
LivePill(label: tr('Offline'), color: c.gray)
```

### `GlassPanel` / `GlassBar`
```dart
GlassPanel(padding: EdgeInsets.all(AppleSpacing.md), child: sidebar) // desfoque + tinta + borda fina
Scaffold(extendBody: true, bottomNavigationBar: GlassBar(child: tabs)) // edge: GlassBarEdge.top p/ topo
```

### `InsetGroupedSection` + `ListRow` (+ `ListRowIcon`, `AppleSwitch`)
```dart
InsetGroupedSection(
  header: tr('Aparência'),
  footer: tr('Vale para este aparelho.'),
  children: [
    ListRow(
      leading: ListRowIcon(CupertinoIcons.moon_fill, color: c.indigo),
      title: tr('Tema'),
      value: tr('Escuro'),           // cinza à direita
      onTap: openThemePicker,        // seta aparece sozinha
    ),
    ListRow(
      leading: ListRowIcon(CupertinoIcons.waveform, color: c.pink),
      title: tr('Vibração'),
      trailing: AppleSwitch(value: on, onChanged: set),
    ),
    ListRow(title: tr('Esquecer este PC'), destructive: true, onTap: forget),
  ],
)
```

### `LargeTitleHeader`
```dart
LargeTitleHeader(
  title: tr('Design'),
  subtitle: tr('Toque num espaço vazio para adicionar'),
  trailing: const LivePill(),
  divider: true,
)
```

### `AppleSearchField`
```dart
AppleSearchField(placeholder: tr('Buscar'), onChanged: filter, trailing: Text('$count'))
```

### `SegmentedControl<T>`
```dart
SegmentedControl<ThemeMode>(
  segments: {ThemeMode.system: Text(tr('Sistema')), ThemeMode.dark: Text(tr('Escuro'))},
  value: mode,
  onChanged: setMode,
)
```

### `PrimaryButton` / `SecondaryButton`
Pílulas de 50 de altura (34 com `compact: true`).
```dart
PrimaryButton(label: tr('Parear'), icon: CupertinoIcons.link, onPressed: pair, expand: true)
SecondaryButton(label: tr('Cancelar'), onPressed: close)          // destaque a 15%
PrimaryButton(label: tr('Apagar'), color: c.red, onPressed: del, loading: busy)
```
`onPressed: null` = desabilitado (40% de opacidade).

### `showAppleSheet` / `showAppleDialog`
```dart
await showAppleSheet(context: context, title: tr('Novo botão'), builder: (_) => editor);

final ok = await showAppleDialog<bool>(
  context: context,
  title: tr('Apagar página?'),
  message: tr('Os botões dela somem.'),
  actions: [
    AppleDialogAction(label: tr('Cancelar'), value: false),
    AppleDialogAction(label: tr('Apagar'), value: true, isDestructive: true, isDefault: true),
  ],
);
```

### `EmptyState`
```dart
EmptyState(
  icon: CupertinoIcons.square_grid_2x2,
  title: tr('Nenhum botão'),
  message: tr('Toque em + para criar o primeiro.'),
  action: PrimaryButton(label: tr('Novo botão'), onPressed: add),
)
```

### `PhoneFrame` — espelho ao vivo no configurador
```dart
PhoneFrame(child: DeckGrid(...))        // deitado, 19,5:9, ilha da câmera à esquerda
PhoneFrame(landscape: false, child: ...)
```

### `AppleScrollBehavior`
Já ligado no `MaterialApp` (app_config.dart): rolagem com quique, sem brilho do Android.

## Tema e preferências

- `buildAppTheme(settings, brightness)` (core/theme/app_theme.dart) monta tudo. O tema
  padrão é `kApplePresetId` (`'apple'`, nome "Padrão"): paleta do iOS + tecla squircle.
  Os temas antigos (Clássico, Neon, OLED, Âmbar, Synthwave) continuam, com os mesmos
  componentes do iOS e as cores deles.
- `DeckTileStyle.squircle` é o novo estilo padrão de tecla; `solid`, `outline`,
  `frame` seguem funcionando.
- `kAccentChoices` agora são as cores de sistema do iOS (+ o amarelo DeckOS); no tema
  claro cada uma vira a sua versão clara.
- `ThemeController.instance` (aparência, vibração, `tapFeedback()`) não mudou.
