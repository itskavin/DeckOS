import 'package:deckos/src/connection/pc_store.dart';
import 'dart:convert';

import 'package:deckos/core/core.dart'; // Contains DeckOSClient, DeckProfile, etc.
import 'package:deckos/src/stream_deck/actions/action_catalog.dart';
import 'package:deckos/src/stream_deck/layout/deck_history.dart';
import 'package:deckos/src/stream_deck/layout/grid_placement.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemDeckCacheEntry {
  _MemDeckCacheEntry(this.client, this.profiles, this.lastProfileId);
  final WeakReference<DeckOSClient> client;
  final List<DeckProfile> profiles;
  final String? lastProfileId;
}

class StreamDeckController {
  StreamDeckController() {
    _hydrateFromMemory();
  }

  final DeckOSClient _client = Injector.get<DeckOSClient>();

  // Bounded in-memory cache (per PC + client instance) so switching Audio <-> Deck
  // renders the last profiles and selected page on frame 0 without flashing a spinner.
  static const int _maxMemCacheEntries = 4;
  static final Map<String, _MemDeckCacheEntry> _memCache = {};

  @visibleForTesting
  static void clearMemoryCacheForTest() => _memCache.clear();

  // Signals state
  final isLoading = signal(false);
  final error = signal<String?>(null);
  final profiles = signal<List<DeckProfile>>([]);
  final currentProfile = signal<DeckProfile?>(null);

  /// Mostrando o último deck salvo no aparelho porque o PC não respondeu.
  final offline = signal(false);

  /// Desfazer/refazer das edições desta sessão (o configurador usa).
  final history = DeckHistory();

  bool _hasLiveProfiles = false;
  Future<void>? _loadInFlight;
  bool _reloadQueued = false;

  /// True once a network `getProfiles()` succeeded in this controller lifecycle.
  bool get hasLiveProfiles => _hasLiveProfiles;

  // Cada PC pareado tem o seu deck guardado.
  static String get _cacheKey => PcStore.scoped('deck_cache');
  static String get _lastProfileKey => PcStore.scoped('deck_last_profile');

  void _hydrateFromMemory() {
    if (WebMode.configurator) return;
    final entry = _memCache[_cacheKey];
    if (entry == null || !identical(entry.client.target, _client)) return;
    if (entry.profiles.isEmpty) return;
    profiles.value = List<DeckProfile>.from(entry.profiles);
    final last = entry.lastProfileId;
    currentProfile.value = entry.profiles.firstWhere(
      (p) => p.id == last,
      orElse: () => entry.profiles.first,
    );
  }

  void _updateMemoryCache(List<DeckProfile> list, {String? lastProfileId}) {
    if (WebMode.configurator) return;
    final key = _cacheKey;
    final prev = _memCache.remove(key);
    final remembered = lastProfileId ??
        currentProfile.value?.id ??
        (identical(prev?.client.target, _client) ? prev?.lastProfileId : null);
    _memCache[key] = _MemDeckCacheEntry(
      WeakReference<DeckOSClient>(_client),
      List<DeckProfile>.from(list),
      remembered,
    );
    while (_memCache.length > _maxMemCacheEntries) {
      _memCache.remove(_memCache.keys.first);
    }
  }

  Future<void> loadProfiles() {
    final existing = _loadInFlight;
    if (existing != null) {
      _reloadQueued = true;
      return existing;
    }
    final task = _runLoadLoop().whenComplete(() => _loadInFlight = null);
    _loadInFlight = task;
    return task;
  }

  Future<void> _runLoadLoop() async {
    do {
      _reloadQueued = false;
      await _loadProfilesOnce();
    } while (_reloadQueued);
  }

