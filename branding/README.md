# DeckOS brand assets

`source/deckos-logo-source.png` is the logo exactly as the owner supplied it (653×648, RGB, 2026-11-22).
Every DeckOS icon is generated from that file. Nothing is redrawn or recoloured:

```sh
python -I branding/generate.py   # from the repo root; needs Pillow
```

Rerunning the script rewrites every file listed below. It gives the same output each time.

## Files here

| File | What it is |
| --- | --- |
| `source/deckos-logo-source.png` | The original. Don't edit it; replace it to change the logo, then rerun the script. |
| `deckos-logo.png` | 1024 px master: the rounded plate on a transparent background. Use this anywhere the logo stands on its own. |
| `deckos-logo-256.png` | The same at 256 px, for the README. |
| `deckos-icon-1024.png`, `deckos-icon-512.png` | Opaque square icons for stores (App Store 1024, Play Store 512). The store applies its own rounded mask. |
| `generate.py` | The generator. |

## How the variants are made

- **Transparent logo:** the dark background around the plate is removed. A flood fill from the
  image edge stops at the plate's light outline. The outline and its anti-aliasing are kept.
- **Full-bleed icons** (Android adaptive, iOS, Play/App Store, web maskable): these platforms apply
  their own mask, so the plate can't carry its rounded corners. The plate's diagonal graphite
  gradient is fitted to the source (mean error about 1/255) and extended under the plate. The
  plate's interior goes on top, with the grid and glow untouched. The outline itself is
  dropped, since the platform's mask replaces it.
- **Safe zones:** the visible square is 1.08× the plate. On Android this puts the 3×3 grid at
  about 44 of 72 dp, inside the 66 dp circle. The web maskable icon uses 1.2×, so the grid fits
  the central 80% circle.
- **Sizes of 48 px and below** get a light unsharp mask on colour only, to keep the grid readable
  in the tray and favicons.

## Where the logo is used

| Surface | Files |
| --- | --- |
| Flutter app (splash, onboarding, browser pairing) | `app/assets/images/logo.png` (512 px, the one in-app path) |
| Android launcher | `app/android/app/src/main/res/mipmap-*/ic_launcher{,_round,_foreground,_background}.png`, `mipmap-anydpi-v26/ic_launcher{,_round}.xml` |
| Android splash (below 12) | `drawable-*/launch_logo.png` via `drawable{,-v21}/launch_background.xml`. Android 12+ shows the adaptive icon. |
| iOS | `app/ios/Runner/Assets.xcassets/AppIcon.appiconset/*`, `LaunchImage.imageset/*` (112 pt) |
| macOS app | `app/macos/Runner/Assets.xcassets/AppIcon.appiconset/*` (824/1024 grid) |
| macOS server `.app` | `.github/workflows/release.yml` builds its `.icns` from the macOS `app_icon_1024.png` |
| Windows PC app (exe, tray, windows, installer) | `DeckOS/deckos.ico`, `DeckOS/frmPrincipal.resx` designer icons |
| Windows Flutter runner | `app/windows/runner/resources/app_icon.ico` |
| Web configurator | `app/web/favicon.png`, `app/web/icons/*` |
| Website | `site/{logo,favicon-32,icon-512,icon-maskable-512,apple-touch-icon}.png`, header of `site/og.png` |
| Legacy landing pages and docs | `website/landing/logo.png`, `website/docs/assets/logo.png` |
| README | `branding/deckos-logo-256.png` |

Deck tiles, action icons and app icons in the deck are not brand assets. Nothing here touches them.
