import 'dart:convert';
import 'package:deckos/src/connection/constants.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('migra o PC único das versões antigas, com o deck guardado', () async {
    SharedPreferences.setMockInitialValues({
      Constants.ipAddrKey: '192.168.0.10',
      Constants.portKey: '4787',
      Constants.apiKeyKey: 'abc',
      'deck_cache': '[deck]',
    });
    final list = await PcStore.load();
    expect(list, hasLength(1));
    expect(list.single.ip, '192.168.0.10');
    expect(list.single.apiKey, 'abc');
    expect(list.single.needsRepair, isTrue);
    expect(PcStore.currentId, list.single.id);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PcStore.scoped('deck_cache')), '[deck]');
    expect(prefs.getString(Constants.apiKeyKey), isNull);
    expect(prefs.getString('pcs'), isNot(contains('abc')));
    final repaired = await PcStore.upsert(
      ip: list.single.ip,
      port: '4788',
      apiKey: 'new-credential',
      trustedPin: 'a' * 64,
    );
    expect(repaired.id, list.single.id);
    expect(repaired.needsRepair, isFalse);
    expect(prefs.getString(PcStore.scoped('deck_cache')), '[deck]');
  });

  test(
    'saved certificate or endpoint tampering cannot reuse a device credential',
    () async {
      SharedPreferences.setMockInitialValues({});
      await PcStore.upsert(
        ip: '10.0.0.1',
        port: '4788',
        apiKey: 'credential',
        trustedPin: 'a' * 64,
      );
      final prefs = await SharedPreferences.getInstance();
      final list = jsonDecode(prefs.getString('pcs')!) as List;
      (list.single as Map)['trustedPin'] = 'b' * 64;
      await prefs.setString('pcs', jsonEncode(list));
      final saved = (await PcStore.load()).single;
      expect(saved.needsRepair, isTrue);
      expect(saved.apiKey, isNull);
    },
  );

  test(
    'concurrent saving and loading preserves both PC identities and credentials',
    () async {
      SharedPreferences.setMockInitialValues({});
      await Future.wait([
        PcStore.upsert(ip: '10.0.0.1', port: '4788', apiKey: 'first'),
        PcStore.load(),
        PcStore.upsert(ip: '10.0.0.2', port: '4788', apiKey: 'second'),
      ]);
      final pcs = await PcStore.load();
      expect(pcs.map((pc) => pc.apiKey).toSet(), {'first', 'second'});
      expect(pcs.map((pc) => pc.id).toSet(), hasLength(2));
    },
  );

  test('parear outro PC acrescenta; o mesmo IP atualiza a chave', () async {
    SharedPreferences.setMockInitialValues({});
    final a = await PcStore.upsert(ip: '10.0.0.1', port: '4787', apiKey: 'k1');
    final b = await PcStore.upsert(ip: '10.0.0.2', port: '4787', apiKey: 'k2');
    expect(PcStore.currentId, b.id);
    final again = await PcStore.upsert(
      ip: '10.0.0.1',
      port: '4787',
      apiKey: 'k3',
    );
    expect(again.id, a.id);
    final list = await PcStore.load();
    expect(list, hasLength(2));
    expect(list.firstWhere((p) => p.id == a.id).apiKey, 'k3');
    // O PC em uso vai para as chaves de conexão que o app lê ao abrir.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(Constants.ipAddrKey), '10.0.0.1');
    expect(prefs.getString(Constants.apiKeyKey), isNull);
    expect(prefs.getString('pcs'), isNot(contains('k3')));
  });

  test('esquecer o PC em uso passa para o próximo', () async {
    SharedPreferences.setMockInitialValues({});
    final a = await PcStore.upsert(ip: '10.0.0.1', port: '4787', apiKey: 'k1');
    final b = await PcStore.upsert(ip: '10.0.0.2', port: '4787', apiKey: 'k2');
    await PcStore.remove(b.id);
    expect(PcStore.currentId, a.id);
    expect((await PcStore.load()).map((p) => p.id), [a.id]);
    await PcStore.rename(a.id, 'Notebook');
    expect((await PcStore.current())!.name, 'Notebook');
  });
}
