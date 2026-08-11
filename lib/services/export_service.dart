import 'dart:convert';

import 'package:drift/drift.dart';

import '../data/database.dart';
import '../data/fsrs_mapping.dart';

enum ImportMode {
  /// Keep what is here; add what is missing. Existing cards keep their
  /// schedules — the safest option and the default.
  merge,

  /// Delete everything first, then load the file verbatim.
  replace,
}

class ImportSummary {
  const ImportSummary({
    required this.topicsAdded,
    required this.cardsAdded,
    required this.cardsSkipped,
    required this.logsAdded,
    required this.mode,
  });

  final int topicsAdded;
  final int cardsAdded;
  final int cardsSkipped;
  final int logsAdded;
  final ImportMode mode;

  String get message {
    final parts = <String>[
      '$topicsAdded ${topicsAdded == 1 ? 'topic' : 'topics'}',
      '$cardsAdded ${cardsAdded == 1 ? 'card' : 'cards'}',
    ];
    final base = 'Imported ${parts.join(', ')}';
    return cardsSkipped > 0
        ? '$base · $cardsSkipped already present, left untouched'
        : base;
  }
}

class ImportException implements Exception {
  const ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads and writes the app's whole dataset as a single JSON document.
///
/// The `fsrs` block on each card is exactly `fsrs.Card.toMap()` minus the id,
/// so a round-trip preserves scheduling to the second.
class ExportService {
  ExportService(this._db);

  final AppDatabase _db;

  static const formatVersion = 1;

  Future<Map<String, dynamic>> buildExport() async {
    final topics = await _db.allTopics();
    final cards = await _db.allCards();
    final logs = await _db.allLogs();

    final cardsByTopic = <int, List<MemCard>>{};
    for (final c in cards) {
      cardsByTopic.putIfAbsent(c.topicId, () => []).add(c);
    }
    final logsByCard = <int, List<CardReview>>{};
    for (final l in logs) {
      logsByCard.putIfAbsent(l.cardId, () => []).add(l);
    }

    return {
      'app': 'memapp',
      'version': formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'topics': [
        for (final t in topics)
          {
            'name': t.name,
            'description': t.description,
            'color': t.colorValue,
            'sortOrder': t.sortOrder,
            'cards': [
              for (final c in cardsByTopic[t.id] ?? const <MemCard>[])
                {
                  'front': c.front,
                  'back': c.back,
                  'tags': c.tagList,
                  'fsrs': {
                    'state': c.fsrsState,
                    'step': c.step,
                    'stability': c.stability,
                    'difficulty': c.difficulty,
                    'due': c.dueUtc.toUtc().toIso8601String(),
                    'lastReview': c.lastReviewUtc?.toUtc().toIso8601String(),
                  },
                  'reps': c.reps,
                  'lapses': c.lapses,
                  'suspended': c.suspended,
                  'createdAt': c.createdAt.toUtc().toIso8601String(),
                  'reviewLogs': [
                    for (final l in logsByCard[c.id] ?? const <CardReview>[])
                      {
                        'rating': l.rating,
                        'reviewedAt': l.reviewedAtUtc.toUtc().toIso8601String(),
                        'durationMs': l.durationMs,
                        'stateBefore': l.stateBefore,
                        'stabilityAfter': l.stabilityAfter,
                        'difficultyAfter': l.difficultyAfter,
                        'scheduledDays': l.scheduledDays,
                      },
                  ],
                },
            ],
          },
      ],
    };
  }

  Future<String> buildExportJson({bool pretty = true}) async {
    final data = await buildExport();
    return pretty
        ? const JsonEncoder.withIndent('  ').convert(data)
        : jsonEncode(data);
  }

  String suggestedFileName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'memapp-${now.year}-${two(now.month)}-${two(now.day)}.json';
  }

  // ------------------------------------------------------------------ import

