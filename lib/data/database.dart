import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

part 'database.g.dart';

/// A subject the user is studying — "Rust", "DSA", "Neuroanatomy".
class Topics extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 120)();
  TextColumn get description => text().nullable()();
  IntColumn get colorValue => integer().withDefault(const Constant(0xFF6366F1))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {name},
      ];
}

/// A single question/answer pair.
///
/// The generated row class is `MemCard`, not `Card`, so it never collides with
/// Flutter's `Card` widget in UI files.
///
/// The [fsrsState]/[step]/[stability]/[difficulty]/[dueUtc]/[lastReviewUtc]
/// columns are a flat mirror of `fsrs.Card.toMap()`. Nothing outside
/// `fsrs_mapping.dart` should read or write them directly.
@DataClassName('MemCard')
class Cards extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get topicId =>
      integer().references(Topics, #id, onDelete: KeyAction.cascade)();
  TextColumn get front => text()();
  TextColumn get back => text()();

  /// Comma-separated. Empty string means untagged.
  TextColumn get tags => text().withDefault(const Constant(''))();

  // --- FSRS state ---
  IntColumn get fsrsState => integer().withDefault(const Constant(1))();
  IntColumn get step => integer().nullable()();
  RealColumn get stability => real().nullable()();
  RealColumn get difficulty => real().nullable()();
  DateTimeColumn get dueUtc => dateTime()();
  DateTimeColumn get lastReviewUtc => dateTime().nullable()();

  // --- Bookkeeping FSRS does not track itself ---
  IntColumn get reps => integer().withDefault(const Constant(0))();
  IntColumn get lapses => integer().withDefault(const Constant(0))();
  BoolColumn get suspended => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

/// One row per grading. Drives the struggle analysis behind AI quizzes.
/// Named `CardReview` to stay distinct from `fsrs.ReviewLog`.
@DataClassName('CardReview')
class ReviewLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get cardId =>
      integer().references(Cards, #id, onDelete: KeyAction.cascade)();
  IntColumn get rating => integer()();
  DateTimeColumn get reviewedAtUtc => dateTime()();
  IntColumn get durationMs => integer().nullable()();
  IntColumn get stateBefore => integer()();
  RealColumn get stabilityAfter => real().nullable()();
  RealColumn get difficultyAfter => real().nullable()();

  /// Days until the card came due again after this grading.
  IntColumn get scheduledDays => integer().withDefault(const Constant(0))();
}

class QuizSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get topicId => integer().nullable()();
  TextColumn get topicName => text().withDefault(const Constant('All topics'))();
  TextColumn get difficulty => text()();
  DateTimeColumn get createdAtUtc => dateTime()();
  RealColumn get score => real().withDefault(const Constant(0))();
  IntColumn get totalQuestions => integer().withDefault(const Constant(0))();
  TextColumn get feedback => text().withDefault(const Constant(''))();
  BoolColumn get completed => boolean().withDefault(const Constant(false))();
}

class QuizQuestions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sessionId =>
      integer().references(QuizSessions, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();

  /// `mcq` or `short`.
  TextColumn get kind => text()();
  TextColumn get prompt => text()();

  /// JSON array of strings, MCQ only.
  TextColumn get optionsJson => text().nullable()();
  IntColumn get correctIndex => integer().nullable()();
  TextColumn get expectedAnswer => text().nullable()();
  TextColumn get userAnswer => text().nullable()();
  BoolColumn get isCorrect => boolean().nullable()();
  RealColumn get awardedScore => real().nullable()();
  TextColumn get explanation => text().nullable()();
  IntColumn get sourceCardId => integer().nullable()();
}

/// Per-topic counts shown on the home screen.
class TopicStats {
  const TopicStats({
    required this.topic,
    required this.total,
    required this.due,
    required this.fresh,
    required this.suspended,
  });

  final Topic topic;
  final int total;

  /// Unsuspended cards whose due date has passed.
  final int due;

  /// Cards that have never been reviewed.
  final int fresh;
  final int suspended;

  int get studied => total - fresh;
  double get progress => total == 0 ? 0 : studied / total;
}