  Future<void> _loadProfilesOnce() async {
    // Primeira carga: mostra na hora o último deck salvo; o do PC substitui quando chegar.
    // Com o PC desligado (sem "connection refused"), a espera pode passar de 20 s.
    if (profiles.value.isEmpty) {
      final cached = await _loadCache();
      if (cached.isNotEmpty && profiles.value.isEmpty) {
        profiles.value = cached;
        await _selectInitial(cached);
        _updateMemoryCache(cached);
      }
    }
    try {
      isLoading.value = profiles.value.isEmpty;
      error.value = null;
      final result = await _applyPageOrder(await _client.getProfiles());
      profiles.value = result;
      offline.value = false;
      _hasLiveProfiles = true;
      // Se o app abriu sem o PC, o catálogo de ações (e os estados ao vivo que ele
      // assina, como os timers) ainda não carregou: tenta agora. Já carregado = nada.
      ActionCatalog.instance.load();
      await _selectInitial(result);
      _updateMemoryCache(result);
      _saveCache(result);
    } catch (e) {
      error.value = e.toString();
      // Sem PC: fica o último deck que o aparelho viu (carregado acima), avisando.
      offline.value = profiles.value.isNotEmpty;
    } finally {
      isLoading.value = false;
    }
  }

  /// Abre no perfil em que o usuário estava da última vez (ou mantém o atual).
  Future<void> _selectInitial(List<DeckProfile> list) async {
    if (list.isEmpty) return;
    final current = currentProfile.value;
    if (current != null) {
      // Recarga: pega a versão nova do mesmo perfil.
      currentProfile.value =
          list.firstWhere((p) => p.id == current.id, orElse: () => list.first);
      return;
    }
    String? last;
    try {
      last = (await SharedPreferences.getInstance()).getString(_lastProfileKey);
    } catch (_) {}
    currentProfile.value =
        list.firstWhere((p) => p.id == last, orElse: () => list.first);
  }

  /// Lembra o perfil visível para abrir nele da próxima vez.
  Future<void> rememberProfile(String id) async {
    if (profiles.value.isNotEmpty) {
      _updateMemoryCache(profiles.value, lastProfileId: id);
    }
    try {
      await (await SharedPreferences.getInstance()).setString(_lastProfileKey, id);
    } catch (_) {}
  }

  Future<void> _saveCache(List<DeckProfile> list) async {
    if (WebMode.configurator) return; // o configurador roda no próprio PC
    try {
      final json = jsonEncode(list.map((p) => p.toJson()).toList());
      await (await SharedPreferences.getInstance()).setString(_cacheKey, json);
    } catch (_) {}
  }

