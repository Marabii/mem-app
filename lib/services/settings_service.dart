import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Everything the user can tune. Plain value type so it can be diffed and
/// persisted in one shot.
@immutable
class AppSettings {
  const AppSettings({
    this.remindersEnabled = false,
    this.reminderHour = 9,
    this.reminderMinute = 0,
    this.desiredRetention = 0.9,
    this.maximumIntervalDays = 36500,
    this.enableFuzzing = true,
    this.learningStepsMinutes = const [1, 10],
    this.relearningStepsMinutes = const [10],
    this.sessionLimit = 100,
    this.serverPort = 8080,
    this.themeMode = ThemeMode.system,
    this.aiBaseUrl = '',
    this.aiModel = '',
    this.aiTemperature = 0.4,
    this.aiTimeoutSeconds = 180,
  });

  final bool remindersEnabled;
  final int reminderHour;
  final int reminderMinute;

  // FSRS tuning
  final double desiredRetention;
  final int maximumIntervalDays;
  final bool enableFuzzing;
  final List<int> learningStepsMinutes;
  final List<int> relearningStepsMinutes;

  /// Max cards handed out per review session.
  final int sessionLimit;

  final int serverPort;
  final ThemeMode themeMode;

  /// e.g. `http://192.168.1.10:1234/v1` — an LM Studio / Ollama / OpenAI URL.
  final String aiBaseUrl;
  final String aiModel;
  final double aiTemperature;
  final int aiTimeoutSeconds;

  TimeOfDay get reminderTime =>
      TimeOfDay(hour: reminderHour, minute: reminderMinute);

  bool get aiConfigured => aiBaseUrl.trim().isNotEmpty && aiModel.trim().isNotEmpty;

  AppSettings copyWith({
    bool? remindersEnabled,
    int? reminderHour,
    int? reminderMinute,
    double? desiredRetention,
    int? maximumIntervalDays,
    bool? enableFuzzing,
    List<int>? learningStepsMinutes,
    List<int>? relearningStepsMinutes,
    int? sessionLimit,
    int? serverPort,
    ThemeMode? themeMode,
    String? aiBaseUrl,
    String? aiModel,
    double? aiTemperature,
    int? aiTimeoutSeconds,
  }) =>
      AppSettings(
        remindersEnabled: remindersEnabled ?? this.remindersEnabled,
        reminderHour: reminderHour ?? this.reminderHour,
        reminderMinute: reminderMinute ?? this.reminderMinute,
        desiredRetention: desiredRetention ?? this.desiredRetention,
        maximumIntervalDays: maximumIntervalDays ?? this.maximumIntervalDays,
        enableFuzzing: enableFuzzing ?? this.enableFuzzing,
        learningStepsMinutes: learningStepsMinutes ?? this.learningStepsMinutes,
        relearningStepsMinutes:
            relearningStepsMinutes ?? this.relearningStepsMinutes,
        sessionLimit: sessionLimit ?? this.sessionLimit,
        serverPort: serverPort ?? this.serverPort,
        themeMode: themeMode ?? this.themeMode,
        aiBaseUrl: aiBaseUrl ?? this.aiBaseUrl,
        aiModel: aiModel ?? this.aiModel,
        aiTemperature: aiTemperature ?? this.aiTemperature,
        aiTimeoutSeconds: aiTimeoutSeconds ?? this.aiTimeoutSeconds,
      );
}

/// Persists [AppSettings] to SharedPreferences, and the AI API key to
/// EncryptedSharedPreferences via flutter_secure_storage.
class SettingsService {
  SettingsService(this._prefs);

  final SharedPreferences _prefs;

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _apiKeyKey = 'ai_api_key';

  static Future<SettingsService> create() async =>
      SettingsService(await SharedPreferences.getInstance());

  AppSettings load() {
    List<int> steps(String key, List<int> fallback) {
      final raw = _prefs.getStringList(key);
      if (raw == null || raw.isEmpty) return fallback;
      final parsed = raw.map(int.tryParse).whereType<int>().toList();
      return parsed.isEmpty ? fallback : parsed;
    }

    return AppSettings(
      remindersEnabled: _prefs.getBool('remindersEnabled') ?? false,
      reminderHour: _prefs.getInt('reminderHour') ?? 9,
      reminderMinute: _prefs.getInt('reminderMinute') ?? 0,
      desiredRetention: _prefs.getDouble('desiredRetention') ?? 0.9,
      maximumIntervalDays: _prefs.getInt('maximumIntervalDays') ?? 36500,
      enableFuzzing: _prefs.getBool('enableFuzzing') ?? true,
      learningStepsMinutes: steps('learningSteps', const [1, 10]),
      relearningStepsMinutes: steps('relearningSteps', const [10]),
      sessionLimit: _prefs.getInt('sessionLimit') ?? 100,
      serverPort: _prefs.getInt('serverPort') ?? 8080,
      themeMode: ThemeMode
          .values[(_prefs.getInt('themeMode') ?? ThemeMode.system.index)
              .clamp(0, ThemeMode.values.length - 1)],
      aiBaseUrl: _prefs.getString('aiBaseUrl') ?? '',
      aiModel: _prefs.getString('aiModel') ?? '',
      aiTemperature: _prefs.getDouble('aiTemperature') ?? 0.4,
      aiTimeoutSeconds: _prefs.getInt('aiTimeoutSeconds') ?? 180,
    );
  }

  Future<void> save(AppSettings s) async {
    await _prefs.setBool('remindersEnabled', s.remindersEnabled);
    await _prefs.setInt('reminderHour', s.reminderHour);
    await _prefs.setInt('reminderMinute', s.reminderMinute);
    await _prefs.setDouble('desiredRetention', s.desiredRetention);
    await _prefs.setInt('maximumIntervalDays', s.maximumIntervalDays);
    await _prefs.setBool('enableFuzzing', s.enableFuzzing);
    await _prefs.setStringList('learningSteps',
        s.learningStepsMinutes.map((e) => e.toString()).toList());
    await _prefs.setStringList('relearningSteps',
        s.relearningStepsMinutes.map((e) => e.toString()).toList());
    await _prefs.setInt('sessionLimit', s.sessionLimit);
    await _prefs.setInt('serverPort', s.serverPort);
    await _prefs.setInt('themeMode', s.themeMode.index);
    await _prefs.setString('aiBaseUrl', s.aiBaseUrl);
    await _prefs.setString('aiModel', s.aiModel);
    await _prefs.setDouble('aiTemperature', s.aiTemperature);
    await _prefs.setInt('aiTimeoutSeconds', s.aiTimeoutSeconds);
  }

  /// Secure storage can throw on devices with a broken keystore; a missing key
  /// is recoverable (the user retypes it), a crash on startup is not.
  Future<String> readApiKey() async {
    try {
      return await _secure.read(key: _apiKeyKey) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> writeApiKey(String value) async {
    try {
      if (value.isEmpty) {
        await _secure.delete(key: _apiKeyKey);
      } else {
        await _secure.write(key: _apiKeyKey, value: value);
      }
    } catch (_) {
      // Swallow: the user is told the key could not be saved by the caller.
    }
  }
}
