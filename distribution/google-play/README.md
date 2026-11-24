# Google Play release preparation

**Status: secure transport implemented; real-device migration/release gates pending; not submitted.** A signed bundle is a release candidate, not permission to publish. The owner reports that a developer account has been created; its verification, eligibility and console setup remain to be confirmed. The owner selected the public publisher name **Bytetrix** and support address **contact@kavin.sh**. DeckOS and `io.github.itskavin.deckos` remain unchanged. Version 1.0.0 (11) is the TLS implementation candidate; version 10 remains transport-blocked and must not be uploaded. No candidate is upload-ready. The package name is not reserved until Play accepts creation/upload.

## Build and signing

Use Java 21 and Flutter 3.50.0. From the repository root:

```powershell
./scripts/build-play-bundle.ps1 -VersionCode 11 -OutputDirectory C:\private-artifacts\deckos
```

Supply `ANDROID_KEYSTORE_PATH`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` privately to that process. Alternatively, ignored `app/android/key.properties` accepts `storeFile`, `storePassword`, `keyAlias`, `keyPassword`; a relative `storeFile` resolves from `app/android/app`. Prefer an absolute private path using forward slashes in properties files. Do not put secrets in command-line arguments, Git, issue bodies or build logs. Gradle rejects missing or partial release signing; debug signing is never a fallback. A deliberately unsigned, non-uploadable candidate requires the script's `-Unsigned` option and no signing configuration.

The manually dispatched **Play bundle (build only)** workflow builds a signed AAB from four GitHub Actions secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Configure them only in the intended owner's repository. It validates inputs, runs analyzer/tests, verifies the JAR signature, and retains the AAB and separate Dart symbols for 14 days. It does not upload to Play or create a GitHub release. The older general Release workflow also now requires upload signing and uses the version in pubspec rather than a workflow run counter. Bump pubspec before each subsequent release; Play version codes must increase across all tracks.

New-app upload key creation was coordinated with the owner through the parent task. The private key/password remain outside this checkout in the Windows owner's private signing directory. The owner must preserve the password in a password manager and the key in encrypted off-machine storage. A secondary copy on the same disk is not disaster recovery. Google Play App Signing enrollment and upload-certificate registration still require the actual account. Never replace a key for an existing app without first confirming certificate ownership and the official reset process.

## Release gates

1. Validate the implemented secure transport on the existing real Android phone and manually updated Windows companion, preserving data. Source/loopback tests pass; they do not prove physical QR, Android Keystore, USB or LAN/firewall behavior. See `transport-handoff.md`.
2. Update and publish the staged privacy policy only after transport behavior is final. Its current HTTP disclosure is accurate to this candidate. Keep the in-app notice, listing, policy and Data safety answers consistent.
3. Confirm the owner-created developer account and complete any remaining identity/contact/device verification and app creation as the owner. Do not invent account details. Enroll in Play App Signing using the new app's actual choices.
4. Supply complete reviewer access to the companion and the app's functions. See `reviewer-access.md`. No reviewer backend or test account is provisioned by this change.
5. Complete App content, Data safety, target audience, IARC content rating and any declarations shown for the final merged manifest. See `data-safety.md`. These are draft answers for owner review, not submitted declarations.
6. For a new personal developer account, fulfill the closed-testing requirement shown by the console, gather real engagement and feedback, and apply for production access. Internal testing is not a substitute. Do not promise an approval date.
7. Rebuild after transport changes, recheck target SDK, manifest, all native libraries, bundle signatures and asset privacy, then upload to the selected test track. Run pre-launch testing and resolve findings before production review.

Camera hardware is optional because the full secure pairing code can be copied manually from the PC. Android credentials now use Keystore-protected encrypted storage, with endpoint/fingerprint binding and fail-closed migration. Cloud backup and device transfer remain excluded. Legacy PCs retain their IDs/caches and require one secure re-pairing.

## Store files and truthful claims

`en-US/` holds the name, <=80-character short description, full description and initial candidate notes. `store-settings.json` records the owner-provided public contact. `graphics/` contains the supplied DeckOS 512px icon, a 1024x500 feature graphic, and actual sanitized app captures. See `graphics/provenance.json` for capture origins and margin-only adjustments. No personal account names, email addresses, pairing QR codes or keys are used in these graphics. AI values are actual captured source states, including unavailable states, not simulated subscription guarantees.

The remote requires a PC companion. The listing does not promise native PC apps on Android or physically verified macOS/Linux desktop behavior. Integrations may require third-party accounts or licenses. This TLS-only candidate has no paid tier, app account system, billing SDK or ad SDK. The owner selected subscription monetization; its separate implementation/configuration must receive a new candidate and updated privacy/Data safety disclosures before release.

## Current official references (checked 24 November 2026)

New phone apps and updates must target API 36 under [Google Play's target API requirements](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en). This candidate uses compile/target 36, min 24, NDK 28.2.13676358 and AGP 9.3.1.

Check both native ELF LOAD segment alignment and APK ZIP alignment for 64-bit native libraries, plus the bundle's page-alignment configuration, following [Android's 16KB guidance](https://developer.android.com/guide/practices/page-sizes). A successful build alone does not prove native compatibility or execution on a 16KB device.

The [Data safety guidance](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en) covers SDK and off-device handling, including ephemeral processing. [ML Kit's Android disclosure](https://developers.google.com/ml-kit/android-data-disclosure) describes metrics and installation identifiers for bundled barcode scanning; [ML Kit privacy terms](https://developers.google.com/ml-kit/terms) distinguish on-device image processing from SDK metrics. See the separate data-flow inventory before completing the form.

The [User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en) requires accurate privacy disclosures and secure handling of sensitive data. Use [preview asset requirements](https://support.google.com/googleplay/android-developer/answer/9866151?hl=en) for final graphic validation and [review access requirements](https://support.google.com/googleplay/android-developer/answer/15748846?hl=en) for the companion-dependent functions.

For newly created personal accounts, the [current testing requirements](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en) require at least 12 testers continuously opted into a closed test for 14 consecutive days before applying for production access; meeting that threshold does not automatically grant approval.
