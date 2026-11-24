import 'package:signals_flutter/signals_flutter.dart';

/// Shared in-memory guard also covers already-open dialogs and onboarding previews.
/// Fail closed until the selected PC has supplied its preference.
class AiAccountPrivacy {
  static final hideNames = signal(true);
}
