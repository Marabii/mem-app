import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_application_1/data/database.dart';
import 'package:flutter_application_1/services/web_server/web_server_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';

/// Drives the real HTTP server over a real socket — the closest thing to the
/// on-device behaviour that can run without a phone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late WebServerService server;
  late String base;

  setUpAll(() {
    // TestWidgetsFlutterBinding installs an HttpOverrides that short-circuits
    // every request to a 400. This suite needs real sockets to talk to the
    // server it starts, so put the genuine HttpClient back.
    HttpOverrides.global = null;

    if (!Platform.isLinux) return;
    open.overrideFor(OperatingSystem.linux, () {
      for (final name in ['libsqlite3.so', 'libsqlite3.so.0']) {
        try {
          return DynamicLibrary.open(name);
        } on ArgumentError {
          continue;
        }
      }
      return DynamicLibrary.process();
    });
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    server = WebServerService(db);
    // High port to avoid colliding with anything the developer is running.
    final state = await server.start(preferredPort: 48231);
    expect(state.running, isTrue, reason: state.error ?? 'server did not start');
    base = 'http://127.0.0.1:${state.port}';
  });

  tearDown(() async {
    await server.dispose();
    await db.close();
  });

  Future<HttpClientResponse> request(String method, String path,
      [Object? body]) async {
    final client = HttpClient();
    final req = await client.openUrl(method, Uri.parse('$base$path'));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    return req.close();
  }

  Future<String> bodyOf(HttpClientResponse response) =>
      response.transform(utf8.decoder).join();

  test('serves the SPA at the root', () async {
    final response = await request('GET', '/');
    expect(response.statusCode, 200);
    expect(response.headers.contentType?.mimeType, 'text/html');

    final html = await bodyOf(response);
    expect(html, contains('<title>MemApp</title>'));
    expect(html, contains('app.js'));
    // The page must not reach out to the internet — the phone may have none.
    expect(html, isNot(contains('http://cdn')));
    expect(html, isNot(contains('https://cdn')));
  });

  test('serves the stylesheet and script with correct content types', () async {
    final css = await request('GET', '/styles.css');
    expect(css.statusCode, 200);
    expect(css.headers.contentType?.mimeType, 'text/css');
    expect(await bodyOf(css), contains('.topic-item'));

    final js = await request('GET', '/app.js');
    expect(js.statusCode, 200);
    expect(js.headers.contentType?.mimeType, 'application/javascript');
    expect(await bodyOf(js), contains('/api/cards'));
  });

  test('refuses to walk out of the asset directory', () async {
    final response = await request('GET', '/../../pubspec.yaml');
    expect(response.statusCode, anyOf(400, 404));
  });

  test('unknown asset paths 404 rather than hanging', () async {
    expect((await request('GET', '/nope.png')).statusCode, 404);
  });

  test('round-trips a card created over HTTP', () async {
    final topicId = await db.createTopic(name: 'Rust');

    final created = await request('POST', '/api/cards', {
      'topicId': topicId,
      'front': 'What is Send?',
      'back': 'Safe to move across threads',
    });
    expect(created.statusCode, 201);

    // It must be visible to the app side immediately — same database.
    expect(await db.allCards(), hasLength(1));

    final listed = jsonDecode(await bodyOf(await request('GET', '/api/cards')));
    expect((listed['cards'] as List).single['front'], 'What is Send?');
  });

  test('counts requests for the in-app indicator', () async {
    final before = server.state.requestCount;
    await bodyOf(await request('GET', '/api/health'));
    await bodyOf(await request('GET', '/api/stats'));
    expect(server.state.requestCount, greaterThan(before));
  });

  test('reports a LAN address or null, never throws', () async {
    final address = await WebServerService.lanAddress();
    if (address != null) {
      expect(InternetAddress.tryParse(address), isNotNull);
      expect(address, isNot(startsWith('127.')));
    }
  });

  test('stop releases the port so it can be rebound', () async {
    final port = server.state.port!;
    await server.stop();
    expect(server.isRunning, isFalse);

    final again = await server.start(preferredPort: port);
    expect(again.running, isTrue);
    expect(again.port, port);
  });
}
