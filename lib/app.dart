import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/providers.dart';
import 'theme/app_theme.dart';
import 'ui/home/home_screen.dart';

class MemApp extends ConsumerStatefulWidget {
  const MemApp({super.key});

  @override
  ConsumerState<MemApp> createState() => _MemAppState();
}

class _MemAppState extends ConsumerState<MemApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncReminders());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The reminder window holds pre-computed due counts, so it has to be
    // rebuilt whenever the app comes back to the foreground.
    if (state == AppLifecycleState.resumed) _syncReminders();
  }

  Future<void> _syncReminders() async {
    final notifications = ref.read(notificationServiceProvider);
    await notifications.init();
    await notifications.rescheduleReminders(ref.read(settingsProvider));
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));

    return MaterialApp(
      title: 'MemApp',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: const HomeScreen(),
    );
  }
}
