import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../../data/database.dart';
import '../export_service.dart';
import 'api_router.dart';
import 'server_keep_alive.dart';

@immutable
class WebServerState {
  const WebServerState({
    this.running = false,
    this.starting = false,
    this.url,
    this.port,
    this.requestCount = 0,
    this.error,
    this.keepAlive = false,
  });

  final bool running;
  final bool starting;
  final String? url;
  final int? port;
  final int requestCount;
  final String? error;

  /// Whether the foreground service that survives the screen going off is up.
  /// False on platforms that have no such service, and if Android refused it.
  final bool keepAlive;

  WebServerState copyWith({
    bool? running,
    bool? starting,
    String? url,
    int? port,
    int? requestCount,
    String? error,
    bool? keepAlive,
    bool clearError = false,
  }) =>
      WebServerState(
        running: running ?? this.running,
        starting: starting ?? this.starting,
        url: url ?? this.url,
        port: port ?? this.port,
        requestCount: requestCount ?? this.requestCount,
        error: clearError ? null : (error ?? this.error),
        keepAlive: keepAlive ?? this.keepAlive,
      );
}

/// Runs a real HTTP server inside the app process.
///
/// Bound to `anyIPv4` so it is reachable from other machines on the Wi-Fi
/// network. There is no authentication by design — see the warning shown on the
/// Server screen.
///
/// While it is running, [ServerKeepAlive] holds the process in the foreground
/// so that locking the phone does not take the server down with the screen.
class WebServerService {
  WebServerService(this._db, {ServerKeepAlive? keepAlive})
      : _keepAlive = keepAlive ?? ServerKeepAlive() {
    // The service stops itself before telling us, so this must not tell it to
    // stop again.
    _keepAlive.onStopRequested = () => unawaited(stop(notifyService: false));
    _keepAlive.listen();
  }

  final AppDatabase _db;
  final ServerKeepAlive _keepAlive;

  HttpServer? _server;
  int _requestCount = 0;

  final _stateController = StreamController<WebServerState>.broadcast();
  WebServerState _state = const WebServerState();

  Stream<WebServerState> get stateStream => _stateController.stream;
  WebServerState get state => _state;
  bool get isRunning => _server != null;

  void _emit(WebServerState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  Future<WebServerState> start({int preferredPort = 8080}) async {
    if (_server != null) return _state;
    _emit(_state.copyWith(starting: true, clearError: true));

    final router = ApiRouter(_db, ExportService(_db)).handler;
    final handler = const Pipeline().addMiddleware(_counter).addHandler(router);

    // If the preferred port is taken (another app, or a previous instance that
    // has not released it yet) walk forward a few rather than just failing.
    for (var offset = 0; offset < 5; offset++) {
      final port = preferredPort + offset;
      try {
        final server =
            await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
        server.autoCompress = true;
        _server = server;
        _requestCount = 0;

        final ip = await lanAddress();
        final url = 'http://${ip ?? 'localhost'}:$port';
        // Started before the state is published so the Server screen never
        // shows "running" while the process is still droppable.
        final keptAlive = await _keepAlive.start(url);
        _emit(WebServerState(
          running: true,
          starting: false,
          url: url,
          port: port,
          requestCount: 0,
          keepAlive: keptAlive,
        ));
        return _state;
      } on SocketException catch (e) {
        if (offset == 4) {
          _emit(WebServerState(
            starting: false,
            error: 'Could not bind to a port near $preferredPort.\n${e.message}',
          ));
          return _state;
        }
      } catch (e) {
        _emit(WebServerState(starting: false, error: e.toString()));
        return _state;
      }
    }
    return _state;
  }

  /// [notifyService] is false only when the stop request came from the
  /// foreground service itself — the notification's Stop action, or the task
  /// being swiped away.
  Future<void> stop({bool notifyService = true}) async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
    if (notifyService) await _keepAlive.stop();
    _emit(const WebServerState());
  }

  Middleware get _counter => (inner) => (request) async {
        _requestCount++;
        _emit(_state.copyWith(requestCount: _requestCount));
        return inner(request);
      };

  /// The phone's address on the local network.
  ///
  /// Uses dart:io directly instead of a plugin: it needs no permission, and on
  /// Android the Wi-Fi interface is the first non-loopback IPv4 that is not a
  /// virtual/tether interface.
  static Future<String?> lanAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      if (interfaces.isEmpty) return null;

      // Prefer wlan*, then anything else that is not a tunnel or tether.
      int rank(NetworkInterface i) {
        final n = i.name.toLowerCase();
        if (n.startsWith('wlan') || n.startsWith('wifi')) return 0;
        if (n.startsWith('eth') || n.startsWith('en')) return 1;
        if (n.startsWith('rmnet') || n.startsWith('tun') || n.startsWith('ap')) {
          return 3;
        }
        return 2;
      }

      final sorted = interfaces.toList()
        ..sort((a, b) => rank(a).compareTo(rank(b)));
      for (final iface in sorted) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (e) {
      debugPrint('MemApp: could not read network interfaces ($e)');
    }
    return null;
  }

  Future<void> dispose() async {
    await stop();
    await _stateController.close();
  }
}