  Future<ImportSummary> importJson(
    String raw, {
    ImportMode mode = ImportMode.merge,
  }) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const ImportException('That file is not valid JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ImportException(
          'Expected a MemApp export object at the top level.');
    }
    return importData(decoded, mode: mode);
  }

  Future<ImportSummary> importData(
    Map<String, dynamic> data, {
    ImportMode mode = ImportMode.merge,
  }) async {
    final topicsRaw = data['topics'];
    if (topicsRaw is! List) {
      throw const ImportException(
          'This does not look like a MemApp export — no "topics" list.');
    }
    final version = data['version'];
    if (version is int && version > formatVersion) {
      throw ImportException(
          'This file was written by a newer version of MemApp (format $version).');
    }

    var topicsAdded = 0;
    var cardsAdded = 0;
    var cardsSkipped = 0;
    var logsAdded = 0;

    await _db.transaction(() async {
      if (mode == ImportMode.replace) await _db.wipeAll();

      for (final topicRaw in topicsRaw) {
        if (topicRaw is! Map) continue;
        final name = (topicRaw['name'] as String?)?.trim();
        if (name == null || name.isEmpty) continue;

        var topic = await _db.topicByName(name);
        int topicId;
        if (topic == null) {
          topicId = await _db.createTopic(
            name: name,
            description: topicRaw['description'] as String?,
            colorValue: _asInt(topicRaw['color']) ?? 0xFF6366F1,
          );
          topicsAdded++;
        } else {
          topicId = topic.id;
        }

        // Cheap dedupe key for merges: a card is "the same card" if its
        // question text matches inside the same topic.
        final existingFronts = mode == ImportMode.merge
            ? (await _db.getCards(topicId: topicId))
                .map((c) => c.front.trim())
                .toSet()
            : <String>{};

        final cardsRaw = topicRaw['cards'];
        if (cardsRaw is! List) continue;

        for (final cardRaw in cardsRaw) {
          if (cardRaw is! Map) continue;
          final front = (cardRaw['front'] as String?)?.trim() ?? '';
          final back = (cardRaw['back'] as String?)?.trim() ?? '';
          if (front.isEmpty && back.isEmpty) continue;

          if (existingFronts.contains(front)) {
            cardsSkipped++;
            continue;
          }
          existingFronts.add(front);

          final fsrsRaw = cardRaw['fsrs'];
          final fsrs = fsrsRaw is Map ? fsrsRaw : const {};
          final now = DateTime.now();

          final cardId = await _db.insertCard(CardsCompanion.insert(
            topicId: topicId,
            front: front,
            back: back,
            tags: Value(_asTags(cardRaw['tags'])),
            fsrsState: Value(_asInt(fsrs['state']) ?? 1),
            step: Value(_asInt(fsrs['step'])),
            stability: Value(_asDouble(fsrs['stability'])),
            difficulty: Value(_asDouble(fsrs['difficulty'])),
            dueUtc: _asDate(fsrs['due']) ?? now.toUtc(),
            lastReviewUtc: Value(_asDate(fsrs['lastReview'])),
            reps: Value(_asInt(cardRaw['reps']) ?? 0),
            lapses: Value(_asInt(cardRaw['lapses']) ?? 0),
            suspended: Value(cardRaw['suspended'] == true),
            createdAt: Value(_asDate(cardRaw['createdAt']) ?? now),
            updatedAt: Value(now),
          ));
          cardsAdded++;

          final logsRaw = cardRaw['reviewLogs'];
          if (logsRaw is! List) continue;
          for (final logRaw in logsRaw) {
            if (logRaw is! Map) continue;
            final reviewedAt = _asDate(logRaw['reviewedAt']);
            final rating = _asInt(logRaw['rating']);
            if (reviewedAt == null || rating == null) continue;
            await _db.insertReviewLog(ReviewLogsCompanion.insert(
              cardId: cardId,
              rating: rating,
              reviewedAtUtc: reviewedAt,
              stateBefore: _asInt(logRaw['stateBefore']) ?? 1,
              durationMs: Value(_asInt(logRaw['durationMs'])),
              stabilityAfter: Value(_asDouble(logRaw['stabilityAfter'])),
              difficultyAfter: Value(_asDouble(logRaw['difficultyAfter'])),
              scheduledDays: Value(_asInt(logRaw['scheduledDays']) ?? 0),
            ));
            logsAdded++;
          }
        }
      }
    });

    if (topicsAdded == 0 && cardsAdded == 0 && cardsSkipped == 0) {
      throw const ImportException('That file contained no cards to import.');
    }

    return ImportSummary(
      topicsAdded: topicsAdded,
      cardsAdded: cardsAdded,
      cardsSkipped: cardsSkipped,
      logsAdded: logsAdded,
      mode: mode,
    );
  }

  // Exports written by other tools are not guaranteed to use our exact types,
  // so every field is coerced rather than cast.
  static int? _asInt(Object? v) => switch (v) {
        final int i => i,
        final double d => d.round(),
        final String s => int.tryParse(s),
        _ => null,
      };

  static double? _asDouble(Object? v) => switch (v) {
        final double d => d,
        final int i => i.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };

  static DateTime? _asDate(Object? v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toUtc();
  }

  static String _asTags(Object? v) => switch (v) {
        final List<Object?> l =>
          l.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).join(','),
        final String s => s,
        _ => '',
      };
}
