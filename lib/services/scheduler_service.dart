import 'package:drift/drift.dart';
import 'package:fsrs/fsrs.dart' as fsrs;

import '../data/database.dart';
import '../data/fsrs_mapping.dart';
import 'settings_service.dart';

/// The result of grading one card, carrying enough state to undo it.
class ReviewOutcome {
  const ReviewOutcome({
    required this.card,
    required this.logId,
    required this.interval,
    required this.wasLapse,
  });

  final MemCard card;
  final int logId;
  final Duration interval;
  final bool wasLapse;
}

/// Wraps `fsrs.Scheduler` and owns every write to a card's scheduling columns.
class SchedulerService {
  SchedulerService(this._db, AppSettings settings) {
    updateSettings(settings);
  }

  final AppDatabase _db;
  late fsrs.Scheduler _scheduler;

  fsrs.Scheduler get scheduler => _scheduler;

  void updateSettings(AppSettings s) {
    _scheduler = fsrs.Scheduler(
      desiredRetention: s.desiredRetention.clamp(0.7, 0.98),
      maximumInterval: s.maximumIntervalDays,
      enableFuzzing: s.enableFuzzing,
      learningSteps: s.learningStepsMinutes
          .map((m) => Duration(minutes: m))
          .toList(growable: false),
      relearningSteps: s.relearningStepsMinutes
          .map((m) => Duration(minutes: m))
          .toList(growable: false),
    );
  }

  /// What each button would do, without touching the database.
  ///
  /// A fresh `fsrs.Card` per rating: the package's card fields are mutable and
  /// reusing one instance across the four calls would compound the outcomes.
  Map<fsrs.Rating, Duration> previewIntervals(MemCard card) {
    final now = DateTime.now().toUtc();
    return {
      for (final rating in fsrs.Rating.values)
        rating: _scheduler
            .reviewCard(card.toFsrsCard(), rating, reviewDateTime: now)
            .card
            .due
            .difference(now),
    };
  }

  double retrievability(MemCard card) =>
      _scheduler.getCardRetrievability(card.toFsrsCard());

  /// Grades [card] and persists the new schedule plus a review log atomically.
  Future<ReviewOutcome> rate(
    MemCard card,
    fsrs.Rating rating, {
    Duration? timeSpent,
  }) async {
    final now = DateTime.now().toUtc();
    final stateBefore = card.state;
    final result = _scheduler.reviewCard(
      card.toFsrsCard(),
      rating,
      reviewDateTime: now,
      reviewDuration: timeSpent?.inMilliseconds,
    );
    final updated = result.card;
    final interval = updated.due.difference(now);
    final wasLapse =
        rating == fsrs.Rating.again && stateBefore == fsrs.State.review;

    late final int logId;
    late final MemCard saved;
    await _db.transaction(() async {
      await (_db.update(_db.cards)..where((c) => c.id.equals(card.id))).write(
        updated.toSchedulingCompanion().copyWith(
              reps: Value(card.reps + 1),
              lapses: Value(card.lapses + (wasLapse ? 1 : 0)),
            ),
      );
      logId = await _db.insertReviewLog(ReviewLogsCompanion.insert(
        cardId: card.id,
        rating: rating.value,
        reviewedAtUtc: now,
        stateBefore: stateBefore.value,
        durationMs: Value(timeSpent?.inMilliseconds),
        stabilityAfter: Value(updated.stability),
        difficultyAfter: Value(updated.difficulty),
        scheduledDays: Value(interval.inDays),
      ));
      saved = (await _db.cardById(card.id))!;
    });

    return ReviewOutcome(
      card: saved,
      logId: logId,
      interval: interval,
      wasLapse: wasLapse,
    );
  }

  /// Restores a pre-review snapshot and drops the log row it produced.
  Future<void> undo(MemCard snapshot, int logId) async {
    await _db.transaction(() async {
      await (_db.update(_db.cards)..where((c) => c.id.equals(snapshot.id)))
          .write(CardsCompanion(
        fsrsState: Value(snapshot.fsrsState),
        step: Value(snapshot.step),
        stability: Value(snapshot.stability),
        difficulty: Value(snapshot.difficulty),
        dueUtc: Value(snapshot.dueUtc),
        lastReviewUtc: Value(snapshot.lastReviewUtc),
        reps: Value(snapshot.reps),
        lapses: Value(snapshot.lapses),
        updatedAt: Value(DateTime.now()),
      ));
      await _db.deleteLog(logId);
    });
  }

  /// Sends a card back to the start of the learning queue. Used by the quiz
  /// results screen for questions the user got wrong.
  Future<void> resetToLearning(int cardId) async {
    await (_db.update(_db.cards)..where((c) => c.id.equals(cardId)))
        .write(CardsCompanion(
      fsrsState: Value(fsrs.State.learning.value),
      step: const Value(0),
      stability: const Value.absent(),
      difficulty: const Value.absent(),
      dueUtc: Value(DateTime.now().toUtc()),
      updatedAt: Value(DateTime.now()),
    ));
  }
}