  Future<List<DeckProfile>> _loadCache() async {
    if (WebMode.configurator) return const [];
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_cacheKey);
      if (raw == null) return const [];
      return (jsonDecode(raw) as List)
          .map((e) => DeckProfile.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Executa a ação de um gesto ('tap', 'longPress', 'doubleTap'). Devolve false se o
  /// PC não respondeu, para a tela avisar.
  Future<bool> executeButtonAction(DeckButton button,
      {String gesture = 'tap', ValueChanged<String>? onFailure}) async {
    // Botão de dois estados vai ao PC mesmo sem ação: o toque alterna o estado lá.
    final toggles = gesture == 'tap' && button.toggle;
    if (button.actionFor(gesture) == null && !toggles) return true;

    // O PC executa a ação salva no perfil, pelo id do botão: o celular não escolhe o
    // que roda. Procura o perfil dono do botão (a página atual, ou uma pasta aberta).
    final current = currentProfile.value;
    final owner = current != null && current.buttons.any((b) => b.id == button.id)
        ? current
        : profiles.value
            .where((p) => p.buttons.any((b) => b.id == button.id))
            .firstOrNull;
    if (owner == null) return true;

    try {
      await _client.pressButton(owner.id, button.id, gesture: gesture);
      return true;
    } catch (e) {
      debugPrint('Error executing action: $e');
      if (e is DioException && e.response != null) {
        // O PC respondeu, mas o botão não existe mais lá: o deck daqui está velho.
        if (e.response!.statusCode == 404) loadProfiles();
        onFailure?.call(tr('O PC recebeu o toque, mas não conseguiu executar a ação. Confira a configuração e as permissões.'));
        return false;
      }
      onFailure?.call(tr('O PC não respondeu. Confira se o DeckOS está aberto nele.'));
      return false;
    }
  }

  /// Mensagem que o PC mandou ao recusar o pedido (403), se houver.
  static String? _forbiddenMessage(Object e) {
    if (e is! DioException || e.response?.statusCode != 403) return null;
    final data = e.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    return tr('O PC recusou a alteração.');
  }

  /// Salva o botão. Devolve a mensagem de recusa do PC (ex.: tentar criar no celular um
  /// botão que abre programas) para a tela mostrar; outros erros vão para [error].
  Future<String?> updateButton(DeckButton newButton, {String? undoLabel}) async {
    final profile = currentProfile.value;
    if (profile == null) return null;

    try {
      isLoading.value = true;

      // Update local state first (optimistic)
      final updatedButtons = List<DeckButton>.from(profile.buttons);
      final index = updatedButtons.indexWhere(
          (b) => b.row == newButton.row && b.column == newButton.column);

      if (index != -1) {
        // If button is "empty/cleared" (id empty), we could remove it or just update it
        // If it's a clearing operation, best to keep the object but reset props, OR remove from list if sparse.
        // Given we use sparse list in frontend now:
        if (newButton.id.isEmpty && index != -1) {
          // It's a clear operation
          updatedButtons.removeAt(index);
        } else {
          updatedButtons[index] = newButton;
        }
      } else if (newButton.id.isNotEmpty) {
        // New button
        updatedButtons.add(newButton);
      }

      final updatedProfile = profile.copyWith(buttons: updatedButtons);

      // Save to backend
      await _client.saveProfile(updatedProfile);

      // Update signal
      currentProfile.value = updatedProfile;
      history.record(DeckEdit(profile, updatedProfile,
          undoLabel ?? (newButton.id.isEmpty ? tr('Remover botão') : tr('Editar botão'))));

      // Also update list if needed
      final profileIndex = profiles.value.indexWhere((p) => p.id == profile.id);
      if (profileIndex != -1) {
        profiles.value[profileIndex] = updatedProfile;
        profiles.value = List.from(profiles.value); // Trigger notify
        _updateMemoryCache(profiles.value);
        _saveCache(profiles.value);
      }
    } catch (e) {
      final forbidden = _forbiddenMessage(e);
      if (forbidden != null) return forbidden;
      error.value = e.toString();
    } finally {
      isLoading.value = false;
    }
    return null;
  }

  /// Grava o perfil inteiro. Com [undoLabel], a mudança entra no desfazer.
  /// Devolve a mensagem de recusa do PC (403) ou erro legível, ou null se salvou.
  Future<String?> updateProfileFull(DeckProfile updatedProfile, {String? undoLabel}) async {
    final before = profiles.value.where((p) => p.id == updatedProfile.id).firstOrNull;
    final prevCurrent = currentProfile.value;
    final index = profiles.value.indexWhere((p) => p.id == updatedProfile.id);
    try {
      isLoading.value = true;
      // Optimistic update. Outro perfil (renomeado pela barra lateral) não vira o atual.
      if (prevCurrent == null || prevCurrent.id == updatedProfile.id || before == null) {
        currentProfile.value = updatedProfile;
      }

      // Update in list
      if (index != -1) {
        profiles.value[index] = updatedProfile;
        profiles.value = List.from(profiles.value); // Trigger notify
      }

      await _client.saveProfile(updatedProfile);
      if (undoLabel != null && before != null) {
        history.record(DeckEdit(before, updatedProfile, undoLabel));
      }
      _updateMemoryCache(profiles.value);
      _saveCache(profiles.value);
      return null;
    } catch (e) {
      // Desfaz a atualização otimista se o PC recusou (403) ou falhou.
      if (before != null && index != -1 && index < profiles.value.length) {
        profiles.value[index] = before;
        profiles.value = List.from(profiles.value);
      }
      if (prevCurrent != null) {
        currentProfile.value = prevCurrent;
      }
      final forbidden = _forbiddenMessage(e);
      if (forbidden != null) return forbidden;
      error.value = e.toString();
      return tr('O PC não respondeu. Confira se o DeckOS está aberto nele.');
    } finally {
      isLoading.value = false;
    }
  }

  void switchProfile(String profileId) {
    try {
      final profile = profiles.value.firstWhere((p) => p.id == profileId);
      currentProfile.value = profile;
    } catch (e) {
      debugPrint('Profile not found: $profileId');
    }
  }

  Future<void> deleteProfile(String id) async {
    try {
      isLoading.value = true;
      await _client.deleteProfile(id);
      history.forget(id);

      // Remove from list
      profiles.value.removeWhere((p) => p.id == id);
      profiles.value = List.from(profiles.value); // Notify

      // If current profile was deleted, switch
      if (currentProfile.value?.id == id) {
        if (profiles.value.isNotEmpty) {
          currentProfile.value = profiles.value.first;
        } else {
          currentProfile.value = null;
        }
      }
    } catch (e) {
      error.value = e.toString();
    } finally {
      isLoading.value = false;
    }
  }

  /// Move um botão para (newRow,newCol); troca de lugar se o destino estiver ocupado.
  Future<void> moveButton(DeckButton button, int newRow, int newCol) async {
    final profile = currentProfile.value;
    if (profile == null) return;
    if (button.row == newRow && button.column == newCol) return;

    final buttons = List<DeckButton>.from(profile.buttons);
    final srcIdx = buttons
        .indexWhere((b) => b.row == button.row && b.column == button.column);
    if (srcIdx == -1) return;
    final targetIdx =
        buttons.indexWhere((b) => b.row == newRow && b.column == newCol);

    if (targetIdx != -1 && targetIdx != srcIdx) {
      // Troca: o botão que estava no destino vai para a posição de origem.
      buttons[targetIdx] =
          _copyWithPos(buttons[targetIdx], button.row, button.column);
    }
    buttons[srcIdx] = _copyWithPos(buttons[srcIdx], newRow, newCol);

    await updateProfileFull(profile.copyWith(buttons: buttons), undoLabel: tr('Mover botão'));
  }

  /// Troca os botões do perfil atual por [buttons] (resultado de uma operação da grade),
  /// entrando no desfazer com [label].
  Future<void> commitButtons(List<DeckButton> buttons, String label) async {
    final profile = currentProfile.value;
    if (profile == null) return;
    await updateProfileFull(profile.copyWith(buttons: buttons), undoLabel: label);
  }

  /// Desfaz a última edição da sessão. Mostra o perfil dela, se for outro.
  Future<String?> undo() async {
    final e = history.undo();
    if (e == null) return null;
    await _restore(e.before);
    return e.label;
  }

  Future<String?> redo() async {
    final e = history.redo();
    if (e == null) return null;
    await _restore(e.after);
    return e.label;
  }

  Future<void> _restore(DeckProfile p) async {
    if (!profiles.value.any((x) => x.id == p.id)) return;
    currentProfile.value = p;
    await updateProfileFull(p);
  }

  /// Cria um perfil (página) vazio e já o mostra.
  Future<DeckProfile> createProfile(String name) async {
    final base = currentProfile.value;
    final profile = DeckProfile(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      rows: base?.rows ?? 3,
      columns: base?.columns ?? 5,
    );
    profiles.value = [...profiles.value, profile];
    currentProfile.value = profile;
    try {
      await _client.saveProfile(profile);
    } catch (e) {
      error.value = e.toString();
    }
    return profile;
  }

  /// Cópia de [source] com outro nome e ids novos nos botões, logo depois dele na lista.
  Future<DeckProfile> duplicateProfile(DeckProfile source, String name) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    var n = 0;
    final copy = DeckProfile(
      id: '$stamp',
      name: name,
      rows: source.rows,
      columns: source.columns,
      buttons: [for (final b in source.buttons) b.copyWith(id: '$stamp-${n++}')],
      autoSwitchApps: null,
    );
    final list = [...profiles.value];
    final at = list.indexWhere((p) => p.id == source.id);
    list.insert(at == -1 ? list.length : at + 1, copy);
    profiles.value = list;
    currentProfile.value = copy;
    try {
      await _client.saveProfile(copy);
      _savePageOrder();
    } catch (e) {
      error.value = e.toString();
    }
    return copy;
  }

