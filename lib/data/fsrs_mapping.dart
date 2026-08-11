import 'package:drift/drift.dart' show Value;
import 'package:fsrs/fsrs.dart' as fsrs;

import 'database.dart';

/// The only place that translates between database rows and the FSRS package.
///
/// The conversion deliberately round-trips through `fsrs.Card.fromMap` /
/// `toMap` using the package's own key names rather than calling the
/// constructor directly, so a change to the package's internals surfaces as a
/// single obvious failure here instead of silently mis-scheduling cards.
extension MemCardFsrs on MemCard {
  Map<String, dynamic> toFsrsMap() => <String, dynamic>{
        'cardId': id,
        'state': fsrsState,
        'step': step,
        'stability': stability,
        'difficulty': difficulty,
        'due': dueUtc.toUtc().toIso8601String(),
        'lastReview': lastReviewUtc?.toUtc().toIso8601String(),
      };

  /// A fresh, detached FSRS card. `fsrs.Card`'s fields are mutable and
  /// `reviewCard` may write to its argument, so callers that need more than one
  /// hypothetical outcome (the four rating previews) must call this per rating.
  fsrs.Card toFsrsCard() => fsrs.Card.fromMap(toFsrsMap());

  fsrs.State get state => fsrs.State.fromValue(fsrsState);

  bool get isDue => !suspended && !dueUtc.toUtc().isAfter(DateTime.now().toUtc());

  bool get isNew => reps == 0;

  List<String> get tagList => tags
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
}

extension FsrsCardToDb on fsrs.Card {
  /// Only the scheduling columns — reps/lapses are the caller's business.
  CardsCompanion toSchedulingCompanion() => CardsCompanion(
        fsrsState: Value(state.value),
        step: Value(step),
        stability: Value(stability),
        difficulty: Value(difficulty),
        dueUtc: Value(due.toUtc()),
        lastReviewUtc: Value(lastReview?.toUtc()),
        updatedAt: Value(DateTime.now()),
      );
}

extension RatingLabel on fsrs.Rating {
  String get label => switch (this) {
        fsrs.Rating.again => 'Again',
        fsrs.Rating.hard => 'Hard',
        fsrs.Rating.good => 'Good',
        fsrs.Rating.easy => 'Easy',
      };
}

extension StateLabel on fsrs.State {
  String get label => switch (this) {
        fsrs.State.learning => 'Learning',
        fsrs.State.review => 'Review',
        fsrs.State.relearning => 'Relearning',
      };
}

/// A card that has never been seen: learning state, step 0, due immediately.
CardsCompanion newCardCompanion({
  required int topicId,
  required String front,
  required String back,
  String tags = '',
}) {
  final now = DateTime.now();
  return CardsCompanion.insert(
    topicId: topicId,
    front: front,
    back: back,
    tags: Value(tags),
    fsrsState: Value(fsrs.State.learning.value),
    step: const Value(0),
    dueUtc: now.toUtc(),
    createdAt: Value(now),
    updatedAt: Value(now),
  );
}

/// Human-readable interval, e.g. "<1m", "10m", "3d", "2.4mo", "1.2y".
String formatInterval(Duration d) {
  if (d.isNegative || d.inSeconds < 60) return '<1m';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  final days = d.inHours / 24;
  if (days < 30) {
    return days < 10 ? '${days.toStringAsFixed(days.truncateToDouble() == days ? 0 : 1)}d' : '${days.round()}d';
  }
  if (days < 365) return '${(days / 30.4).toStringAsFixed(1)}mo';
  return '${(days / 365).toStringAsFixed(1)}y';
}
