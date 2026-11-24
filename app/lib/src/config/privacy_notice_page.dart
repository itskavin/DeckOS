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
      'The phone uses HTTPS and secure WebSockets to reach your paired PC. '
          'Scanning or copying a fresh code from the PC verifies its certificate '
          'before a one-time pairing token or device credential is sent. Codes '
          'expire after three minutes. Each device has a revocable credential; '
          'a changed certificate requires a new verified pairing. Old HTTP PCs '
          'require secure re-pairing without removing profiles or preferences. '
          'USB forwarding uses the same TLS identity. The same-PC browser '
          'configurator uses loopback HTTP; browser LAN access needs a certificate '
          'trusted by that browser. Account masking changes the display only.',
    ),
    (
      'What stays on your devices',
      'Saved PC names, addresses, pairing keys and app preferences are stored '
          'in the phone app storage. Device credentials are encrypted using an Android '
          'Keystore-protected key, with no plaintext fallback. Android app backup and device '
          'transfer are excluded for this data. The PC stores deck profiles '
          'and integration settings. Supported secret files use Windows '
          'user-account encryption; macOS and Linux use owner-only files '
          'without equivalent encryption. AI usage snapshots are kept in '
          'memory on the phone.',
    ),
    (
      'Camera, images and QR scanning',
      'Camera access is optional and used for QR pairing or integration QR '
          'codes. You can pair by copying the complete secure code from the PC instead. QR images '
          'are processed on the phone by Google ML Kit. Google states that '
          'ML Kit does not send the scanned images or recognition results to '
          'Google. ML Kit does send device and app information, identifiers, '
          'performance and usage diagnostics to Google over HTTPS. Images '
          'you select for deck buttons are sent to your PC.',
    ),
    (
      'Optional services and sharing',
      'Integrations you configure on the PC may contact their providers and '
          'use credentials you supply. Their transport depends on your configuration; '
          'some local integrations may use HTTP. Weather uses the configured city. AI '
          'Limits may read supported local CLI usage files, configured local '
          'services or manual entries; availability depends on the source. '
          'DeckOS does not promise access to every provider quota. Exported '
          'profiles, shared links and files can contain your custom content. '
          'Check them before sharing. External websites and share targets '
          'follow their own privacy policies. This app includes no ads.',
    ),
    (
      'Google Play subscriptions',
      'The app includes Google Play Billing, but subscriptions are not available '
          'in this build. DeckOS does not start a billing connection, create a '
          'billing identifier or send purchase tokens to a verification service '
          'while billing is unconfigured. Managing subscriptions opens Google Play '
          'in an external app or browser under Google\'s policies. If billing is '
          'enabled in a future version, Play will handle checkout; DeckOS will use '
          'an opaque installation identifier, purchase token, product and subscription '
          'status to verify access with a trusted HTTPS service. An opaque identifier '
          'is linkable data, not a guarantee of anonymity. That release will need '
          'updated retention, recovery and privacy details. DeckOS does not receive '
          'your payment card details from Play.',
    ),
    (
      'Removing data',
      'Forget a saved PC to remove its connection from the app. Clear Android '
          'app storage or uninstall to remove remaining phone preferences. '
          'This does not erase data on the PC. In the same-PC configurator, revoke paired '
          'devices to stop their current and future connections. Remove integration sources '
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
