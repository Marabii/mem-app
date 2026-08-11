import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../services/ai/ai_client.dart';
import '../services/ai/quiz_service.dart';
import '../services/export_service.dart';
import '../services/notification_service.dart';
import '../services/scheduler_service.dart';
import '../services/settings_service.dart';
import '../services/web_server/web_server_service.dart';

/// Both are supplied by `ProviderScope(overrides: ...)` in `main.dart`, where
/// they can be constructed asynchronously before the first frame.
final databaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

final settingsServiceProvider = Provider<SettingsService>(
  (ref) => throw UnimplementedError('settingsServiceProvider must be overridden'),
);

class SettingsController extends StateNotifier<AppSettings> {
  SettingsController(this._service) : super(_service.load());

  final SettingsService _service;

  Future<void> update(AppSettings next) async {
    state = next;
    await _service.save(next);
  }

  Future<void> edit(AppSettings Function(AppSettings) change) =>
      update(change(state));
}

final settingsProvider =
    StateNotifierProvider<SettingsController, AppSettings>((ref) {
  return SettingsController(ref.watch(settingsServiceProvider));
});

/// Rebuilt whenever FSRS tuning changes, so the next rating uses the new
/// parameters without any explicit refresh.
final schedulerServiceProvider = Provider<SchedulerService>((ref) {
  return SchedulerService(
    ref.watch(databaseProvider),
    ref.watch(settingsProvider),
  );
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService(ref.watch(databaseProvider));
});

final exportServiceProvider = Provider<ExportService>((ref) {
  return ExportService(ref.watch(databaseProvider));
});

final quizServiceProvider = Provider<QuizService>((ref) {
  return QuizService(
    ref.watch(databaseProvider),
    ref.watch(schedulerServiceProvider),
  );
});

final webServerServiceProvider = Provider<WebServerService>((ref) {
  final service = WebServerService(ref.watch(databaseProvider));
  ref.onDispose(service.dispose);
  return service;
});

final webServerStateProvider = StreamProvider<WebServerState>((ref) {
  final service = ref.watch(webServerServiceProvider);
  return service.stateStream;
});

// ------------------------------------------------------------------- data

final topicStatsProvider = StreamProvider<List<TopicStats>>((ref) {
  return ref.watch(databaseProvider).watchTopicStats();
});

final topicsProvider = StreamProvider<List<Topic>>((ref) {
  return ref.watch(databaseProvider).watchTopics();
});

/// Identity matters here — Riverpod families key on equality.
class CardQuery {
  const CardQuery({this.topicId, this.search = ''});

  final int? topicId;
  final String search;

  @override
  bool operator ==(Object other) =>
      other is CardQuery && other.topicId == topicId && other.search == search;

  @override
  int get hashCode => Object.hash(topicId, search);
}

final cardsProvider =
    StreamProvider.family<List<MemCard>, CardQuery>((ref, query) {
  return ref
      .watch(databaseProvider)
      .watchCards(topicId: query.topicId, query: query.search);
});

final dueCountProvider = StreamProvider.family<int, int?>((ref, topicId) {
  return ref.watch(databaseProvider).watchDueCount(topicId: topicId);
});

final quizHistoryProvider = StreamProvider<List<QuizSession>>((ref) {
  return ref.watch(databaseProvider).watchQuizSessions();
});

// --------------------------------------------------------------------- AI

/// Kept out of [settingsProvider] because it lives in encrypted storage rather
/// than SharedPreferences.
final apiKeyProvider = FutureProvider<String>((ref) {
  return ref.watch(settingsServiceProvider).readApiKey();
});

/// Null when the user has not configured a base URL and model yet — every AI
/// screen renders a "not configured" state in that case rather than failing.
final aiClientProvider = Provider<AiClient?>((ref) {
  final settings = ref.watch(settingsProvider);
  if (!settings.aiConfigured) return null;
  final key = ref.watch(apiKeyProvider).valueOrNull ?? '';
  return AiClient(
    baseUrl: settings.aiBaseUrl,
    apiKey: key,
    model: settings.aiModel,
    temperature: settings.aiTemperature,
    timeout: Duration(seconds: settings.aiTimeoutSeconds),
  );
});

/// Called after anything that changes what is due: reviews, edits, imports,
/// settings changes.
Future<void> refreshReminders(Ref ref) async {
  final settings = ref.read(settingsProvider);
  await ref.read(notificationServiceProvider).rescheduleReminders(settings);
}

/// Widget-side variant of [refreshReminders].
Future<void> refreshRemindersFrom(WidgetRef ref) async {
  final settings = ref.read(settingsProvider);
  await ref.read(notificationServiceProvider).rescheduleReminders(settings);
}
