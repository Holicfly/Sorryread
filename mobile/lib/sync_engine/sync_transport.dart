import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'sync_model.dart';

bool isLanEndpoint(String value, {bool allowLoopback = false}) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !['', '/'].contains(uri.path) ||
      uri.port < 1 ||
      uri.port > 65535) {
    return false;
  }
  final address = InternetAddress.tryParse(uri.host);
  if (address == null) return false;
  if (address.isLoopback) return allowLoopback;
  final b = address.rawAddress;
  return address.type == InternetAddressType.IPv4
      ? b[0] == 10 ||
            (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
            (b[0] == 192 && b[1] == 168) ||
            (b[0] == 169 && b[1] == 254)
      : address.isLinkLocal || (b[0] & 0xfe) == 0xfc;
}

class PairTicket {
  PairTicket(
    this.serverId,
    this.name,
    this.endpoints,
    this.pin,
    this.token,
    this.expires,
  );
  final String serverId, name, pin, token;
  final List<String> endpoints;
  final DateTime expires;
  factory PairTicket.parse(String raw, {bool allowLoopback = false}) {
    if (raw.length > 8192) throw const FormatException('二维码内容过长');
    final json = jsonDecode(raw) as Json;
    final ticket = PairTicket(
      json['serverId'] as String,
      json['name'] as String,
      (json['endpoints'] as List).cast<String>(),
      json['certificateSha256'] as String,
      json['token'] as String,
      DateTime.parse(json['expiresUtc'] as String).toUtc(),
    );
    final now = DateTime.now().toUtc();
    if (json['type'] != 'sorryread-pair' ||
        json['version'] != 1 ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(ticket.serverId) ||
        ticket.name.length > 128 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(ticket.pin) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(ticket.token) ||
        ticket.endpoints.isEmpty ||
        ticket.endpoints.length > 8 ||
        ticket.endpoints.any(
          (e) => !isLanEndpoint(e, allowLoopback: allowLoopback),
        ) ||
        !ticket.expires.isAfter(now) ||
        ticket.expires.difference(now) > const Duration(minutes: 5)) {
      throw const FormatException('二维码无效、已过期或不属于局域网配对');
    }
    return ticket;
  }
}

class LinkedPeer {
  LinkedPeer({
    required this.serverId,
    required this.name,
    required this.endpoints,
    required this.pin,
    required this.credential,
  });
  final String serverId, name, pin, credential;
  final List<String> endpoints;
  factory LinkedPeer.fromJson(Json json) => LinkedPeer(
    serverId: json['serverId'] as String,
    name: json['name'] as String,
    endpoints: (json['endpoints'] as List).cast<String>(),
    pin: json['pin'] as String,
    credential: json['credential'] as String,
  );
  Json toJson() => {
    'serverId': serverId,
    'name': name,
    'endpoints': endpoints,
    'pin': pin,
    'credential': credential,
  };
  LinkedPeer withEndpoint(String endpoint) => LinkedPeer(
    serverId: serverId,
    name: name,
    endpoints: [
      endpoint,
      ...endpoints.where((e) => e != endpoint),
    ].take(8).toList(),
    pin: pin,
    credential: credential,
  );
}

abstract interface class PeerStorage {
  Future<LinkedPeer?> read();
  Future<void> write(LinkedPeer peer);
  Future<void> delete();
}

class SecurePeerStorage implements PeerStorage {
  SecurePeerStorage({this.key = 'sorryread.device-link.v1'});
  static const _storage = FlutterSecureStorage();
  final String key;
  @override
  Future<LinkedPeer?> read() async {
    final value = await _storage.read(key: key);
    return value == null
        ? null
        : LinkedPeer.fromJson(jsonDecode(value) as Json);
  }

  @override
  Future<void> write(LinkedPeer peer) =>
      _storage.write(key: key, value: jsonEncode(peer.toJson()));
  @override
  Future<void> delete() => _storage.delete(key: key);
}

class SyncTransport {
  SyncTransport(
    String endpoint,
    String pin, {
    String? credential,
    this.allowLoopback = false,
  }) {
    if (!isLanEndpoint(endpoint, allowLoopback: allowLoopback) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(pin)) {
      throw const FormatException('连接地址或证书指纹无效');
    }
    final expected = Uri.parse(endpoint);
    bool matches(X509Certificate certificate, String host, int port) =>
        host == expected.host &&
        port == expected.port &&
        sha256.convert(certificate.der).toString() == pin &&
        certificate.startValidity.isBefore(DateTime.now()) &&
        certificate.endValidity.isAfter(DateTime.now());
    dio = Dio(
      BaseOptions(
        baseUrl: endpoint,
        connectTimeout: const Duration(seconds: 4),
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 12),
        followRedirects: false,
        maxRedirects: 0,
        headers: {
          if (credential != null) 'Authorization': 'Bearer $credential',
        },
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        // An empty trust store forces this exact leaf pin to be checked during TLS,
        // BEFORE Dart creates the HTTP request and sends its Authorization header.
        final client = HttpClient(
          context: SecurityContext(withTrustedRoots: false),
        );
        client.findProxy = (_) => 'DIRECT';
        client.badCertificateCallback = matches;
        return client;
      },
      validateCertificate: (certificate, host, port) =>
          certificate != null && matches(certificate, host, port),
    );
  }
  final bool allowLoopback;
  late final Dio dio;
  Future<Json> get(String path, CancelToken cancel) async {
    final response = await dio.get<dynamic>(path, cancelToken: cancel);
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Json> post(
    String path,
    dynamic body,
    CancelToken cancel, {
    bool pairing = false,
  }) async {
    final response = await dio.post<dynamic>(
      path,
      data: body,
      cancelToken: cancel,
      options: pairing
          ? Options(receiveTimeout: const Duration(seconds: 75))
          : null,
    );
    if (response.data == null || response.data == '') return {};
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> delete(String path, CancelToken cancel) async {
    await dio.delete<void>(path, cancelToken: cancel);
  }

  void close() => dio.close(force: true);
}
