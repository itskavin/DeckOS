import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'demo_icons.dart';

/// PC de mentira para ver o configurador cheio sem o servidor (capturas de tela,
/// ajuste visual). Só liga em build de depuração ou com
/// `--dart-define=DECKOS_DEMO=true`, e só com `?demo=1` no endereço: num build
/// normal de release o compilador remove tudo isto.
class DemoBackend {
  DemoBackend._();

  static const _forced = bool.fromEnvironment('DECKOS_DEMO');

  static final bool enabled = (kDebugMode || _forced) &&
      kIsWeb &&
      Uri.base.queryParameters['demo'] == '1';

  static Interceptor interceptor() => InterceptorsWrapper(onRequest: (o, h) async {
        final path = o.uri.path;
        final result = await _state.handle(o.method.toUpperCase(), path, o.data);
        if (result == null) {
          h.reject(DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 404),
          ));
          return;
        }
        h.resolve(Response(requestOptions: o, statusCode: 200, data: result.data));
      });

  static final _state = _DemoState();
}

class _Result {
  final Object? data;
  const _Result(this.data);
}

class _DemoState {
  final profiles = <Map<String, dynamic>>[
    // A página dos prints: oito apps, só o ícone de cada um.
    _profile('design', 'Design', [
      _app(0, 0, 'Opera'),
      _app(0, 1, 'Chrome'),
      _app(0, 2, 'Discord'),
      _app(0, 3, 'VS Code'),
      _app(1, 0, 'WhatsApp'),
      _app(1, 1, 'Claude'),
      _app(1, 2, 'ChatGPT'),
      _app(1, 3, 'Music'),
    ]),
    // Controles do sistema: glifos brancos, sem nome.
    _profile('system', 'System', [
      _glyph(0, 0, 'Screenshot', 'camera', 'keyboard'),
      _glyph(0, 1, 'Mute', 'volume_off', 'mixer'),
      _glyph(0, 2, 'Volume down', 'volume_down', 'mixer'),
      _glyph(0, 3, 'Volume up', 'volume_up', 'mixer'),
      _glyph(1, 0, 'Mic', 'mic', 'mixer'),
      _glyph(1, 1, 'Previous', null, 'media', {'command': 'previous'}),
      _glyph(1, 2, 'Play/Pause', null, 'media', {'command': 'playpause'}),
      _glyph(1, 3, 'Next', null, 'media', {'command': 'next'}),
    ]),
    _profile('dev', 'Dev', [
      _app(0, 0, 'Terminal'),
      _app(0, 1, 'Xcode'),
      _app(0, 2, 'GitHub'),
      _app(0, 3, 'Docker'),
      _app(1, 0, 'Postman'),
      _app(1, 1, 'Figma'),
      {
        'id': 'folder-btn',
        'row': 1,
        'column': 2,
        'label': 'Streaming',
        'iconName': 'folder',
        'action': {
          'type': 'open_profile',
          'parameters': {'profileId': 'streaming'}
        },
      },
    ]),
    _profile('streaming', 'Streaming', [
      _glyph(0, 0, 'Go live', 'videocam', 'obs', {'operation': 'toggleStream'}),
      _glyph(0, 1, 'Mic', 'mic', 'mixer'),
      {
        'id': 'back',
        'row': 1,
        'column': 3,
        'label': 'Back',
        'iconName': 'arrow_back',
        'action': {'type': 'back', 'parameters': <String, String>{}},
      },
    ]),
    _profile('music', 'Music', const []),
  ];

  static Map<String, dynamic> _profile(String id, String name, List<Map<String, dynamic>> buttons) =>
      {'id': id, 'name': name, 'rows': 2, 'columns': 4, 'isDefault': id == 'design', 'buttons': buttons};

  /// App: o ícone (PNG) entra no primeiro pedido dos perfis, em [_fillIcons].
  static Map<String, dynamic> _app(int row, int col, String label) => {
        'id': 'b-$row-$col-${label.hashCode.abs()}',
        'row': row,
        'column': col,
        'label': label,
        '_demoIcon': label,
        'action': {
          'type': 'launch_app',
          'parameters': {'path': '/Applications/$label.app'},
        },
      };

  static Map<String, dynamic> _glyph(int row, int col, String label, String? icon, String type,
          [Map<String, String> params = const {}]) =>
      {
        'id': 'g-$row-$col-${label.hashCode.abs()}',
        'row': row,
        'column': col,
        'label': label,
        if (icon != null) 'iconName': icon,
        'action': {'type': type, 'parameters': params},
      };

  Future<void>? _icons;

  /// Troca a marca `_demoIcon` dos botões pelo PNG do ícone.
  Future<void> _fillIcons() async {
    for (final p in profiles) {
      for (final b in (p['buttons'] as List).cast<Map<String, dynamic>>()) {
        final name = b.remove('_demoIcon') as String?;
        if (name != null) b['iconBase64'] = base64Encode(await demoIconPng(name));
      }
    }
  }

