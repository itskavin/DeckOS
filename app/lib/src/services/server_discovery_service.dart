import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import 'package:network_info_plus/network_info_plus.dart';

/// Um PC achado na rede. [ip] é o que vai no campo de endereço do app; [port] só vem do
/// mDNS (o UDP não anuncia a porta, e aí vale a padrão 4787).
@immutable
class DiscoveredServer {
  final String ip;
  final int? port;
  final String? name;
  final String? version;

  /// Identidade estável do servidor (TXT "id" do mDNS). Junta o mesmo PC achado pelos dois
  /// caminhos mesmo quando ele tem mais de uma placa de rede.
  final String? id;

  /// 'udp' ou 'mdns': de onde veio a primeira resposta.
  final String source;

  const DiscoveredServer({
    required this.ip,
    required this.source,
    this.port,
    this.name,
    this.version,
    this.id,
  });

  /// Endereço para o campo do app: "ip" ou "ip:porta" quando a porta não é a padrão.
  String get address =>
      port == null || port == ServerDiscoveryService.defaultHttpPort ? ip : '$ip:$port';

  /// Completa o que falta com o que o outro caminho trouxe (o mDNS sabe porta, versão e id;
  /// o UDP não).
  DiscoveredServer merge(DiscoveredServer other) => DiscoveredServer(
        ip: ip,
        source: source,
        port: port ?? other.port,
        name: name ?? other.name,
        version: version ?? other.version,
        id: id ?? other.id,
      );

  @override
  String toString() => 'DiscoveredServer($address, $name, via $source)';
}

class ServerDiscoveryService {
  static const udpPort = 7573;
  static const defaultHttpPort = 4787;
  static const mdnsType = '_deckos._tcp';

  /// Primeiro PC que responder, pelo UDP ou pelo mDNS. Mantida para quem só quer um IP:
  /// devolve o IP ou 'Not Found' depois de [timeout] segundos. [ip] é ignorado (o destino
  /// do broadcast é calculado pela rede atual).
  Future<String> findServers(String ip, int timeout) async {
    debugPrint('Discovery: Starting search.');
    try {
      final first = await discover(timeout: Duration(seconds: timeout)).first;
      return first.address;
    } on StateError {
      // Stream fechou sem nenhum PC.
      debugPrint('Discovery: Timeout waiting for response');
      return 'Not Found';
    }
  }

  /// Todos os PCs achados em [timeout], sem repetição.
  Future<List<DiscoveredServer>> findAll(
      {Duration timeout = const Duration(seconds: 4)}) {
    return discover(timeout: timeout).toList();
  }

  /// Cada PC uma vez só, assim que aparece por qualquer um dos caminhos. Fecha depois de
  /// [timeout] (ou antes, se quem ouve cancelar).
  Stream<DiscoveredServer> discover(
      {Duration timeout = const Duration(seconds: 4)}) {
    final seen = <String, DiscoveredServer>{};
    final ids = <String, String>{};
    late final StreamController<DiscoveredServer> controller;
    final stops = <Future<void> Function()>[];
    Timer? timer;
    var closed = false;

    void runStop(Future<void> Function() stop) {
      stop().catchError((Object e) => debugPrint('Discovery: Error stopping: $e'));
    }

    // Sem await: o `.first` de findServers espera o cancelamento terminar, e esperar o
    // close() do controller dentro do próprio onCancel travaria para sempre.
    void close() {
      if (closed) return;
      closed = true;
      timer?.cancel();
      stops.forEach(runStop);
      controller.close();
    }

    // Os caminhos sobem de forma assíncrona: se a busca já acabou quando um deles fica
    // pronto, ele é parado na hora em vez de ficar ouvindo a rede à toa.
    void onStop(Future<void> Function() stop) {
      if (closed) {
        runStop(stop);
      } else {
        stops.add(stop);
      }
    }

    void add(DiscoveredServer server) {
      if (closed) return;
      // Mesmo id (o mesmo PC por outra placa) ou mesmo IP: não repete, só completa.
      final key = server.id != null ? (ids[server.id!] ?? server.ip) : server.ip;
      if (server.id != null) ids.putIfAbsent(server.id!, () => key);
      final previous = seen[key];
      if (previous != null) {
        seen[key] = previous.merge(server);
        return;
      }
      seen[key] = server;
      debugPrint('Discovery: Found $server');
      controller.add(server);
    }

    controller = StreamController<DiscoveredServer>(
      onListen: () {
        timer = Timer(timeout, close);
        // No navegador não há socket nem mDNS: o próprio endereço da página já é o PC.
        if (kIsWeb) {
          close();
          return;
        }
        _startUdp(add, onStop);
        _startMdns(add, onStop);
      },
      onCancel: close,
    );
    return controller.stream;
  }

