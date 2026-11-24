import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

import 'settings_kit.dart';

/// Available offline, including before pairing. Keep this notice aligned with
/// the release privacy policy when network transport or SDKs change.
class PrivacyNoticePage extends StatelessWidget {
  const PrivacyNoticePage({super.key});

  static const sections = <(String, String)>[
    (
      'Publisher and contact',
      'DeckOS is published by Bytetrix. For support or privacy questions, '
          'contact contact@kavin.sh. Do not include passwords, pairing keys '
          'or provider credentials in support messages.',
    ),
    (
      'Your phone and PC',
      'DeckOS is a remote for the DeckOS PC companion. The phone sends button '
          'actions, configuration, selected images and pairing credentials to '
          'the PC you choose. It receives profiles, device information and '
          'optional integration or AI account names, aliases and usage data. '
          'DeckOS does not require its own online account.',
    ),
    (
      'Local connection security',
      'This version connects to the PC using unencrypted HTTP and WebSocket '
          'traffic. Pairing keys and settings sent over that connection can be '
          'read by someone monitoring the network. Use only a trusted private '
          'network or a direct USB connection. Do not expose the PC server to '
          'the internet. Account masking changes what is displayed; it does '
          'not encrypt the connection.',
    ),
    (
      'What stays on your devices',
      'Saved PC names, addresses, pairing keys and app preferences are stored '
          'in the phone app storage. Pairing keys are not stored in an Android '
          'hardware-backed credential vault. Android app backup and device '
          'transfer are excluded for this data. The PC stores deck profiles '
          'and integration settings. Supported secret files use Windows '
          'user-account encryption; macOS and Linux use owner-only files '
          'without equivalent encryption. AI usage snapshots are kept in '
          'memory on the phone.',
    ),
    (
      'Camera, images and QR scanning',
      'Camera access is optional and used for QR pairing or integration QR '
          'codes. You can pair by entering the PC address instead. QR images '
          'are processed on the phone by Google ML Kit. Google states that '
          'ML Kit does not send the scanned images or recognition results to '
          'Google. ML Kit does send device and app information, identifiers, '
          'performance and usage diagnostics to Google over HTTPS. Images '
          'you select for deck buttons are sent to your PC.',
    ),
    (
      'Optional services and sharing',
      'Integrations you configure on the PC may contact their providers and '
          'use credentials you supply. Weather uses the configured city. AI '
          'Limits may read supported local CLI usage files, configured local '
          'services or manual entries; availability depends on the source. '
          'DeckOS does not promise access to every provider quota. Exported '
          'profiles, shared links and files can contain your custom content. '
          'Check them before sharing. External websites and share targets '
          'follow their own privacy policies. This app includes no ads or '
          'in-app purchases.',
    ),
    (
      'Removing data',
      'Forget a saved PC to remove its connection from the app. Clear Android '
          'app storage or uninstall to remove remaining phone preferences. '
          'This does not erase data on the PC. Remove integration sources '
          'and credentials on the PC, and separately delete profiles, local '
          'files, logs and any exported backups you no longer need. Third-party '
          'accounts and Google SDK diagnostics follow their providers\' '
          'retention and deletion policies.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final type = AppleTextStyles.of(context);
    final c = AppleColors.of(context);
    return SettingsScaffold(
      title: tr('Privacidade e conexão local'),
      subtitle: 'DeckOS · 24 November 2026',
      children: [
        for (final (heading, body) in sections)
          Padding(
            padding: const EdgeInsets.only(bottom: AppleSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(heading, style: type.headline.copyWith(color: c.label)),
                const SizedBox(height: AppleSpacing.xs),
                SelectableText(
                  body,
                  style: type.body.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