  /// Apps "instalados" (a biblioteca do configurador). Ícones em demo_icons.dart.
  static const _apps = [
    'Activity Monitor',
    'AdGuard',
    'AirPort Utility',
    'Antigravity',
    'App Store',
    'Audio MIDI Setup',
    'Automator',
    'Blender',
    'Bluetooth File Exchange',
    'Books',
    'Calculator',
    'Calendar',
    'CapCut',
    'ChatGPT',
    'Chess',
    'Claude',
    'Clock',
    'Discord',
    'Docker',
    'Figma',
    'Finder',
    'FaceTime',
    'Google Chrome',
    'Mail',
    'Maps',
    'Messages',
    'Music',
    'Notes',
    'OBS Studio',
    'Opera',
    'Photos',
    'Safari',
    'Slack',
    'Spotify',
    'Steam',
    'System Settings',
    'Terminal',
    'Visual Studio Code',
    'WhatsApp',
    'Xcode',
    'Zoom',
  ];

  static String _appId(String name) => name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  List<Map<String, dynamic>>? triggers;

  List<Map<String, dynamic>> _demoTriggers() {
    final p = profiles.first;
    final buttons = p['buttons'] as List;
    String id(int i) => '${(buttons[i % buttons.length] as Map)['id']}';
    return [
      {'id': 't1', 'event': 'schedule', 'time': '09:00', 'days': '1-5', 'enabled': true,
        'name': 'Bom dia', 'profileId': p['id'], 'buttonId': id(7)},
      {'id': 't2', 'event': 'app_start', 'app': 'obs64', 'enabled': true,
        'profileId': p['id'], 'buttonId': id(2)},
      {'id': 't3', 'event': 'resume', 'enabled': false, 'profileId': p['id'], 'buttonId': id(0)},
    ];
  }

  Future<_Result?> handle(String method, String path, Object? body) async {
    switch ((method, path)) {
      case ('GET', '/api/StreamDeck/profiles'):
        await (_icons ??= _fillIcons());
        return _Result(jsonDecode(jsonEncode(profiles)));
      case ('POST', '/api/StreamDeck/profiles'):
        final p = Map<String, dynamic>.from(body is String ? jsonDecode(body) as Map : body as Map);
        final i = profiles.indexWhere((e) => e['id'] == p['id']);
        if (i == -1) {
          profiles.add(p);
        } else {
          profiles[i] = p;
        }
        return const _Result(null);
      case ('GET', '/api/StreamDeck/layout'):
        return const _Result({'rows': 2, 'columns': 4});
      case ('POST', '/api/StreamDeck/press'):
        return const _Result(null);
      case ('GET', '/api/system/info'):
        return const _Result({'name': "Kavin's MacBook Pro", 'version': '2.0.0'});
      case ('GET', '/api/platform'):
        return const _Result({
          'os': 'macos',
          'osVersion': 'macOS 26.1',
          'machineName': "Kavin's MacBook Pro",
          'version': '2.0.0',
          'capabilities': [
            'keyboard', 'keyboard.hold', 'apps.launch', 'apps.list', 'window.activate',
            'audio.volume', 'audio.microphone', 'media.control', 'media.nowPlaying',
            'soundboard', 'power.lock', 'power.sleep', 'system.monitor', 'script.shell', 'steam',
          ],
          'missing': [],
        });
      // Ajustes: quem está conectado e as automações (Quando → Fazer).
      case ('GET', '/api/integrations'):
        return const _Result([
          {'name': 'discord', 'connected': true},
          {'name': 'obs', 'connected': true},
          {'name': 'spotify', 'connected': true},
          {'name': 'homeassistant', 'connected': false},
        ]);
      case ('GET', '/api/triggers'):
        return _Result(triggers ??= _demoTriggers());
      case ('PUT', '/api/triggers'):
        final list = body is String ? jsonDecode(body) : body;
        triggers = [for (final t in list as List) Map<String, dynamic>.from(t as Map)];
        return const _Result(null);
      case ('GET', '/api/apps'):
        return _Result([
          for (final name in _apps)
            {'id': _appId(name), 'name': name, 'path': '/Applications/$name.app', 'iconUrl': '/api/apps/${_appId(name)}/icon'},
        ]);
    }
    if (method == 'DELETE' && path.startsWith('/api/StreamDeck/profiles/')) {
      final id = path.split('/').last;
      profiles.removeWhere((p) => p['id'] == id);
      return const _Result(null);
    }
    final icon = RegExp(r'^/api/apps/([^/]+)/icon$').firstMatch(path);
    if (method == 'GET' && icon != null) {
      final app = _apps.where((a) => _appId(a) == icon[1]).firstOrNull;
      if (app == null) return null;
      return _Result(await demoIconPng(app));
    }
    return null;
  }
}
