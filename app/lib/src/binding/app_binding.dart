import 'package:deckos/core/core.dart';
import '../services/signalr_service.dart';

class AppBinding extends ApplicationBindings {
  @override
  List<Bind<Object>> bindings() => [
        Bind.lazySingleton<DeckOSClient>((i) => DeckOSClient(baseUrl: '')
          ..onConnectionRefused =
              (url, key) => Injector.get<SignalRService>().rerouteFromUsb(url, key)),
        Bind.lazySingleton<SignalRService>((i) => SignalRService()),
      ];
}