  // ---- Ordem das páginas ----
  // O PC ainda não guarda a ordem dos perfis: o configurador lembra a ordem que o usuário
  // arrastou (neste navegador) e a aplica ao carregar.
  static String get _orderKey => PcStore.scoped('deck_page_order');

  /// Leva a página de [from] para [to] (índices da lista atual).
  void reorderProfiles(int from, int to) {
    final list = [...profiles.value];
    if (from < 0 || from >= list.length) return;
    final p = list.removeAt(from);
    list.insert(to.clamp(0, list.length), p);
    profiles.value = list;
    _savePageOrder();
  }

  Future<void> _savePageOrder() async {
    try {
      await (await SharedPreferences.getInstance())
          .setStringList(_orderKey, [for (final p in profiles.value) p.id]);
    } catch (_) {}
  }

  Future<List<DeckProfile>> _applyPageOrder(List<DeckProfile> list) async {
    if (!WebMode.configurator) return list;
    List<String>? order;
    try {
      order = (await SharedPreferences.getInstance()).getStringList(_orderKey);
    } catch (_) {}
    if (order == null || order.isEmpty) return list;
    final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    // Página nova (fora da ordem salva) fica no fim, na ordem do PC.
    indexed.sort((a, b) {
      final ra = rank[a.$2.id] ?? order!.length + a.$1;
      final rb = rank[b.$2.id] ?? order!.length + b.$1;
      return ra.compareTo(rb);
    });
    return [for (final (_, p) in indexed) p];
  }