  Future<void> _startUdp(void Function(DiscoveredServer) add,
      void Function(Future<void> Function()) onStop) async {
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (e) {
      debugPrint('Discovery: UDP bind failed: $e');
      return;
    }
    onStop(() async => socket.close());
    socket.broadcastEnabled = true;

    socket.listen((RawSocketEvent e) {
      if (e != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      try {
        final response = utf8.decode(datagram.data);
        debugPrint(
            'Discovery: Received response: $response from ${datagram.address}');
        final json = jsonDecode(response) as Map<String, dynamic>;
        final ip = json['ip'];
        if (ip is String && ip.isNotEmpty) {
          add(DiscoveredServer(
            ip: ip,
            source: 'udp',
            name: json['name'] as String?,
            id: json['id'] as String?,
          ));
        }
      } catch (e) {
        // Datagrama malformado/de outro serviço: segue ouvindo até o timeout.
        debugPrint('Discovery: Error parsing response: $e');
      }
    }, onError: (Object e) => debugPrint('Discovery: UDP error: $e'));

    for (final target in await _broadcastTargets()) {
      try {
        debugPrint('Discovery: Sending packet to $target:$udpPort');
        socket.send(utf8.encode('DeckOSDiscoveryRequest'),
            InternetAddress(target), udpPort);
      } catch (e) {
        // No iOS o broadcast falha sem a permissão de multicast da Apple; o mDNS cobre.
        debugPrint('Discovery: Error sending packet to $target: $e');
      }
    }
  }

  Future<List<String>> _broadcastTargets() async {
    final targets = ['255.255.255.255'];
    try {
      final wifiIP = await NetworkInfo().getWifiIP();
      debugPrint('Discovery: IP=$wifiIP');
      // Assume /24 (o normal em Wi-Fi de casa).
      final lastDot = wifiIP?.lastIndexOf('.') ?? -1;
      if (lastDot != -1) {
        final broadcast = '${wifiIP!.substring(0, lastDot)}.255';
        if (!targets.contains(broadcast)) targets.add(broadcast);
      }
    } catch (e) {
      debugPrint('Discovery: Error calculating broadcast: $e');
    }
    return targets;
  }

  Future<void> _startMdns(void Function(DiscoveredServer) add,
      void Function(Future<void> Function()) onStop) async {
    try {
      final discovery = BonsoirDiscovery(type: mdnsType, printLogs: false);
      await discovery.initialize();
      discovery.eventStream?.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            event.service.resolve(discovery.serviceResolver);
          case BonsoirDiscoveryServiceResolvedEvent():
          case BonsoirDiscoveryServiceUpdatedEvent():
            final server = _fromMdns(event.service!);
            if (server != null) add(server);
          default:
            break;
        }
      }, onError: (Object e) => debugPrint('Discovery: mDNS error: $e'));
      await discovery.start();
      onStop(discovery.stop);
    } catch (e) {
      // Plataforma sem mDNS (ou sem permissão de rede local): fica só o UDP.
      debugPrint('Discovery: mDNS unavailable: $e');
    }
  }

  DiscoveredServer? _fromMdns(BonsoirService service) {
    // Prefere IPv4: é o que o resto do app (e o usuário) espera ver no campo de endereço.
    final addresses = service.hostAddresses;
    final ip = addresses.firstWhere(
      (a) => InternetAddress.tryParse(a)?.type == InternetAddressType.IPv4,
      orElse: () => '',
    );
    if (ip.isEmpty) return null;
    final txt = service.attributes;
    return DiscoveredServer(
      ip: ip,
      source: 'mdns',
      port: service.port > 0 ? service.port : null,
      name: txt['name'] ?? service.name,
      version: txt['version'],
      id: txt['id'],
    );
  }
}
