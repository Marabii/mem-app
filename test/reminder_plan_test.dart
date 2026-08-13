import 'package:flutter_application_1/services/reminder_plan.dart';
import 'package:flutter_application_1/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const on = AppSettings(
    remindersEnabled: true,
    reminderHour: 9,
    reminderMinute: 0,
  );

  List<DateTime> nudgeTimes(List<PlannedReminder> plan) => plan
      .where((r) => r.kind == ReminderKind.nudge)
      .map((r) => r.at)
      .toList();

  /// Reminders falling on the given day only, so a seven-day window can be
  /// asserted on one day at a time.
  List<PlannedReminder> onDay(List<PlannedReminder> plan, DateTime day) =>
      plan.where((r) => r.at.day == day.day && r.at.month == day.month).toList();

  test('nothing is planned while reminders are off', () {
    expect(
      ReminderPlan.build(
        settings: const AppSettings(remindersEnabled: false),
        now: DateTime(2026, 8, 13, 8),
      ),
      isEmpty,
    );
  });

  test('the default window is four nudges over the last two hours', () {
    final plan = ReminderPlan.build(
      settings: on,
      now: DateTime(2026, 8, 13, 8),
    );
    final today = onDay(plan, DateTime(2026, 8, 13));

    expect(nudgeTimes(today), [
      DateTime(2026, 8, 13, 22, 0),
      DateTime(2026, 8, 13, 22, 30),
      DateTime(2026, 8, 13, 23, 0),
      DateTime(2026, 8, 13, 23, 30),
    ]);
    expect(today.first.kind, ReminderKind.daily);
    expect(today.first.at, DateTime(2026, 8, 13, 9, 0));
  });

  test('only the last nudge of a day is marked final', () {
    final plan = ReminderPlan.build(
      settings: on,
      now: DateTime(2026, 8, 13, 8),
    );
    final nudges = onDay(plan, DateTime(2026, 8, 13))
        .where((r) => r.kind == ReminderKind.nudge)
        .toList();

    expect(nudges.map((r) => r.isFinal), [false, false, false, true]);
    expect(nudges.last.minutesToMidnight, 30);
    expect(nudges.first.minutesToMidnight, 120);
  });

  test('times already past today are skipped, tomorrow is intact', () {
    final plan = ReminderPlan.build(
      settings: on,
      now: DateTime(2026, 8, 13, 22, 45),
    );

    expect(nudgeTimes(onDay(plan, DateTime(2026, 8, 13))),
        [DateTime(2026, 8, 13, 23, 0), DateTime(2026, 8, 13, 23, 30)]);
    expect(onDay(plan, DateTime(2026, 8, 13)).any((r) => r.kind == ReminderKind.daily),
        isFalse);
    expect(nudgeTimes(onDay(plan, DateTime(2026, 8, 14))), hasLength(4));
  });

  test('the window and the count are configurable', () {
    final plan = ReminderPlan.build(
      settings: on.copyWith(eveningNudgeWindowHours: 3, eveningNudgeCount: 3),
      now: DateTime(2026, 8, 13, 8),
    );

    expect(nudgeTimes(onDay(plan, DateTime(2026, 8, 13))), [
      DateTime(2026, 8, 13, 21, 0),
      DateTime(2026, 8, 13, 22, 0),
      DateTime(2026, 8, 13, 23, 0),
    ]);
  });

  test('turning nudges off leaves one reminder a day', () {
    final plan = ReminderPlan.build(
      settings: on.copyWith(eveningNudgesEnabled: false),
      now: DateTime(2026, 8, 13, 8),
    );

    expect(plan, hasLength(ReminderPlan.horizonDays));
    expect(plan.every((r) => r.kind == ReminderKind.daily), isTrue);
  });

  test('a nudge that lands on the daily reminder is dropped, not duplicated', () {
    // 23:00 daily reminder collides with the third of four nudges.
    final plan = ReminderPlan.build(
      settings: on.copyWith(reminderHour: 23, reminderMinute: 0),
      now: DateTime(2026, 8, 13, 8),
    );
    final today = onDay(plan, DateTime(2026, 8, 13));

    expect(today.where((r) => r.at == DateTime(2026, 8, 13, 23, 0)), hasLength(1));
    expect(today.where((r) => r.at == DateTime(2026, 8, 13, 23, 0)).single.kind,
        ReminderKind.daily);
  });

  test('ids are unique, stable and inside the plan range', () {
    final plan = ReminderPlan.build(
      settings: on.copyWith(eveningNudgeCount: 6),
      now: DateTime(2026, 8, 13, 8),
    );

    final ids = plan.map((r) => r.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids.every(ReminderPlan.ownsId), isTrue);
    expect(ReminderPlan.ownsId(ReminderPlan.idRangeEnd), isFalse);
    // The server badge and the test notification must stay clear of it.
    expect(ReminderPlan.ownsId(2000), isFalse);
    expect(ReminderPlan.ownsId(2001), isFalse);

    final again = ReminderPlan.build(
      settings: on.copyWith(eveningNudgeCount: 6),
      now: DateTime(2026, 8, 13, 8),
    );
    expect(again.map((r) => r.id), ids);
  });

  test('a count beyond the reserved slots is clamped, not overflowed', () {
    final plan = ReminderPlan.build(
      settings: on.copyWith(eveningNudgeCount: 99),
      now: DateTime(2026, 8, 13, 8),
    );
    final nudges = onDay(plan, DateTime(2026, 8, 13))
        .where((r) => r.kind == ReminderKind.nudge);

    expect(nudges, hasLength(ReminderPlan.maxNudges));
    expect(plan.map((r) => r.id).every(ReminderPlan.ownsId), isTrue);
  });

  test('the plan is in firing order', () {
    final plan = ReminderPlan.build(
      settings: on,
      now: DateTime(2026, 8, 13, 8),
    );
    for (var i = 1; i < plan.length; i++) {
      expect(plan[i].at.isAfter(plan[i - 1].at), isTrue);
    }
  });

  test('a nudge just before midnight belongs to that day, not the next', () {
    final plan = ReminderPlan.build(
      settings: on.copyWith(eveningNudgeWindowHours: 1, eveningNudgeCount: 4),
      now: DateTime(2026, 8, 31, 12),
    );

    expect(nudgeTimes(onDay(plan, DateTime(2026, 8, 31))), [
      DateTime(2026, 8, 31, 23, 0),
      DateTime(2026, 8, 31, 23, 15),
      DateTime(2026, 8, 31, 23, 30),
      DateTime(2026, 8, 31, 23, 45),
    ]);
    // …and the month rolls over cleanly.
    expect(nudgeTimes(onDay(plan, DateTime(2026, 9, 1))).first,
        DateTime(2026, 9, 1, 23, 0));
  });

  test('describeTimeLeft reads naturally', () {
    expect(ReminderPlan.describeTimeLeft(120), '2 hours');
    expect(ReminderPlan.describeTimeLeft(60), '1 hour');
    expect(ReminderPlan.describeTimeLeft(90), '90 minutes');
    expect(ReminderPlan.describeTimeLeft(15), '15 minutes');
  });
}
