import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../widgets/common.dart';

/// Exposes the FSRS knobs that are safe for a user to turn. The 21 model
/// weights are deliberately not editable — the defaults are the published
/// optimised parameters.
class SchedulingScreen extends ConsumerWidget {
  const SchedulingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('FSRS tuning')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            const SectionHeader('Target retention', padding: EdgeInsets.fromLTRB(4, 8, 4, 10)),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${(settings.desiredRetention * 100).round()}%',
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      'How much you want to remember at review time. Higher '
                      'means shorter intervals and more reviews per day.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    Slider(
                      value: settings.desiredRetention,
                      min: 0.70,
                      max: 0.98,
                      divisions: 28,
                      label: '${(settings.desiredRetention * 100).round()}%',
                      onChanged: (v) => controller
                          .edit((s) => s.copyWith(desiredRetention: v)),
                    ),
                  ],
                ),
              ),
            ),

            const SectionHeader('Session'),
            SettingsGroup(children: [
              ListTile(
                leading: const Icon(Icons.layers_outlined),
                title: const Text('Cards per session'),
                subtitle: const Text('Upper bound on one study run'),
                trailing: Text('${settings.sessionLimit}',
                    style: theme.textTheme.titleMedium),
                onTap: () => _editNumber(
                  context,
                  title: 'Cards per session',
                  initial: settings.sessionLimit,
                  min: 5,
                  max: 999,
                  onSaved: (v) =>
                      controller.edit((s) => s.copyWith(sessionLimit: v)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.event_available_outlined),
                title: const Text('Maximum interval'),
                subtitle: const Text('Longest gap FSRS may schedule'),
                trailing: Text('${settings.maximumIntervalDays} d',
                    style: theme.textTheme.titleMedium),
                onTap: () => _editNumber(
                  context,
                  title: 'Maximum interval (days)',
                  initial: settings.maximumIntervalDays,
                  min: 1,
                  max: 36500,
                  onSaved: (v) => controller
                      .edit((s) => s.copyWith(maximumIntervalDays: v)),
                ),
              ),
            ]),

            const SectionHeader('Steps'),
            SettingsGroup(children: [
              ListTile(
                leading: const Icon(Icons.school_outlined),
                title: const Text('Learning steps'),
                subtitle: Text(_stepsLabel(settings.learningStepsMinutes)),
                onTap: () => _editSteps(
                  context,
                  title: 'Learning steps',
                  initial: settings.learningStepsMinutes,
                  onSaved: (v) =>
                      controller.edit((s) => s.copyWith(learningStepsMinutes: v)),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.replay),
                title: const Text('Relearning steps'),
                subtitle: Text(_stepsLabel(settings.relearningStepsMinutes)),
                onTap: () => _editSteps(
                  context,
                  title: 'Relearning steps',
                  initial: settings.relearningStepsMinutes,
                  onSaved: (v) => controller
                      .edit((s) => s.copyWith(relearningStepsMinutes: v)),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.shuffle),
                value: settings.enableFuzzing,
                title: const Text('Fuzz intervals'),
                subtitle: const Text(
                    'Spreads due dates slightly so cards added together do not '
                    'all come back on the same day'),
                onChanged: (v) =>
                    controller.edit((s) => s.copyWith(enableFuzzing: v)),
              ),
            ]),

            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Changes apply to the next card you rate. Cards already '
                'scheduled keep their current due dates.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _stepsLabel(List<int> minutes) => minutes
      .map((m) => m < 60 ? '${m}m' : '${(m / 60).toStringAsFixed(m % 60 == 0 ? 0 : 1)}h')
      .join(' → ');

  Future<void> _editNumber(
    BuildContext context, {
    required String title,
    required int initial,
    required int min,
    required int max,
    required void Function(int) onSaved,
  }) async {
    final controller = TextEditingController(text: '$initial');
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(helperText: 'Between $min and $max'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null) return;
    if (value < min || value > max) {
      if (context.mounted) {
        showSnack(context, 'Enter a value between $min and $max',
            isError: true);
      }
      return;
    }
    onSaved(value);
  }

  Future<void> _editSteps(
    BuildContext context, {
    required String title,
    required List<int> initial,
    required void Function(List<int>) onSaved,
  }) async {
    final controller = TextEditingController(text: initial.join(', '));
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            helperText: 'Minutes, comma separated. e.g. 1, 10',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null) return;

    final parsed = value
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((m) => m > 0)
        .toList();

    if (parsed.isEmpty) {
      if (context.mounted) {
        showSnack(context, 'Enter at least one positive number of minutes',
            isError: true);
      }
      return;
    }
    onSaved(parsed);
  }
}
