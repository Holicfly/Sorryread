import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nsd/nsd.dart' as nsd;

import '../../sync_engine/sync_transport.dart';

class _Search {
  final cancelled = Completer<List<String>>();
  nsd.Discovery? discovery;
  Future<void>? cleanup;
}

class PeerDiscovery {
  PeerDiscovery({
    Future<nsd.Discovery> Function()? startDiscovery,
    Future<void> Function(nsd.Discovery)? stopDiscovery,
    this.startTimeout = const Duration(seconds: 3),
    this.searchTimeout = const Duration(seconds: 5),
    this.stopTimeout = const Duration(seconds: 1),
  }) : _start =
           startDiscovery ??
           (() => nsd.startDiscovery(
             '_sorryread._tcp',
             ipLookupType: nsd.IpLookupType.none,
           )),
       _stop = stopDiscovery ?? nsd.stopDiscovery;

  final Future<nsd.Discovery> Function() _start;
  final Future<void> Function(nsd.Discovery) _stop;
  final Duration startTimeout, searchTimeout, stopTimeout;
  _Search? _active;
  int _generation = 0;

  Future<void> _cleanup(_Search search) {
    final discovery = search.discovery;
    if (discovery == null) return Future.value();
    return search.cleanup ??= Future<void>.sync(() => _stop(discovery))
        .timeout(stopTimeout)
        .catchError((Object _) {});
  }

  Future<void> _cancel(_Search? search) async {
    if (search == null) return;
    if (!search.cancelled.isCompleted) search.cancelled.complete([]);
    await _cleanup(search);
  }

  Future<List<String>> find(String serverId) async {
    final generation = ++_generation;
    final previous = _active;
    _active = null;
    await _cancel(previous);
    if (generation != _generation) return [];
    final search = _Search();
    _active = search;
    final starting = Future<nsd.Discovery>.sync(_start);
    // A native start may finish after timeout/cancellation. Release that late handle
    // without letting it replace or stop a newer discovery session.
    unawaited(
      starting.then<void>((discovery) {
        search.discovery = discovery;
        if (!identical(_active, search)) unawaited(_cleanup(search));
      }, onError: (Object _, StackTrace _) {}),
    );
    nsd.Discovery? discovery;
    void Function()? inspect;
    try {
      discovery = await Future.any<nsd.Discovery?>([
        starting,
        search.cancelled.future.then((_) => null),
      ]).timeout(startTimeout, onTimeout: () => null);
      if (discovery == null || !identical(_active, search)) return [];
      final current = discovery;
      final found = Completer<List<String>>();
      inspect = () {
        for (final service in current.services) {
          final id = service.txt?['id'];
          if (id == null ||
              utf8.decode(id, allowMalformed: true) != serverId ||
              service.port == null) {
            continue;
          }
          final advertised = utf8
              .decode(service.txt?['a'] ?? [], allowMalformed: true)
              .split(',')
              .map(InternetAddress.tryParse)
              .nonNulls;
          final host = service.host == null
              ? null
              : InternetAddress.tryParse(service.host!);
          final addresses = [...advertised, ...?service.addresses, ?host]
            ..sort(
              (a, b) => a.type == b.type
                  ? 0
                  : a.type == InternetAddressType.IPv4
                  ? -1
                  : 1,
            );
          final endpoints = addresses
              .where(
                (a) => a.type != InternetAddressType.IPv6 || !a.isLinkLocal,
              )
              .map(
                (a) => Uri(
                  scheme: 'https',
                  host: a.address,
                  port: service.port,
                ).toString(),
              )
              .where(isLanEndpoint)
              .toSet()
              .take(8)
              .toList();
          if (endpoints.isNotEmpty && !found.isCompleted) {
            found.complete(endpoints);
          }
        }
      };
      current.addListener(inspect);
      inspect();
      return await Future.any([found.future, search.cancelled.future])
          .timeout(searchTimeout, onTimeout: () => []);
    } finally {
      if (discovery != null && inspect != null) {
        discovery.removeListener(inspect);
      }
      if (identical(_active, search)) _active = null;
      await _cleanup(search);
    }
  }

  Future<void> stop() {
    ++_generation;
    final search = _active;
    _active = null;
    return _cancel(search);
  }
}
