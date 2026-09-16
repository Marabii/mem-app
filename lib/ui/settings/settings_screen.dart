import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/export_service.dart';
import '../../services/file_channel.dart';
import '../../services/reminder_plan.dart';
import '../../services/settings_service.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import 'ai_settings_screen.dart';
import 'scheduling_screen.dart';
import 'server_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final serverState = ref.watch(webServerStateProvider).valueOrNull;
    final doneToday =
        ref.watch(remindersDoneTodayProvider).valueOrNull ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
          children: [
            const SectionHeader('Reminders'),
            SettingsGroup(children: [
              SwitchListTile(
                value: settings.remindersEnabled,
                title: const Text('Daily review reminder'),
                subtitle: Text(
                  !settings.remindersEnabled
                      ? 'Off'
                      : doneToday
                          ? 'Every day at '
                              '${settings.reminderTime.format(context)} · '
                              'silent for the rest of today, you are done'
                          : 'Every day at '
                              '${settings.reminderTime.format(context)}',
                ),
                onChanged: _toggleReminders,
              ),
              ListTile(
                enabled: settings.remindersEnabled,
                leading: const Icon(Icons.schedule),
                title: const Text('Reminder time'),
                trailing: Text(
                  settings.reminderTime.format(context),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                onTap: settings.remindersEnabled ? _pickTime : null,
              ),
              SwitchListTile(
                value: settings.eveningNudgesEnabled,
                secondary: const Icon(Icons.bedtime_outlined),
                title: const Text('Keep nudging until midnight'),
                subtitle: Text(settings.eveningNudgesEnabled
                    ? '${settings.eveningNudgeCount} more reminders across the '
                        'last ${settings.eveningNudgeWindowHours} '
                        '${settings.eveningNudgeWindowHours == 1 ? 'hour' : 'hours'} '
                        'of the day, only while cards you have not seen today '
                        'are still waiting'
                    : 'One reminder a day, and that is it'),
                onChanged: settings.remindersEnabled ? _toggleNudges : null,
              ),
              ListTile(
                enabled: settings.remindersEnabled &&
                    settings.eveningNudgesEnabled,
                leading: const Icon(Icons.tune),
                title: const Text('How persistent'),
                subtitle: Text(_nudgeSchedulePreview(settings)),
                onTap: settings.remindersEnabled && settings.eveningNudgesEnabled
                    ? _editNudges
                    : null,
              ),
              ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: const Text('Send a test notification'),
                subtitle: const Text('Confirms permissions are granted'),
                onTap: _sendTest,
              ),
            ]),

            const SectionHeader('Sharing'),
            SettingsGroup(children: [
              ListTile(
                leading: const Icon(Icons.wifi_tethering),
                title: const Text('Web server'),
                subtitle: Text(serverState?.running == true
                    ? 'Running at ${serverState!.url}'
                    : 'Edit your cards from a browser on this Wi-Fi'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ServerScreen()),
                ),
              ),
            ]),

            const SectionHeader('Data'),
            SettingsGroup(children: [
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('Export all cards'),
                subtitle: const Text('Saves a JSON file, schedules included'),
                enabled: !_busy,
                onTap: _export,
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Import cards'),
                subtitle: const Text('Merge into what you have, or replace it'),
                enabled: !_busy,
                onTap: _import,
              ),
            ]),

            const SectionHeader('AI quizzes'),
            SettingsGroup(children: [
              ListTile(
                leading: const Icon(Icons.smart_toy_outlined),
                title: const Text('Model connection'),
                subtitle: Text(settings.aiConfigured
                    ? '${settings.aiModel} · ${settings.aiBaseUrl}'
                    : 'Not configured'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
                ),
              ),
            ]),

            const SectionHeader('Scheduling'),
            SettingsGroup(children: [
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('FSRS tuning'),
                subtitle: Text(
                    '${(settings.desiredRetention * 100).round()}% target retention · '
                    '${settings.sessionLimit} cards per session'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SchedulingScreen()),
                ),
              ),
            ]),

            const SectionHeader('Appearance'),
            RadioGroup<ThemeMode>(
              groupValue: settings.themeMode,
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .edit((s) => s.copyWith(themeMode: v)),
              child: SettingsGroup(children: [
                for (final mode in ThemeMode.values)
                  RadioListTile<ThemeMode>(
                    value: mode,
                    title: Text(switch (mode) {
                      ThemeMode.system => 'Follow system',
                      ThemeMode.light => 'Light',
                      ThemeMode.dark => 'Dark',
                    }),
                  ),
              ]),
            ),

            const SectionHeader('About'),
            SettingsGroup(children: [
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('MemApp'),
                subtitle: Text(
                  'Spaced repetition with FSRS. Everything — scheduling, '
                  'storage, reminders and the web server — runs on this device. '
                  'No account, no backend.',
                ),
                isThreeLine: true,
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- reminders

  Future<void> _toggleReminders(bool value) async {
    final controller = ref.read(settingsProvider.notifier);

    if (value) {
      final notifications = ref.read(notificationServiceProvider);
      await notifications.init();
      final granted = await notifications.requestPermissions();
      if (!granted) {
        if (!mounted) return;
        showSnack(
          context,
          'Notification permission was denied. Enable it in Android settings '
          'to get reminders.',
          isError: true,
        );
        return;
      }
    }

    await controller.edit((s) => s.copyWith(remindersEnabled: value));
    if (!mounted) return;
    await refreshRemindersFrom(ref);
    if (!mounted) return;
    showSnack(context, value ? 'Reminders on' : 'Reminders off');
  }

  Future<void> _pickTime() async {
    final settings = ref.read(settingsProvider);
    final picked = await showTimePicker(
      context: context,
      initialTime: settings.reminderTime,
    );
    if (picked == null) return;
    await ref.read(settingsProvider.notifier).edit((s) => s.copyWith(
          reminderHour: picked.hour,
          reminderMinute: picked.minute,
        ));
    if (!mounted) return;
    await refreshRemindersFrom(ref);
  }

  Future<void> _toggleNudges(bool value) async {
    await ref
        .read(settingsProvider.notifier)
        .edit((s) => s.copyWith(eveningNudgesEnabled: value));
    if (!mounted) return;
    await refreshRemindersFrom(ref);
  }

  /// "22:00, 22:30, 23:00, 23:30" — what the current settings actually produce.
  String _nudgeSchedulePreview(AppSettings settings) {
    if (!settings.eveningNudgesEnabled) return 'Off';
    // Built from a fixed day so the preview shows the whole evening rather
    // than only the nudges still ahead of the current time.
    final plan = ReminderPlan.build(
      settings: settings.copyWith(remindersEnabled: true),
      now: DateTime(2000),
    ).where((r) => r.kind == ReminderKind.nudge).take(8);

    final times = plan.map((r) => TimeOfDay.fromDateTime(r.at).format(context));
    return times.join(', ');
  }

  Future<void> _editNudges() async {
    final settings = ref.read(settingsProvider);
    var hours = settings.eveningNudgeWindowHours;
    var count = settings.eveningNudgeCount;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final theme = Theme.of(context);
          final preview = _nudgeSchedulePreview(settings.copyWith(
            eveningNudgesEnabled: true,
            eveningNudgeWindowHours: hours,
            eveningNudgeCount: count,
          ));

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Evening nudges',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    'Sent only while cards you have not already answered today '
                    'are waiting. Clearing the queue silences the rest of the '
                    'day, learning-step repeats included.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 18),
                  Text('Window before midnight',
                      style: theme.textTheme.labelLarge),
                  Slider(
                    value: hours.toDouble(),
                    min: 1,
                    max: 6,
                    divisions: 5,
                    label: '$hours h',
                    onChanged: (v) =>
                        setSheetState(() => hours = v.round()),
                  ),
                  Text('Number of nudges', style: theme.textTheme.labelLarge),
                  Slider(
                    value: count.toDouble(),
                    min: 1,
                    max: 6,
                    divisions: 5,
                    label: '$count',
                    onChanged: (v) => setSheetState(() => count = v.round()),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.notifications_none,
                          size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(preview,
                            style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (saved != true) return;
    await ref.read(settingsProvider.notifier).edit((s) => s.copyWith(
          eveningNudgeWindowHours: hours,
          eveningNudgeCount: count,
        ));
    if (!mounted) return;
    await refreshRemindersFrom(ref);
  }

  Future<void> _sendTest() async {
    final notifications = ref.read(notificationServiceProvider);
    await notifications.init();
    if (!await notifications.hasPermission()) {
      final granted = await notifications.requestPermissions();
      if (!granted) {
        if (!mounted) return;
        showSnack(context, 'Notification permission is off', isError: true);
        return;
      }
    }
    await notifications.sendTestNotification();
    if (!mounted) return;
    showSnack(context, 'Test notification sent');
  }

  // ------------------------------------------------------------------- data

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final service = ref.read(exportServiceProvider);
      final json = await service.buildExportJson();
      final saved = await FileChannel.saveJson(
        fileName: service.suggestedFileName(),
        content: json,
      );
      if (!mounted) return;
      showSnack(context, saved == null ? 'Export cancelled' : 'Export saved');
    } on FileChannelException catch (e) {
      if (mounted) showSnack(context, e.message, isError: true);
    } catch (e) {
      if (mounted) showSnack(context, 'Export failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final raw = await FileChannel.pickJson();
      if (raw == null) return;
      if (!mounted) return;

      final mode = await _askImportMode();
      if (mode == null) return;
      if (mode == ImportMode.replace) {
        if (!mounted) return;
        final confirmed = await confirmDialog(
          context,
          title: 'Replace everything?',
          message:
              'Every topic, card and review record on this device is deleted '
              'before the file is loaded. This cannot be undone.',
          confirmLabel: 'Replace',
        );
        if (!confirmed) return;
      }

      final summary =
          await ref.read(exportServiceProvider).importJson(raw, mode: mode);
      if (!mounted) return;
      await refreshRemindersFrom(ref);
      if (!mounted) return;
      showSnack(context, summary.message);
    } on ImportException catch (e) {
      if (mounted) showSnack(context, e.message, isError: true);
    } on FileChannelException catch (e) {
      if (mounted) showSnack(context, e.message, isError: true);
    } catch (e) {
      if (mounted) showSnack(context, 'Import failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<ImportMode?> _askImportMode() {
    return showModalBottomSheet<ImportMode>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text('How should this file be imported?',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.merge_type),
              title: const Text('Merge'),
              subtitle: const Text(
                  'Add missing topics and cards. Cards you already have keep '
                  'their review schedules.'),
              isThreeLine: true,
              onTap: () => Navigator.pop(context, ImportMode.merge),
            ),
            ListTile(
              leading: Icon(Icons.delete_sweep_outlined,
                  color: Theme.of(context).colorScheme.error),
              title: const Text('Replace'),
              subtitle: const Text('Delete everything here first.'),
              onTap: () => Navigator.pop(context, ImportMode.replace),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