  /// Copia (ou move) [button] para a primeira casa livre de [target], numa grade de
  /// [rows]×[columns] (a do celular: botão fora dela some). Devolve o erro para mostrar,
  /// ou null se deu certo.
  Future<String?> copyButtonTo(DeckButton button, DeckProfile target,
      {required int rows, required int columns, required bool move}) async {
    final owner = profiles.value
        .where((p) => p.buttons.any((b) => b.id == button.id))
        .firstOrNull;
    if (owner == null) return tr('O botão não está mais no PC. Atualize o deck.');

    final layout = GridLayout.of(target.buttons, rows, columns);
    // Casa com botão escondido (fora da grade de outro aparelho) também conta como ocupada.
    final anchors = {for (final b in target.buttons) GridLayout.key(b.row, b.column)};
    (int, int)? free;
    for (var r = 0; r < rows && free == null; r++) {
      for (var c = 0; c < columns; c++) {
        if (layout.isFree(r, c) && !anchors.contains(GridLayout.key(r, c))) {
          free = (r, c);
          break;
        }
      }
    }
    if (free == null) {
      return tr('"{name}" está cheio. Libere uma casa e tente de novo.', {'name': target.name});
    }

    try {
      await _client.copyButton(
        fromProfileId: owner.id,
        buttonId: button.id,
        toProfileId: target.id,
        row: free.$1,
        column: free.$2,
        move: move,
      );
      await loadProfiles();
      return null;
    } catch (e) {
      debugPrint('Error copying button: $e');
      return tr('O PC não respondeu. Confira se o DeckOS está aberto nele.');
    }
  }

  /// Ajusta as dimensões (linhas/colunas) do perfil atual.
  Future<void> setGridSize(int rows, int columns) async {
    final profile = currentProfile.value;
    if (profile == null) return;
    await updateProfileFull(profile.copyWith(
      rows: rows.clamp(1, 10),
      columns: columns.clamp(1, 10),
    ));
  }

  DeckButton _copyWithPos(DeckButton b, int row, int col) =>
      b.copyWith(row: row, column: col);
}
