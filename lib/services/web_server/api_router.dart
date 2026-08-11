import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/services.dart' show rootBundle;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../data/database.dart';
import '../../data/fsrs_mapping.dart';
import '../export_service.dart';

/// Serves the companion web UI and its JSON API.
///
/// Every write goes through the same [AppDatabase] methods the Flutter UI uses,
/// so drift's query streams push browser edits to the phone screen live and
/// vice versa.
class ApiRouter {
  ApiRouter(this._db, this._export);

  final AppDatabase _db;
  final ExportService _export;

  Handler get handler {
    final router = Router()
      ..get('/api/health', _health)
      ..get('/api/stats', _stats)
      ..get('/api/topics', _listTopics)
      ..post('/api/topics', _createTopic)
      ..put('/api/topics/<id>', _updateTopic)
      ..delete('/api/topics/<id>', _deleteTopic)
      ..get('/api/topics/<id>/cards', _cardsForTopic)
      ..get('/api/cards', _listCards)
      ..post('/api/cards', _createCard)
      ..put('/api/cards/<id>', _updateCard)
      ..delete('/api/cards/<id>', _deleteCard)
      ..get('/api/export', _exportAll)
      ..post('/api/import', _importAll)
      ..mount('/', _staticHandler);

    return const Pipeline()
        .addMiddleware(_cors)
        .addMiddleware(_errors)
        .addHandler(router.call);
  }

  // ------------------------------------------------------------ middleware

  /// The server is meant to be opened from a laptop browser on the same
  /// network, so cross-origin requests are allowed outright.
  Middleware get _cors => (inner) => (request) async {
        if (request.method == 'OPTIONS') {
          return Response.ok('', headers: _corsHeaders);
        }
        final response = await inner(request);
        return response.change(headers: _corsHeaders);
      };

