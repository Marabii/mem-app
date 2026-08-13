import 'package:flutter/foundation.dart';

import 'settings_service.dart';

enum ReminderKind {
  /// The one-a-day reminder at the user's chosen time.
  daily,

  /// A follow-up in the run-up to midnight, for cards that are *still* due.
  nudge,
}

/// One reminder the app intends to schedule: when it fires, which slot it
/// occupies, and how much of the day is left at that point.
@immutable
class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.at,
    required this.kind,
    this.minutesToMidnight = 0,
    this.isFinal = false,
  });

  /// Stable notification id, derived from the day and slot so a reschedule
  /// overwrites the same alarms instead of piling new ones on top.
  final int id;

  /// Local wall-clock time. Converted to a zoned time when scheduled.
  final DateTime at;

  final ReminderKind kind;

  /// Minutes between [at] and the following midnight — the "you have this
  /// long left" figure the nudge text is built from.
  final int minutesToMidnight;

  /// The last nudge of the day, which gets the most insistent treatment.
  final bool isFinal;

  @override
  String toString() => '$kind@$at (id $id)';
}

/// Works out the whole reminder window ahead of time.
///
/// Nothing here touches the notification plugin or the database, because the
/// awkward parts are all arithmetic: which nudges fall in the past, how they
/// space out across the window, and where they collide with the daily
/// reminder.
///
/// Why a window of pre-computed alarms rather than one repeating reminder that
/// checks at fire time: with no server and no background isolate, nothing of
/// ours runs while the phone sits idle. So the app schedules concrete alarms
/// for concrete times, each carrying the count that will be due *then*, and
/// rebuilds the window whenever the data changes — which includes right after
/// a review session, so nudges for cards you have since cleared are dropped.
abstract final class ReminderPlan {
  static const baseId = 1000;
  static const horizonDays = 7;

  /// Ids are `baseId + day * slotsPerDay + slot`, slot 0 being the daily
  /// reminder. The spare slots leave room for the nudge count to grow without
  /// colliding with the next day's block.
  static const slotsPerDay = 8;
  static const maxNudges = slotsPerDay - 1;

  /// Ids in `[baseId, idRangeEnd)` belong to this plan and no one else.
  static const idRangeEnd = baseId + horizonDays * slotsPerDay;

  static bool ownsId(int id) => id >= baseId && id < idRangeEnd;

  static int idFor({required int dayOffset, required int slot}) =>
      baseId + dayOffset * slotsPerDay + slot;

  /// Every reminder that should exist between [now] and the end of the window,
  /// in firing order. Times in the past are left out.
  static List<PlannedReminder> build({
    required AppSettings settings,
    required DateTime now,
  }) {
    final plan = <PlannedReminder>[];
    if (!settings.remindersEnabled) return plan;

    for (var day = 0; day < horizonDays; day++) {
      final date = DateTime(now.year, now.month, now.day + day);

      final daily = DateTime(date.year, date.month, date.day,
          settings.reminderHour, settings.reminderMinute);
      if (daily.isAfter(now)) {
        plan.add(PlannedReminder(
          id: idFor(dayOffset: day, slot: 0),
          at: daily,
          kind: ReminderKind.daily,
        ));
      }

      if (!settings.eveningNudgesEnabled) continue;

      final count = settings.eveningNudgeCount.clamp(1, maxNudges);
      final window = settings.eveningNudgeWindowHours.clamp(1, 6) * 60;
      // Evenly spaced across the window, the first at its start and the last
      // one spacing-minutes short of midnight: 4 over 2 hours gives 22:00,
      // 22:30, 23:00, 23:30.
      final spacing = window / count;

      for (var i = 0; i < count; i++) {
        final left = (window - spacing * i).round();
        final minuteOfDay = 24 * 60 - left;
        // Built from wall-clock fields rather than by subtracting a Duration
        // from midnight, so a daylight-saving jump cannot shift a 22:00 nudge
        // to 21:00.
        final at = DateTime(date.year, date.month, date.day,
            minuteOfDay ~/ 60, minuteOfDay % 60);

        if (!at.isAfter(now)) continue;
        // A nudge landing on the daily reminder would be a duplicate.
        if (at.difference(daily).abs() < const Duration(minutes: 1)) continue;

        plan.add(PlannedReminder(
          id: idFor(dayOffset: day, slot: i + 1),
          at: at,
          kind: ReminderKind.nudge,
          minutesToMidnight: left,
          isFinal: i == count - 1,
        ));
      }
    }

    plan.sort((a, b) => a.at.compareTo(b.at));
    return plan;
  }

  /// "2 hours", "90 minutes" — the tail of "… left today".
  static String describeTimeLeft(int minutes) {
    if (minutes < 60) return '$minutes minutes';
    if (minutes % 60 == 0) {
      final hours = minutes ~/ 60;
      return hours == 1 ? '1 hour' : '$hours hours';
    }
    return '$minutes minutes';
  }
}
