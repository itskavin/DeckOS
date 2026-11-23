import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/stream_deck/slider_state_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

void main() {
  tearDown(() async {
    SliderStateStore.resetForTest();
    PcStore.currentId = null;
    await GetIt.I.reset();
  });

  test('serializes slider writes and coalesces intermediate levels behind a slow PUT', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final sent = <int>[];
    final dio = Dio()..interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
      final v = (o.data as Map)['volume'] as int;
      sent.add(v);
      if (sent.length == 1) {
        started.complete();
        await gate.future;
      }
      h.resolve(Response(requestOptions: o, statusCode: 200, data: {'volume': v}));
    }));
    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://pc-a', dio: dio));
    final store = SliderStateStore.instance;
    final first = store.writeVolume('output', const {}, 20);
    await started.future;
    final second = store.writeVolume('output', const {}, 60);
    final last = store.writeVolume('output', const {}, 90);
    expect(sent, [20]);
    expect(store.peek('output', const {})?.volume, 90);
    gate.complete();
    await Future.wait([first, second, last]);
    expect(sent, [20, 90]);
    expect(store.peek('output', const {})?.volume, 90);
  });

  test('late slider response from a previous unsaved PC route is discarded', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final dio = Dio()..interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
      started.complete();
      await gate.future;
      h.resolve(Response(requestOptions: o, statusCode: 200, data: {'volume': 75}));
    }));
    final client = DeckOSClient(baseUrl: 'http://pc-a', dio: dio);
    GetIt.I.registerSingleton<DeckOSClient>(client);
    final store = SliderStateStore.instance;
    final request = store.refresh('output', const {});
    await started.future;
    client.setBaseUrl('http://pc-b');
    gate.complete();
    expect(await request, isNull);
    expect(store.peek('output', const {}), isNull);
  });

  test('a rejected slider PUT surfaces an error and a later live read recovers', () async {
    final dio = Dio()..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      if (o.method == 'PUT') {
        return h.reject(DioException(requestOptions: o, type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 503, data: {'error': 'Output unavailable'})));
      }
      h.resolve(Response(requestOptions: o, statusCode: 200, data: {'volume': 35}));
    }));
    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://pc-a', dio: dio));
    final store = SliderStateStore.instance;
    await store.writeVolume('output', const {}, 80);
    expect(store.peek('output', const {})?.error, 'Output unavailable');
    await store.refresh('output', const {});
    expect(store.peek('output', const {})?.volume, 35);
    expect(store.peek('output', const {})?.error, isNull);
  });
}
