import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_application_1/data/database.dart';
import 'package:flutter_application_1/data/fsrs_mapping.dart';
import 'package:flutter_application_1/services/export_service.dart';
import 'package:flutter_application_1/services/web_server/api_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/open.dart';

void main() {
  late AppDatabase db;
  late Handler handler;

  setUpAll(() {
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

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    handler = ApiRouter(db, ExportService(db)).handler;
  });

  tearDown(() async => db.close());

  Uri url(String path) => Uri.parse('http://localhost:8080$path');

  Future<Response> get(String path) =>
      Future.value(handler(Request('GET', url(path))));

  Future<Response> send(String method, String path, Object? body) =>
      Future.value(handler(Request(
        method,
        url(path),
        body: body == null ? null : jsonEncode(body),
        headers: {'Content-Type': 'application/json'},
      )));

  Future<Map<String, dynamic>> json(Response response) async =>
      jsonDecode(await response.readAsString()) as Map<String, dynamic>;

  group('topics', () {
    test('creates, lists, updates and deletes', () async {
      final created = await send('POST', '/api/topics',
          {'name': 'Rust', 'description': 'Ownership', 'color': 0xFF10B981});
      expect(created.statusCode, 201);
      final topic = await json(created);
      expect(topic['name'], 'Rust');

      final listed = await json(await get('/api/topics'));
      expect((listed['topics'] as List), hasLength(1));
      expect((listed['topics'] as List).first['total'], 0);

      final updated = await json(
          await send('PUT', '/api/topics/${topic['id']}', {'name': 'Rust 2'}));
      expect(updated['name'], 'Rust 2');
      expect(updated['description'], 'Ownership',
          reason: 'omitted fields are left alone');

      final deleted = await send('DELETE', '/api/topics/${topic['id']}', null);
      expect(deleted.statusCode, 200);
      expect((await json(await get('/api/topics')))['topics'], isEmpty);
    });

    test('rejects a blank name with 400', () async {
      final response = await send('POST', '/api/topics', {'name': '   '});
      expect(response.statusCode, 400);
      expect((await json(response))['error'], contains('name'));
    });

    test('rejects a duplicate name with 409', () async {
      await send('POST', '/api/topics', {'name': 'Rust'});
      final response = await send('POST', '/api/topics', {'name': 'Rust'});
      expect(response.statusCode, 409);
    });

    test('404s for a topic that does not exist', () async {
      expect((await send('PUT', '/api/topics/999', {'name': 'x'})).statusCode,
          404);
      expect((await send('DELETE', '/api/topics/999', null)).statusCode, 404);
      expect((await get('/api/topics/999/cards')).statusCode, 404);
    });
  });

  group('cards', () {
    late int topicId;

    setUp(() async {
      topicId = await db.createTopic(name: 'Rust');
    });

    test('creates a card that is new, due, and correctly scheduled', () async {
      final response = await send('POST', '/api/cards', {
        'topicId': topicId,
        'front': 'What is a lifetime?',
        'back': 'A region of code…',
        'tags': ['ownership', 'lifetimes'],
      });
      expect(response.statusCode, 201);

      final card = await json(response);
      expect(card['front'], 'What is a lifetime?');
      expect(card['tags'], ['ownership', 'lifetimes']);
      expect(card['isNew'], isTrue);
      expect(card['isDue'], isTrue);

      // It must be a real FSRS-ready row, not just text.
      final stored = (await db.allCards()).single;
      expect(stored.state.value, 1);
      expect(stored.step, 0);
    });

    test('a bad topicId is a 400, not a 500', () async {
      final missing = await send(
          'POST', '/api/cards', {'front': 'Q', 'topicId': 4242});
      expect(missing.statusCode, 400);
      expect((await json(missing))['error'], contains('topic'));

      final absent = await send('POST', '/api/cards', {'front': 'Q'});
      expect(absent.statusCode, 400);
      expect((await json(absent))['error'], contains('topicId'));
    });

    test('an empty front is a 400', () async {
      final response =
          await send('POST', '/api/cards', {'topicId': topicId, 'front': '  '});
      expect(response.statusCode, 400);
    });

    test('malformed JSON is a 400', () async {
      final response = await handler(Request(
        'POST',
        url('/api/cards'),
        body: '{not json',
        headers: {'Content-Type': 'application/json'},
      ));
      expect(response.statusCode, 400);
      expect((await json(response))['error'], contains('Malformed'));
    });

    test('filters by topic and search term', () async {
      final other = await db.createTopic(name: 'DSA');
      await db.insertCard(newCardCompanion(
          topicId: topicId, front: 'borrow checker', back: ''));
      await db.insertCard(
          newCardCompanion(topicId: other, front: 'quicksort', back: ''));

      final byTopic = await json(await get('/api/cards?topicId=$topicId'));
      expect(byTopic['cards'], hasLength(1));
      expect((byTopic['cards'] as List).first['front'], 'borrow checker');

      final bySearch = await json(await get('/api/cards?q=quick'));
      expect(bySearch['cards'], hasLength(1));

      final all = await json(await get('/api/cards'));
      expect(all['cards'], hasLength(2));
    });

    test('editing does not disturb the review schedule', () async {
      final id = await db.insertCard(
          newCardCompanion(topicId: topicId, front: 'Q', back: 'A'));
      final before = (await db.cardById(id))!;

      await send('PUT', '/api/cards/$id', {'back': 'A revised'});

      final after = (await db.cardById(id))!;
      expect(after.back, 'A revised');
      expect(after.dueUtc, before.dueUtc);
      expect(after.fsrsState, before.fsrsState);
      expect(after.reps, before.reps);
    });

    test('moving a card to a nonexistent topic is a 400', () async {
      final id = await db.insertCard(
          newCardCompanion(topicId: topicId, front: 'Q', back: 'A'));
      final response =
          await send('PUT', '/api/cards/$id', {'topicId': 9999});
      expect(response.statusCode, 400);
    });

    test('non-numeric ids are a 400', () async {
      expect((await get('/api/topics/abc/cards')).statusCode, 400);
    });
  });

  group('export and import over HTTP', () {
    test('export returns a downloadable document', () async {
      final topicId = await db.createTopic(name: 'Rust');
      await db.insertCard(
          newCardCompanion(topicId: topicId, front: 'Q', back: 'A'));

      final response = await get('/api/export');
      expect(response.statusCode, 200);
      expect(response.headers['content-disposition'], contains('attachment'));

      final body = jsonDecode(await response.readAsString());
      expect(body['app'], 'memapp');
      expect((body['topics'] as List).first['cards'], hasLength(1));
    });

    test('import merges by default and reports what happened', () async {
      final payload = {
        'app': 'memapp',
        'version': 1,
        'topics': [
          {
            'name': 'Imported',
            'cards': [
              {'front': 'Q1', 'back': 'A1'},
              {'front': 'Q2', 'back': 'A2'},
            ],
          },
        ],
      };

      final response = await send('POST', '/api/import', payload);
      expect(response.statusCode, 200);
      expect((await json(response))['cardsAdded'], 2);
      expect(await db.allCards(), hasLength(2));

      // Same file again: nothing new, nothing lost.
      final again = await json(await send('POST', '/api/import', payload));
      expect(again['cardsAdded'], 0);
      expect(again['cardsSkipped'], 2);
      expect(await db.allCards(), hasLength(2));
    });

    test('replace mode wipes first', () async {
      final topicId = await db.createTopic(name: 'Old');
      await db.insertCard(
          newCardCompanion(topicId: topicId, front: 'gone', back: ''));

      await send('POST', '/api/import?mode=replace', {
        'topics': [
          {
            'name': 'New',
            'cards': [
              {'front': 'kept', 'back': ''}
            ],
          },
        ],
      });

      expect((await db.allTopics()).single.name, 'New');
      expect((await db.allCards()).single.front, 'kept');
    });

    test('a garbage import body is a 400', () async {
      final response = await handler(Request(
        'POST',
        url('/api/import'),
        body: 'this is not json',
      ));
      expect(response.statusCode, 400);
    });

    test('an empty import body is a 400', () async {
      final response =
          await handler(Request('POST', url('/api/import'), body: ''));
      expect(response.statusCode, 400);
    });
  });

  group('plumbing', () {
    test('health and stats report the real database contents', () async {
      final topicId = await db.createTopic(name: 'Rust');
      await db.insertCard(
          newCardCompanion(topicId: topicId, front: 'Q', back: 'A'));

      expect((await json(await get('/api/health')))['ok'], isTrue);

      final stats = await json(await get('/api/stats'));
      expect(stats['topics'], 1);
      expect(stats['cards'], 1);
      expect(stats['due'], 1);
      expect(stats['new'], 1);
    });

    test('CORS headers are present and preflight succeeds', () async {
      final response = await get('/api/health');
      expect(response.headers['access-control-allow-origin'], '*');

      final preflight = await handler(Request('OPTIONS', url('/api/cards')));
      expect(preflight.statusCode, 200);
    });

    test('an unknown path is a 404, not a crash', () async {
      expect((await get('/api/nope')).statusCode, 404);
    });
  });
}
