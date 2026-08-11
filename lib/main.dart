import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/database.dart';
import 'services/settings_service.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Both are cheap to build and needed synchronously by the first frame, so
  // they are constructed here and injected rather than resolved lazily.
  final database = AppDatabase();
  final settingsService = await SettingsService.create();

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        settingsServiceProvider.overrideWithValue(settingsService),
      ],
      child: const MemApp(),
    ),
  );
}
