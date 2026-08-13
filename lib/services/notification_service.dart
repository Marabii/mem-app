import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/database.dart';
import 'reminder_plan.dart';
import 'settings_service.dart';

/// All reminders are computed and scheduled on the device. There is no push
/// service, no server, and nothing to configure.
///
/// `zonedSchedule` bakes its text in at scheduling time, but "how many cards
/// are due" changes every day. So instead of one repeating notification the
/// app lays down a window of concrete alarms — see [ReminderPlan] — each with
/// the count that will be due at that moment, and rebuilds the window whenever
/// the data changes (app start/resume, end of a review session, card edits,
/// imports).
class NotificationService {
  NotificationService(this._db);

  final AppDatabase _db;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _reviewChannelId = 'memapp_reviews';
  static const _nudgeChannelId = 'memapp_nudges';
  static const _serverChannelId = 'memapp_server';

  static const _serverNotificationId = 2000;
  static const _testNotificationId = 2001;

  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;

    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (e) {
      // Falls back to UTC. Reminders still fire, just against UTC wall-clock.
      debugPrint('MemApp: could not resolve local timezone ($e)');
    }

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _reviewChannelId,
      'Review reminders',
      description: 'Daily nudge listing how many cards are due.',
      importance: Importance.high,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _nudgeChannelId,
      'Evening nudges',
      description:
          'Follow-ups before midnight while cards are still waiting. Turn this '
          'channel off to keep the daily reminder and drop the rest.',
      importance: Importance.high,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _serverChannelId,
      'Web server',
      description: 'Shown while the on-device web server is running.',
      importance: Importance.low,
    ));

    _ready = true;
  }

  // ------------------------------------------------------------ permissions

  Future<bool> requestPermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    final notifications = await android.requestNotificationsPermission() ?? false;
    // Exact alarms are what keep the reminder on time under Doze. Denial is not
    // fatal — inexact delivery still happens, just within a wider window.
    await android.requestExactAlarmsPermission();
    return notifications;
  }

  Future<bool> hasPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.areNotificationsEnabled() ?? false;
  }

  // -------------------------------------------------------------- reminders

  /// Cancels the current reminder window and lays down a fresh one.
  ///
  /// Called often (every resume, every card edit, the end of every session),
  /// so the cancel pass only touches ids this app scheduled and only those
  /// that actually exist.
  Future<void> rescheduleReminders(AppSettings settings) async {
    await init();
    await _clearWindow();
    if (!settings.remindersEnabled) return;

    final plan = ReminderPlan.build(
      settings: settings,
      now: DateTime.now(),
    );

    for (final reminder in plan) {
      final fireAt = tz.TZDateTime(
        tz.local,
        reminder.at.year,
        reminder.at.month,
        reminder.at.day,
        reminder.at.hour,
        reminder.at.minute,
      );

      // Cards due *at that moment*, not right now — a card due in three days
      // belongs to day 3's reminder, and a nudge is worth sending only if the
      // work is still outstanding when it fires. Reviewing rebuilds this
      // window, so cleared cards never produce a nudge.
      final counts = await _db.dueCountsAt(fireAt.toUtc());
      final total = counts.fold<int>(0, (sum, e) => sum + e.due);
      if (total == 0) continue;

      await _plugin.zonedSchedule(
        id: reminder.id,
        title: _title(reminder, total),
        body: _body(reminder, counts),
        scheduledDate: fireAt,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        notificationDetails: _detailsFor(reminder),
        payload: 'review',
      );
    }
  }

  /// Drops both the alarms that have not fired yet and any nudge still sitting
  /// in the shade — including the final one, which is posted as ongoing and so
  /// cannot be swiped away by hand.
  Future<void> _clearWindow() async {
    final pending = await _plugin.pendingNotificationRequests();
    for (final request in pending) {
      if (ReminderPlan.ownsId(request.id)) await _plugin.cancel(id: request.id);
    }
    try {
      final active = await _plugin.getActiveNotifications();
      for (final notification in active) {
        final id = notification.id;
        if (id != null && ReminderPlan.ownsId(id)) await _plugin.cancel(id: id);
      }
    } catch (e) {
      // getActiveNotifications is Android 6+; a failure here is not worth
      // aborting a reschedule over.
      debugPrint('MemApp: could not list active notifications ($e)');
    }
  }

  String _title(PlannedReminder reminder, int total) {
    final cards = total == 1 ? '1 card' : '$total cards';
    return switch (reminder.kind) {
      ReminderKind.daily => '$cards due',
      ReminderKind.nudge when reminder.isFinal => 'Last call — $cards due',
      ReminderKind.nudge => '$cards still due',
    };
  }

  String _body(
    PlannedReminder reminder,
    List<({String topic, int due})> counts,
  ) {
    final breakdown = _breakdown(counts);
    if (reminder.kind == ReminderKind.daily) return breakdown;
    final left = ReminderPlan.describeTimeLeft(reminder.minutesToMidnight);
    return reminder.isFinal
        ? '$breakdown · $left before midnight'
        : '$breakdown · $left left today';
  }

  NotificationDetails _detailsFor(PlannedReminder reminder) {
    if (reminder.kind == ReminderKind.daily) {
      return const NotificationDetails(
        android: AndroidNotificationDetails(
          _reviewChannelId,
          'Review reminders',
          channelDescription: 'Daily nudge listing how many cards are due.',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          styleInformation: BigTextStyleInformation(''),
        ),
      );
    }

    return NotificationDetails(
      android: AndroidNotificationDetails(
        _nudgeChannelId,
        'Evening nudges',
        channelDescription:
            'Follow-ups before midnight while cards are still waiting.',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        styleInformation: const BigTextStyleInformation(''),
        // The last one of the night stays put until the app is opened, rather
        // than being swiped away and forgotten.
        ongoing: reminder.isFinal,
        autoCancel: true,
      ),
    );
  }

  /// "Rust (7) · DSA (5)", truncated so the line stays readable.
  String _breakdown(List<({String topic, int due})> counts) {
    if (counts.isEmpty) return 'Time to review.';
    const maxShown = 3;
    final shown =
        counts.take(maxShown).map((e) => '${e.topic} (${e.due})').join(' · ');
    final remaining = counts.length - maxShown;
    return remaining > 0 ? '$shown  +$remaining more' : shown;
  }

  Future<void> sendTestNotification() async {
    await init();
    final counts = await _db.dueCountsAt(DateTime.now().toUtc());
    final total = counts.fold<int>(0, (sum, e) => sum + e.due);
    await _plugin.show(
      id: _testNotificationId,
      title: total == 0 ? 'Nothing due right now' : '$total cards due',
      body: total == 0
          ? 'Reminders are working — this is what they will look like.'
          : _breakdown(counts),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _reviewChannelId,
          'Review reminders',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }

  // ----------------------------------------------------------- server badge

  /// Ongoing, non-dismissable note that the LAN server is live. It also makes
  /// Android less eager to freeze the process while someone is editing from a
  /// browser.
  Future<void> showServerRunning(String url) async {
    await init();
    await _plugin.show(
      id: _serverNotificationId,
      title: 'MemApp server running',
      body: '$url — reachable by anyone on this Wi-Fi network',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _serverChannelId,
          'Web server',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          showWhen: false,
        ),
      ),
    );
  }

  Future<void> hideServerRunning() =>
      _plugin.cancel(id: _serverNotificationId);

  Future<void> cancelAll() => _plugin.cancelAll();
}
