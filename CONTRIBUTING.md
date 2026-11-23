# Contributing to DeckOS

Thanks for wanting to help! DeckOS has two halves that live in this repository: the Windows app
(`DeckOS/`, C# / .NET 8) and the phone app plus web configurator (`app/`, Flutter).

## Good ways to start

- **Translate.** Each language is one file in [`app/assets/i18n/`](app/assets/i18n/), shared by the
  phone app, the web configurator and the Windows app. To add one, copy `en.json` to `<code>.json`
  (`fr.json`, `de.json`...), set `@language` to the language's own name, `@locale` and `@decimal`, and
  translate the values. Keep the keys and the `{placeholders}` as they are; the keys are the
  Portuguese text used in the code, the English values show what each one means. Nothing else needs
  to change: the new language shows up in Appearance → Language and is picked automatically on
  phones set to it. A partial file is fine: anything you haven't translated yet appears in English.
  No Flutter or C# experience needed.
- **Issues labelled [`good first issue`](https://github.com/itskavin/DeckOS/labels/good%20first%20issue)**
  are small and self-contained.
- **A new action type** usually needs only C#: implement `IActionProvider` and the phone builds the
  editor from its schema. See [Architecture](https://itskavin.github.io/DeckOS/docs/developers/architecture/).

Not sure where something goes? Ask in [Discussions](https://github.com/itskavin/DeckOS/discussions).

## Building and testing

```powershell
dotnet test tests/DeckOS.Tests          # backend tests
dotnet run --project DeckOS             # tray app + server at http://localhost:4787

cd app
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
```

More in [Building from source](https://itskavin.github.io/DeckOS/docs/developers/building/).

## Pull requests

- Commits follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`,
  `docs:`…): releases and the changelog are generated from them.
- Keep `dotnet test`, `flutter analyze` and `flutter test` green; CI runs all three.
- User-facing text goes through `tr("…")` in the app and `L.T("…")` on the PC, so it can be translated.
- Actions that run code or reach the network from the PC (like launching apps or calling URLs) must be
  listed as privileged in `ActionPolicy`.