@DriftDatabase(
  tables: [Topics, Cards, ReviewLogs, QuizSessions, QuizQuestions],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  /// In-memory instance for tests.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_cards_topic_due ON cards (topic_id, due_utc)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_logs_card ON review_logs (card_id)');
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  // ---------------------------------------------------------------- topics

  Stream<List<Topic>> watchTopics() =>
      (select(topics)..orderBy([(t) => OrderingTerm(expression: t.sortOrder), (t) => OrderingTerm(expression: t.name)]))
          .watch();

  Future<List<Topic>> allTopics() =>
      (select(topics)..orderBy([(t) => OrderingTerm(expression: t.sortOrder), (t) => OrderingTerm(expression: t.name)]))
          .get();

  Future<Topic?> topicById(int id) =>
      (select(topics)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Topic?> topicByName(String name) =>
      (select(topics)..where((t) => t.name.equals(name))).getSingleOrNull();

  Future<int> createTopic({
    required String name,
    String? description,
    int colorValue = 0xFF6366F1,
  }) =>
      into(topics).insert(TopicsCompanion.insert(
        name: name,
        description: Value(description),
        colorValue: Value(colorValue),
        createdAt: Value(DateTime.now()),
      ));

  Future<bool> updateTopic(Topic topic) => update(topics).replace(topic);

  Future<int> deleteTopic(int id) =>
      (delete(topics)..where((t) => t.id.equals(id))).go();

  /// Reactive topic list with due/new counts, recomputed whenever either table
  /// changes. `readsFrom` is what makes the home screen self-updating while the
  /// web server writes to the same database.
  Stream<List<TopicStats>> watchTopicStats() {
    final now = DateTime.now();
    return customSelect(
      '''
      SELECT t.*,
        (SELECT COUNT(*) FROM cards c WHERE c.topic_id = t.id) AS total,
        (SELECT COUNT(*) FROM cards c WHERE c.topic_id = t.id
           AND c.suspended = 0 AND c.due_utc <= ?) AS due_count,
        (SELECT COUNT(*) FROM cards c WHERE c.topic_id = t.id AND c.reps = 0) AS fresh,
        (SELECT COUNT(*) FROM cards c WHERE c.topic_id = t.id AND c.suspended = 1) AS susp
      FROM topics t
      ORDER BY t.sort_order ASC, t.name COLLATE NOCASE ASC
      ''',
      variables: [Variable.withDateTime(now)],
      readsFrom: {topics, cards},
    ).watch().map((rows) => rows
        .map((r) => TopicStats(
              topic: topics.map(r.data),
              total: r.read<int>('total'),
              due: r.read<int>('due_count'),
              fresh: r.read<int>('fresh'),
              suspended: r.read<int>('susp'),
            ))
        .toList());
  }

  // ----------------------------------------------------------------- cards

  Stream<List<MemCard>> watchCards({int? topicId, String query = ''}) {
    final q = select(cards);
    if (topicId != null) q.where((c) => c.topicId.equals(topicId));
    if (query.trim().isNotEmpty) {
      final like = '%${query.trim()}%';
      q.where((c) =>
          c.front.like(like) | c.back.like(like) | c.tags.like(like));
    }
    q.orderBy([(c) => OrderingTerm(expression: c.dueUtc)]);
    return q.watch();
  }

  Future<List<MemCard>> getCards({int? topicId, String query = ''}) {
    final q = select(cards);
    if (topicId != null) q.where((c) => c.topicId.equals(topicId));
    if (query.trim().isNotEmpty) {
      final like = '%${query.trim()}%';
      q.where((c) =>
          c.front.like(like) | c.back.like(like) | c.tags.like(like));
    }
    q.orderBy([(c) => OrderingTerm(expression: c.dueUtc)]);
    return q.get();
  }

  Future<MemCard?> cardById(int id) =>
      (select(cards)..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<List<MemCard>> allCards() => select(cards).get();

  Future<int> insertCard(CardsCompanion entry) => into(cards).insert(entry);

  Future<bool> updateCard(MemCard card) =>
      update(cards).replace(card.copyWith(updatedAt: DateTime.now()));

  Future<int> deleteCard(int id) =>
      (delete(cards)..where((c) => c.id.equals(id))).go();

  Future<void> setSuspended(int id, bool value) =>
      (update(cards)..where((c) => c.id.equals(id)))
          .write(CardsCompanion(
        suspended: Value(value),
        updatedAt: Value(DateTime.now()),
      ));

  /// The study queue: due, unsuspended, oldest-due first.
  Future<List<MemCard>> dueCards({int? topicId, int limit = 200}) {
    final q = select(cards)
      ..where((c) =>
          c.suspended.equals(false) &
          c.dueUtc.isSmallerOrEqualValue(DateTime.now()))
      ..orderBy([(c) => OrderingTerm(expression: c.dueUtc)])
      ..limit(limit);
    if (topicId != null) q.where((c) => c.topicId.equals(topicId));
    return q.get();
  }

  Stream<int> watchDueCount({int? topicId}) {
    final countExp = cards.id.count();
    final q = selectOnly(cards)..addColumns([countExp]);
    q.where(cards.suspended.equals(false) &
        cards.dueUtc.isSmallerOrEqualValue(DateTime.now()));
    if (topicId != null) q.where(cards.topicId.equals(topicId));
    return q.map((r) => r.read(countExp) ?? 0).watchSingle();
  }

  /// Due counts per topic at an arbitrary instant. Used to write the body text
  /// of each scheduled reminder ("12 cards due — Rust (7), DSA (5)").
  Future<List<({String topic, int due})>> dueCountsAt(DateTime instant) async {
    final rows = await customSelect(
      '''
      SELECT t.name AS name, COUNT(c.id) AS due_count
      FROM topics t
      JOIN cards c ON c.topic_id = t.id
      WHERE c.suspended = 0 AND c.due_utc <= ?
      GROUP BY t.id
      HAVING due_count > 0
      ORDER BY due_count DESC
      ''',
      variables: [Variable.withDateTime(instant)],
      readsFrom: {topics, cards},
    ).get();
    return rows
        .map((r) => (topic: r.read<String>('name'), due: r.read<int>('due_count')))
        .toList();
  }

  // ----------------------------------------------------------- review logs

  Future<int> insertReviewLog(ReviewLogsCompanion entry) =>
      into(reviewLogs).insert(entry);

  Future<List<CardReview>> logsForCard(int cardId, {int limit = 20}) =>
      (select(reviewLogs)
            ..where((l) => l.cardId.equals(cardId))
            ..orderBy([
              (l) => OrderingTerm(
                  expression: l.reviewedAtUtc, mode: OrderingMode.desc)
            ])
            ..limit(limit))
          .get();

  Future<List<CardReview>> allLogs() => select(reviewLogs).get();

  Future<int> deleteLog(int id) =>
      (delete(reviewLogs)..where((l) => l.id.equals(id))).go();

  /// Reviews per day for the last [days] days, for the stats strip.
  Future<Map<DateTime, int>> reviewsPerDay({int days = 30}) async {
    final since = DateTime.now().subtract(Duration(days: days));
    final rows = await customSelect(
      '''
      SELECT DATE(reviewed_at_utc, 'unixepoch', 'localtime') AS day,
             COUNT(*) AS n
      FROM review_logs
      WHERE reviewed_at_utc >= ?
      GROUP BY day ORDER BY day
      ''',
      variables: [Variable.withDateTime(since)],
      readsFrom: {reviewLogs},
    ).get();
    return {
      for (final r in rows) DateTime.parse(r.read<String>('day')): r.read<int>('n'),
    };
  }

  // ----------------------------------------------------------------- quiz

  Future<int> insertQuizSession(QuizSessionsCompanion entry) =>
      into(quizSessions).insert(entry);

  Future<void> updateQuizSession(QuizSession session) =>
      update(quizSessions).replace(session);

  Future<int> insertQuizQuestion(QuizQuestionsCompanion entry) =>
      into(quizQuestions).insert(entry);

  Future<void> updateQuizQuestion(QuizQuestion question) =>
      update(quizQuestions).replace(question);

  Stream<List<QuizSession>> watchQuizSessions() => (select(quizSessions)
        ..where((s) => s.completed.equals(true))
        ..orderBy([
          (s) => OrderingTerm(
              expression: s.createdAtUtc, mode: OrderingMode.desc)
        ])
        ..limit(50))
      .watch();

  Future<List<QuizQuestion>> questionsForSession(int sessionId) =>
      (select(quizQuestions)
            ..where((q) => q.sessionId.equals(sessionId))
            ..orderBy([(q) => OrderingTerm(expression: q.position)]))
          .get();

  Future<int> deleteQuizSession(int id) =>
      (delete(quizSessions)..where((s) => s.id.equals(id))).go();

  // ------------------------------------------------------------ wholesale

  /// Used by "Replace" imports. Order matters: children before parents even
  /// with cascades on, because the quiz tables have no FK to cards.
  Future<void> wipeAll() async {
    await transaction(() async {
      await delete(quizQuestions).go();
      await delete(quizSessions).go();
      await delete(reviewLogs).go();
      await delete(cards).go();
      await delete(topics).go();
    });
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'memapp.sqlite'));

    // Required for sqlite3 to work reliably on older Android releases.
    await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
    sqlite3.tempDirectory = (await getTemporaryDirectory()).path;

    return NativeDatabase.createInBackground(file);
  });
}
