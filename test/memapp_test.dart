import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:sqlite3/open.dart';
import 'package:flutter_application_1/data/database.dart';
import 'package:flutter_application_1/data/fsrs_mapping.dart';
import 'package:flutter_application_1/services/ai/ai_client.dart';
import 'package:flutter_application_1/services/ai/quiz_service.dart';
import 'package:flutter_application_1/services/export_service.dart';
import 'package:flutter_application_1/services/scheduler_service.dart';
import 'package:flutter_application_1/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsrs/fsrs.dart' as fsrs;

/// On Android the app links sqlite3 via sqlite3_flutter_libs. Desktop test
/// runners have no bundled copy, and many Linux boxes ship only the versioned
/// `libsqlite3.so.0` without the `-dev` symlink, so point the loader at it.
void _useSystemSqlite() {
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
}

void main() {
  late AppDatabase db;
  late SchedulerService scheduler;

  setUpAll(_useSystemSqlite);

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    scheduler = SchedulerService(db, const AppSettings());
  });

  tearDown(() async => db.close());

  Future<MemCard> addCard(
    int topicId, {
    String front = 'Q',
    String back = 'A',
  }) async {
    final id = await db.insertCard(
        newCardCompanion(topicId: topicId, front: front, back: back));
    return (await db.cardById(id))!;
  }

  group('FSRS mapping', () {
    test('round-trips a card through the database without drift', () async {
      final topicId = await db.createTopic(name: 'Rust');
      var card = await addCard(topicId);

      // Put the card through a real review so every FSRS field is populated.
      await scheduler.rate(card, fsrs.Rating.good);
      card = (await db.cardById(card.id))!;

      final fsrsCard = card.toFsrsCard();
      final map = fsrsCard.toMap();

      expect(map['cardId'], card.id);
      expect(map['state'], card.fsrsState);
      expect(map['stability'], card.stability);
      expect(map['difficulty'], card.difficulty);
      expect(DateTime.parse(map['due'] as String).toUtc(),
          card.dueUtc.toUtc());

      // Rebuilding from the map must produce an identical FSRS card.
      expect(fsrs.Card.fromMap(map).toMap(), map);
    });

    test('a new card starts in learning at step 0 and is due now', () async {
      final topicId = await db.createTopic(name: 'DSA');
      final card = await addCard(topicId);

      expect(card.state, fsrs.State.learning);
      expect(card.step, 0);
      expect(card.isNew, isTrue);
      expect(card.isDue, isTrue);
      expect(card.stability, isNull);
    });
  });

  group('scheduling', () {
    test('repeated Good ratings produce growing intervals', () async {
      final topicId = await db.createTopic(name: 'Rust');
      var card = await addCard(topicId);

      final intervals = <Duration>[];
      for (var i = 0; i < 4; i++) {
        final outcome = await scheduler.rate(card, fsrs.Rating.good);
        intervals.add(outcome.interval);
        card = outcome.card;
      }

      expect(card.reps, 4);
      expect(card.state, fsrs.State.review);
      // The last interval must be far longer than the first learning step.
      expect(intervals.last, greaterThan(intervals.first));
      expect(intervals.last.inDays, greaterThanOrEqualTo(1));
    });

    test('Again on a review card records a lapse and relearns it', () async {
      final topicId = await db.createTopic(name: 'Rust');
      var card = await addCard(topicId);

      // Graduate it to the review state first.
      for (var i = 0; i < 3; i++) {
        card = (await scheduler.rate(card, fsrs.Rating.good)).card;
      }
      expect(card.state, fsrs.State.review);
      expect(card.lapses, 0);

      final outcome = await scheduler.rate(card, fsrs.Rating.again);
      expect(outcome.wasLapse, isTrue);
      expect(outcome.card.lapses, 1);
      expect(outcome.card.state, fsrs.State.relearning);
    });

    test('previewIntervals does not mutate the card or the database', () async {
      final topicId = await db.createTopic(name: 'Rust');
      final card = await addCard(topicId);

      final previews = scheduler.previewIntervals(card);
      expect(previews.length, 4);
      expect(previews[fsrs.Rating.easy]!,
          greaterThan(previews[fsrs.Rating.again]!));

      final reloaded = (await db.cardById(card.id))!;
      expect(reloaded.reps, 0);
      expect(reloaded.dueUtc, card.dueUtc);
      expect(await db.allLogs(), isEmpty);
    });

    test('undo restores the pre-review state and drops the log', () async {
      final topicId = await db.createTopic(name: 'Rust');
      final card = await addCard(topicId);

      final outcome = await scheduler.rate(card, fsrs.Rating.easy);
      expect(await db.allLogs(), hasLength(1));

      await scheduler.undo(card, outcome.logId);

      final restored = (await db.cardById(card.id))!;
      expect(restored.reps, 0);
      expect(restored.stability, isNull);
      expect(restored.dueUtc, card.dueUtc);
      expect(await db.allLogs(), isEmpty);
    });

    test('rate writes exactly one log row per grading', () async {
      final topicId = await db.createTopic(name: 'Rust');
      final card = await addCard(topicId);

      await scheduler.rate(card, fsrs.Rating.hard,
          timeSpent: const Duration(seconds: 4));

      final logs = await db.logsForCard(card.id);
      expect(logs, hasLength(1));
      expect(logs.single.rating, fsrs.Rating.hard.value);
      expect(logs.single.durationMs, 4000);
      expect(logs.single.stateBefore, fsrs.State.learning.value);
    });
  });

  group('due queries', () {
    test('suspended cards are excluded from the queue', () async {
      final topicId = await db.createTopic(name: 'Rust');
      final card = await addCard(topicId);

      expect(await db.dueCards(), hasLength(1));
      await db.setSuspended(card.id, true);
      expect(await db.dueCards(), isEmpty);
    });

    test('dueCountsAt groups by topic and skips empty topics', () async {
      final rust = await db.createTopic(name: 'Rust');
      final dsa = await db.createTopic(name: 'DSA');
      await db.createTopic(name: 'Empty');

      await addCard(rust, front: 'a');
      await addCard(rust, front: 'b');
      await addCard(dsa, front: 'c');

      final counts = await db.dueCountsAt(DateTime.now().toUtc());
      expect(counts, hasLength(2));
      expect(counts.first.topic, 'Rust');
      expect(counts.first.due, 2);
      expect(counts.map((c) => c.topic), isNot(contains('Empty')));
    });
  });

  group('export and import', () {
    test('a full round-trip preserves schedules exactly', () async {
      final topicId = await db.createTopic(
          name: 'Rust', description: 'Ownership', colorValue: 0xFF10B981);
      var card = await addCard(topicId, front: 'Borrow rules?', back: 'One &mut');
      card = (await scheduler.rate(card, fsrs.Rating.good)).card;
      card = (await scheduler.rate(card, fsrs.Rating.hard)).card;

      final service = ExportService(db);
      final json = await service.buildExportJson();

      await db.wipeAll();
      expect(await db.allCards(), isEmpty);

      final summary = await service.importJson(json, mode: ImportMode.replace);
      expect(summary.topicsAdded, 1);
      expect(summary.cardsAdded, 1);

      final restored = (await db.allCards()).single;
      expect(restored.front, card.front);
      expect(restored.back, card.back);
      expect(restored.reps, card.reps);
      expect(restored.stability, closeTo(card.stability!, 1e-9));
      expect(restored.difficulty, closeTo(card.difficulty!, 1e-9));
      expect(restored.dueUtc.toUtc().toIso8601String(),
          card.dueUtc.toUtc().toIso8601String());
      expect(restored.fsrsState, card.fsrsState);

      final logs = await db.logsForCard(restored.id);
      expect(logs, hasLength(2));

      final topic = (await db.allTopics()).single;
      expect(topic.description, 'Ownership');
      expect(topic.colorValue, 0xFF10B981);
    });

    test('merge leaves existing cards and their schedules untouched', () async {
      final topicId = await db.createTopic(name: 'Rust');
      var kept = await addCard(topicId, front: 'Shared question', back: 'Old');
      kept = (await scheduler.rate(kept, fsrs.Rating.easy)).card;

      final incoming = {
        'app': 'memapp',
        'version': 1,
        'topics': [
          {
            'name': 'Rust',
            'cards': [
              {
                'front': 'Shared question',
                'back': 'REPLACED',
                'fsrs': {
                  'state': 1,
                  'due': DateTime.now().toUtc().toIso8601String(),
                },
              },
              {'front': 'Brand new question', 'back': 'New'},
            ],
          },
        ],
      };

      final summary = await ExportService(db)
          .importData(incoming, mode: ImportMode.merge);

      expect(summary.cardsAdded, 1);
      expect(summary.cardsSkipped, 1);
      expect(summary.topicsAdded, 0, reason: 'topic matched by name');

      final reloaded = (await db.cardById(kept.id))!;
      expect(reloaded.back, 'Old', reason: 'existing content is not clobbered');
      expect(reloaded.stability, kept.stability);
      expect(reloaded.dueUtc, kept.dueUtc);
      expect(await db.allCards(), hasLength(2));
    });

    test('rejects files that are not MemApp exports', () async {
      final service = ExportService(db);
      expect(
        () => service.importJson('not json at all'),
        throwsA(isA<ImportException>()),
      );
      expect(
        () => service.importJson('{"hello":"world"}'),
        throwsA(isA<ImportException>()),
      );
      expect(
        () => service.importJson('{"topics":[],"version":99}'),
        throwsA(isA<ImportException>()),
      );
    });

    test('coerces loosely typed fields from third-party files', () async {
      final summary = await ExportService(db).importData({
        'topics': [
          {
            'name': 'Imported',
            'color': '4283215696',
            'cards': [
              {
                'front': 'Q',
                'back': 'A',
                'tags': 'one, two',
                'reps': '3',
                'fsrs': {'state': '2', 'stability': 5, 'difficulty': '4.5'},
              },
            ],
          },
        ],
      });

      expect(summary.cardsAdded, 1);
      final card = (await db.allCards()).single;
      expect(card.reps, 3);
      expect(card.fsrsState, 2);
      expect(card.stability, 5.0);
      expect(card.difficulty, 4.5);
      expect(card.tagList, ['one', 'two']);
    });
  });

  group('struggle analysis', () {
    test('ranks a lapsing card above a clean one', () async {
      final topicId = await db.createTopic(name: 'Rust');
      var struggling = await addCard(topicId, front: 'Hard one');
      var easy = await addCard(topicId, front: 'Easy one');

      // A lapse is only recorded for Again while in the review state, so the
      // card has to graduate out of learning first. Two full cycles.
      for (var cycle = 0; cycle < 2; cycle++) {
        while (struggling.state != fsrs.State.review) {
          struggling = (await scheduler.rate(struggling, fsrs.Rating.good)).card;
        }
        struggling = (await scheduler.rate(struggling, fsrs.Rating.again)).card;
      }
      for (var i = 0; i < 4; i++) {
        easy = (await scheduler.rate(easy, fsrs.Rating.easy)).card;
      }

      expect(struggling.lapses, 2, reason: 'setup should produce real lapses');
      expect(easy.lapses, 0);

      final entries = await QuizService(db, scheduler).analyzeStruggles();
      expect(entries, hasLength(2));
      expect(entries.first.card.front, 'Hard one');
      expect(entries.first.score, greaterThan(entries.last.score));
      expect(entries.first.reason, contains('lapse'));
    });

    test('unseen cards still surface so a new deck can be quizzed', () async {
      final topicId = await db.createTopic(name: 'Rust');
      await addCard(topicId);

      final entries = await QuizService(db, scheduler).analyzeStruggles();
      expect(entries, hasLength(1));
      expect(entries.single.score, greaterThan(0));
      expect(entries.single.reason, 'not studied yet');
    });

    test('suspended cards are never quizzed', () async {
      final topicId = await db.createTopic(name: 'Rust');
      final card = await addCard(topicId);
      await db.setSuspended(card.id, true);

      expect(await QuizService(db, scheduler).analyzeStruggles(), isEmpty);
    });
  });

  group('model response parsing', () {
    test('accepts bare JSON', () {
      expect(extractJsonObject('{"questions":[1]}'), {
        'questions': [1]
      });
    });

    test('accepts fenced JSON', () {
      const raw = '```json\n{"questions":[{"prompt":"hi"}]}\n```';
      final parsed = extractJsonObject(raw);
      expect((parsed!['questions'] as List).first['prompt'], 'hi');
    });

    test('accepts JSON buried in prose', () {
      const raw =
          'Sure! Here is your quiz:\n{"questions":[{"prompt":"a"}]}\nHope that helps.';
      expect(extractJsonObject(raw), isNotNull);
    });

    test('is not fooled by braces inside strings', () {
      const raw = r'{"prompt":"use the } brace","ok":true}';
      final parsed = extractJsonObject(raw);
      expect(parsed!['ok'], isTrue);
      expect(parsed['prompt'], 'use the } brace');
    });

    test('returns null when there is no JSON at all', () {
      expect(extractJsonObject('I cannot help with that.'), isNull);
    });
  });

  group('AI base URL normalisation', () {
    test('adds scheme and /v1, and tolerates trailing slashes', () {
      expect(AiClient.normalizeBaseUrl('192.168.1.10:1234'),
          'http://192.168.1.10:1234/v1');
      expect(AiClient.normalizeBaseUrl('http://host:1234/v1/'),
          'http://host:1234/v1');
      expect(AiClient.normalizeBaseUrl('https://api.openai.com/v1'),
          'https://api.openai.com/v1');
      expect(AiClient.normalizeBaseUrl(''), '');
    });
  });

  group('interval formatting', () {
    test('scales units with the duration', () {
      expect(formatInterval(const Duration(seconds: 30)), '<1m');
      expect(formatInterval(const Duration(minutes: 10)), '10m');
      expect(formatInterval(const Duration(hours: 5)), '5h');
      expect(formatInterval(const Duration(days: 3)), '3d');
      expect(formatInterval(const Duration(days: 60)), '2.0mo');
      expect(formatInterval(const Duration(days: 730)), '2.0y');
    });
  });

  group('cascading deletes', () {
    test('deleting a topic removes its cards and their logs', () async {
      final topicId = await db.createTopic(name: 'Rust');
      final card = await addCard(topicId);
      await scheduler.rate(card, fsrs.Rating.good);

      expect(await db.allCards(), hasLength(1));
      expect(await db.allLogs(), hasLength(1));

      await db.deleteTopic(topicId);

      expect(await db.allCards(), isEmpty);
      expect(await db.allLogs(), isEmpty);
    });
  });
}