  static const _corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };

  /// Turns anything thrown inside a handler into JSON. A stray 500 with an HTML
  /// body would leave the SPA showing nothing useful.
  Middleware get _errors => (inner) => (request) async {
        try {
          return await inner(request);
        } on _ApiError catch (e) {
          return _json({'error': e.message}, status: e.status);
        } catch (e) {
          return _json({'error': e.toString()}, status: 500);
        }
      };

  // -------------------------------------------------------------- handlers

  Response _health(Request _) =>
      _json({'app': 'memapp', 'ok': true, 'version': ExportService.formatVersion});

  Future<Response> _stats(Request _) async {
    final topics = await _db.allTopics();
    final cards = await _db.allCards();
    final now = DateTime.now().toUtc();
    final due = cards
        .where((c) => !c.suspended && !c.dueUtc.toUtc().isAfter(now))
        .length;
    return _json({
      'topics': topics.length,
      'cards': cards.length,
      'due': due,
      'new': cards.where((c) => c.reps == 0).length,
    });
  }

  Future<Response> _listTopics(Request _) async {
    final stats = await _db.watchTopicStats().first;
    return _json({
      'topics': [
        for (final s in stats)
          {
            ..._topicJson(s.topic),
            'total': s.total,
            'due': s.due,
            'new': s.fresh,
          },
      ],
    });
  }

  Future<Response> _createTopic(Request request) async {
    final body = await _body(request);
    final name = (body['name'] as String?)?.trim();
    if (name == null || name.isEmpty) {
      throw const _ApiError('A topic name is required', 400);
    }
    if (await _db.topicByName(name) != null) {
      throw const _ApiError('A topic with that name already exists', 409);
    }
    final id = await _db.createTopic(
      name: name,
      description: (body['description'] as String?)?.trim(),
      colorValue: _asInt(body['color']) ?? 0xFF6366F1,
    );
    return _json(_topicJson((await _db.topicById(id))!), status: 201);
  }

  Future<Response> _updateTopic(Request request, String id) async {
    final topic = await _db.topicById(_id(id));
    if (topic == null) throw const _ApiError('No such topic', 404);
    final body = await _body(request);
    final name = (body['name'] as String?)?.trim();
    if (name != null && name.isEmpty) {
      throw const _ApiError('A topic name is required', 400);
    }
    await _db.updateTopic(topic.copyWith(
      name: name ?? topic.name,
      description: Value((body['description'] as String?)?.trim() ??
          topic.description),
      colorValue: _asInt(body['color']) ?? topic.colorValue,
    ));
    return _json(_topicJson((await _db.topicById(topic.id))!));
  }

  Future<Response> _deleteTopic(Request _, String id) async {
    final removed = await _db.deleteTopic(_id(id));
    if (removed == 0) throw const _ApiError('No such topic', 404);
    return _json({'deleted': removed});
  }

  Future<Response> _cardsForTopic(Request _, String id) async {
    final topicId = _id(id);
    if (await _db.topicById(topicId) == null) {
      throw const _ApiError('No such topic', 404);
    }
    final cards = await _db.getCards(topicId: topicId);
    return _json({'cards': cards.map(_cardJson).toList()});
  }

  Future<Response> _listCards(Request request) async {
    final params = request.url.queryParameters;
    final topicId = _asInt(params['topicId']);
    var cards = await _db.getCards(
      topicId: topicId,
      query: params['q'] ?? '',
    );
    final offset = _asInt(params['offset']) ?? 0;
    final limit = _asInt(params['limit']);
    if (offset > 0) cards = cards.skip(offset).toList();
    if (limit != null) cards = cards.take(limit).toList();
    return _json({'cards': cards.map(_cardJson).toList()});
  }

  Future<Response> _createCard(Request request) async {
    final body = await _body(request);
    final topicId = _asInt(body['topicId']);
    if (topicId == null) throw const _ApiError('topicId is required', 400);
    if (await _db.topicById(topicId) == null) {
      throw const _ApiError('No such topic', 400);
    }
    final front = (body['front'] as String?)?.trim() ?? '';
    final back = (body['back'] as String?)?.trim() ?? '';
    if (front.isEmpty) throw const _ApiError('front is required', 400);

    final id = await _db.insertCard(newCardCompanion(
      topicId: topicId,
      front: front,
      back: back,
      tags: _tagsOf(body['tags']),
    ));
    return _json(_cardJson((await _db.cardById(id))!), status: 201);
  }

  Future<Response> _updateCard(Request request, String id) async {
    final card = await _db.cardById(_id(id));
    if (card == null) throw const _ApiError('No such card', 404);
    final body = await _body(request);

    final topicId = _asInt(body['topicId']) ?? card.topicId;
    if (topicId != card.topicId && await _db.topicById(topicId) == null) {
      throw const _ApiError('No such topic', 400);
    }
    final front = (body['front'] as String?)?.trim() ?? card.front;
    if (front.isEmpty) throw const _ApiError('front cannot be empty', 400);

    await _db.updateCard(card.copyWith(
      topicId: topicId,
      front: front,
      back: (body['back'] as String?)?.trim() ?? card.back,
      tags: body.containsKey('tags') ? _tagsOf(body['tags']) : card.tags,
      suspended: body['suspended'] is bool
          ? body['suspended'] as bool
          : card.suspended,
    ));
    return _json(_cardJson((await _db.cardById(card.id))!));
  }

  Future<Response> _deleteCard(Request _, String id) async {
    final removed = await _db.deleteCard(_id(id));
    if (removed == 0) throw const _ApiError('No such card', 404);
    return _json({'deleted': removed});
  }

  Future<Response> _exportAll(Request _) async {
    final data = await _export.buildExport();
    return Response.ok(
      const JsonEncoder.withIndent('  ').convert(data),
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Disposition':
            'attachment; filename="${_export.suggestedFileName()}"',
      },
    );
  }

  Future<Response> _importAll(Request request) async {
    final mode = request.url.queryParameters['mode'] == 'replace'
        ? ImportMode.replace
        : ImportMode.merge;
    final raw = await request.readAsString();
    if (raw.trim().isEmpty) throw const _ApiError('Empty request body', 400);
    try {
      final summary = await _export.importJson(raw, mode: mode);
      return _json({
        'message': summary.message,
        'topicsAdded': summary.topicsAdded,
        'cardsAdded': summary.cardsAdded,
        'cardsSkipped': summary.cardsSkipped,
      });
    } on ImportException catch (e) {
      throw _ApiError(e.message, 400);
    }
  }

  // ----------------------------------------------------- static web assets

  /// Serves `assets/web/` straight out of the Flutter bundle — nothing is
  /// unpacked to disk, and it works with no network access.
  Future<Response> _staticHandler(Request request) async {
    var path = request.url.path;
    if (path.isEmpty || path == '/') path = 'index.html';
    if (path.contains('..')) return Response.notFound('Not found');

    try {
      final data = await rootBundle.load('assets/web/$path');
      return Response.ok(
        data.buffer.asUint8List(
            data.offsetInBytes, data.lengthInBytes),
        headers: {
          'Content-Type': _contentType(path),
          'Cache-Control': 'no-cache',
        },
      );
    } catch (_) {
      return Response.notFound('Not found');
    }
  }

  static String _contentType(String path) {
    if (path.endsWith('.html')) return 'text/html; charset=utf-8';
    if (path.endsWith('.css')) return 'text/css; charset=utf-8';
    if (path.endsWith('.js')) return 'application/javascript; charset=utf-8';
    if (path.endsWith('.json')) return 'application/json; charset=utf-8';
    if (path.endsWith('.svg')) return 'image/svg+xml';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.ico')) return 'image/x-icon';
    return 'application/octet-stream';
  }

  // --------------------------------------------------------------- helpers

  Map<String, dynamic> _topicJson(Topic t) => {
        'id': t.id,
        'name': t.name,
        'description': t.description,
        'color': t.colorValue,
      };

  Map<String, dynamic> _cardJson(MemCard c) => {
        'id': c.id,
        'topicId': c.topicId,
        'front': c.front,
        'back': c.back,
        'tags': c.tagList,
        'state': c.fsrsState,
        'due': c.dueUtc.toUtc().toIso8601String(),
        'reps': c.reps,
        'lapses': c.lapses,
        'suspended': c.suspended,
        'isDue': c.isDue,
        'isNew': c.isNew,
      };

  Future<Map<String, dynamic>> _body(Request request) async {
    final raw = await request.readAsString();
    if (raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const _ApiError('Expected a JSON object', 400);
      }
      return decoded;
    } on FormatException {
      throw const _ApiError('Malformed JSON', 400);
    }
  }

  static int _id(String raw) {
    final id = int.tryParse(raw);
    if (id == null) throw const _ApiError('Invalid id', 400);
    return id;
  }

  static int? _asInt(Object? v) => switch (v) {
        final int i => i,
        final double d => d.round(),
        final String s => int.tryParse(s),
        _ => null,
      };

  static String _tagsOf(Object? v) => switch (v) {
        final List<Object?> l =>
          l.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).join(','),
        final String s => s.trim(),
        _ => '',
      };

  static Response _json(Object? body, {int status = 200}) => Response(
        status,
        body: jsonEncode(body),
        headers: {'Content-Type': 'application/json; charset=utf-8'},
      );
}

class _ApiError implements Exception {
  const _ApiError(this.message, this.status);
  final String message;
  final int status;
}
