import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/database.dart';
import 'settings_service.dart';

/// All reminders are computed and scheduled on the device. There is no push
/// service, no server, and nothing to configure.
///
/// `zonedSchedule` bakes its text in at scheduling time, but "how many cards
/// are due" changes every day. So instead of one repeating notification we
/// schedule the next [_horizonDays] days individually with per-day counts, and
/// rebuild that window whenever the data changes (app start/resume, end of a
/// review session, card edits, imports).
class NotificationService {
  NotificationService(this._db);

  final AppDatabase _db;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _reviewChannelId = 'memapp_reviews';
  static const _serverChannelId = 'memapp_server';

  /// Reminder ids occupy [_baseId, _baseId + _horizonDays).
  static const _baseId = 1000;
  static const _horizonDays = 7;
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
  Future<void> rescheduleReminders(AppSettings settings) async {
    await init();
    for (var i = 0; i < _horizonDays; i++) {
      await _plugin.cancel(id: _baseId + i);
    }
    if (!settings.remindersEnabled) return;

    final now = tz.TZDateTime.now(tz.local);

    for (var dayOffset = 0; dayOffset < _horizonDays; dayOffset++) {
      var fireAt = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day + dayOffset,
        settings.reminderHour,
        settings.reminderMinute,
      );
      if (!fireAt.isAfter(now)) continue;

      // Cards due *at that moment*, not right now — a card due in three days
      // should count towards day 3's reminder, not today's.
      final counts = await _db.dueCountsAt(fireAt.toUtc());
      final total = counts.fold<int>(0, (sum, e) => sum + e.due);
      if (total == 0) continue;

      await _plugin.zonedSchedule(
        id: _baseId + dayOffset,
        title: total == 1 ? '1 card due' : '$total cards due',
        body: _breakdown(counts),
        scheduledDate: fireAt,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _reviewChannelId,
            'Review reminders',
            channelDescription:
                'Daily nudge listing how many cards are due.',
            importance: Importance.high,
            priority: Priority.high,
            styleInformation: BigTextStyleInformation(''),
          ),
        ),
        payload: 'review',
      );
    }
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
