import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../services/ai/ai_client.dart';
import '../../services/ai/quiz_service.dart';
import '../../state/providers.dart';
import '../settings/ai_settings_screen.dart';
import '../widgets/common.dart';
import 'quiz_result_screen.dart';
import 'quiz_run_screen.dart';

class QuizHomeScreen extends ConsumerStatefulWidget {
  const QuizHomeScreen({super.key});

  @override
  ConsumerState<QuizHomeScreen> createState() => _QuizHomeScreenState();
}

class _QuizHomeScreenState extends ConsumerState<QuizHomeScreen> {
  int? _topicId;
  QuizDifficulty _difficulty = QuizDifficulty.medium;
  int _questionCount = 8;
  bool _generating = false;

  Future<void> _generate() async {
    final client = ref.read(aiClientProvider);
    if (client == null) {
      showSnack(context, 'Set up a model first', isError: true);
      return;
    }

    final topics = ref.read(topicsProvider).valueOrNull ?? const <Topic>[];
    final topicName = _topicId == null
        ? 'All topics'
        : topics.firstWhere((t) => t.id == _topicId).name;

    setState(() => _generating = true);
    try {
      final result = await ref.read(quizServiceProvider).generateQuiz(
            client: client,
            settings: ref.read(settingsProvider),
            topicId: _topicId,
            topicName: topicName,
            difficulty: _difficulty,
            questionCount: _questionCount,
          );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => QuizRunScreen(
            sessionId: result.sessionId,
            questions: result.questions,
            topicName: topicName,
          ),
        ),
      );
    } on AiException catch (e) {
      if (!mounted) return;
      _showAiError(e);
    } catch (e) {
      if (!mounted) return;
      showSnack(context, 'Could not build a quiz: $e', isError: true);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _showAiError(AiException e) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('The model could not be reached'),
        content: SingleChildScrollView(
          child: SelectableText(e.toString()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
              );
            },
            child: const Text('AI settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    final topics = ref.watch(topicsProvider).valueOrNull ?? const <Topic>[];
    final history = ref.watch(quizHistoryProvider).valueOrNull ?? const [];

    if (!settings.aiConfigured) {
      return Scaffold(
        appBar: AppBar(title: const Text('Quiz')),
        body: EmptyState(
          icon: Icons.smart_toy_outlined,
          title: 'No model configured',
          message:
              'Point MemApp at an OpenAI-compatible server — LM Studio on your '
              'laptop works well — and it will build quizzes from the cards you '
              'keep getting wrong.',
          action: FilledButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
            ),
            icon: const Icon(Icons.settings),
            label: const Text('Set up the model'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Quiz')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('New quiz',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      'MemApp picks the cards you struggle with most — lapses, '
                      'Again ratings, high difficulty — and asks the model to '
                      'probe those.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.45),
                    ),
                    const SizedBox(height: 18),
                    DropdownButtonFormField<int?>(
                      initialValue: _topicId,
                      decoration: const InputDecoration(labelText: 'Topic'),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('All topics')),
                        for (final topic in topics)
                          DropdownMenuItem(
                              value: topic.id, child: Text(topic.name)),
                      ],
                      onChanged: (v) => setState(() => _topicId = v),
                    ),
                    const SizedBox(height: 18),
                    Text('Difficulty', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    SegmentedButton<QuizDifficulty>(
                      segments: [
                        for (final d in QuizDifficulty.values)
                          ButtonSegment(value: d, label: Text(d.label)),
                      ],
                      selected: {_difficulty},
                      onSelectionChanged: (v) =>
                          setState(() => _difficulty = v.first),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Focus: ${_difficulty.brief}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Text('Questions', style: theme.textTheme.labelLarge),
                        const Spacer(),
                        Text('$_questionCount',
                            style: theme.textTheme.titleMedium),
                      ],
                    ),
                    Slider(
                      value: _questionCount.toDouble(),
                      min: 3,
                      max: 20,
                      divisions: 17,
                      label: '$_questionCount',
                      onChanged: (v) =>
                          setState(() => _questionCount = v.round()),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _generating ? null : _generate,
                        icon: _generating
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.2),
                              )
                            : const Icon(Icons.auto_awesome),
                        label: Text(_generating
                            ? 'Writing your quiz…'
                            : 'Generate quiz'),
                      ),
                    ),
                    if (_generating) ...[
                      const SizedBox(height: 10),
                      Text(
                        'A local model can take a minute or two.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SectionHeader('Weak spots'),
            const _StrugglePreview(),

            if (history.isNotEmpty) ...[
              const SectionHeader('Past quizzes'),
              SettingsGroup(children: [
                for (final session in history.take(10))
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _scoreColor(session.score, theme)
                          .withValues(alpha: 0.15),
                      child: Text(
                        '${(session.score * 100).round()}',
                        style: TextStyle(
                          color: _scoreColor(session.score, theme),
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    title: Text(session.topicName),
                    subtitle: Text(
                        '${session.difficulty} · ${session.totalQuestions} questions · '
                        '${_ago(session.createdAtUtc)}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            QuizResultScreen(sessionId: session.id),
                      ),
                    ),
                  ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  static Color _scoreColor(double score, ThemeData theme) => score >= 0.8
      ? const Color(0xFF10B981)
      : score >= 0.5
          ? const Color(0xFFF59E0B)
          : theme.colorScheme.error;

  static String _ago(DateTime utc) {
    final diff = DateTime.now().difference(utc.toLocal());
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${(diff.inDays / 30).round()}mo ago';
  }
}

/// Shows what the local analysis would feed the model, so the feature is not a
/// black box.
class _StrugglePreview extends ConsumerWidget {
  const _StrugglePreview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return FutureBuilder<List<StruggleEntry>>(
      // Re-runs whenever cards change, since cardsProvider is watched below.
      future: ref
          .watch(quizServiceProvider)
          .analyzeStruggles(limit: 5),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        final entries = snapshot.data!;
        if (entries.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                'Nothing to analyse yet — add some cards and study them a few '
                'times.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          );
        }

        return SettingsGroup(children: [
          for (final entry in entries)
            ListTile(
              dense: true,
              title: Text(
                cardPreviewText(entry.card.front),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(entry.reason),
              trailing: SizedBox(
                width: 46,
                child: LinearProgressIndicator(
                  value: entry.score.clamp(0.0, 1.0),
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(999),
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
        ]);
      },
    );
  }
}
