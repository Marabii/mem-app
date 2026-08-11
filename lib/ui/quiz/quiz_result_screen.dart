import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import 'quiz_run_screen.dart' show decodeOptions;

class QuizResultScreen extends ConsumerStatefulWidget {
  const QuizResultScreen({super.key, required this.sessionId});

  final int sessionId;

  @override
  ConsumerState<QuizResultScreen> createState() => _QuizResultScreenState();
}

class _QuizResultScreenState extends ConsumerState<QuizResultScreen> {
  QuizSession? _session;
  List<QuizQuestion> _questions = const [];
  bool _loading = true;
  bool _resetting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(databaseProvider);
    final sessions = await (db.select(db.quizSessions)
          ..where((s) => s.id.equals(widget.sessionId)))
        .get();
    final questions = await db.questionsForSession(widget.sessionId);
    if (!mounted) return;
    setState(() {
      _session = sessions.firstOrNull;
      _questions = questions;
      _loading = false;
    });
  }

  List<QuizQuestion> get _missed =>
      _questions.where((q) => q.isCorrect != true && q.sourceCardId != null).toList();

  Future<void> _resetMissedCards() async {
    final cardIds = _missed.map((q) => q.sourceCardId!).toSet();
    if (cardIds.isEmpty) return;

    final ok = await confirmDialog(
      context,
      title: 'Study these again?',
      message:
          '${cardIds.length} ${cardIds.length == 1 ? 'card goes' : 'cards go'} '
          'back into the learning queue so they come up again soon.',
      confirmLabel: 'Reset',
      destructive: false,
    );
    if (!ok) return;

    setState(() => _resetting = true);
    final scheduler = ref.read(schedulerServiceProvider);
    for (final id in cardIds) {
      await scheduler.resetToLearning(id);
    }
    if (!mounted) return;
    await refreshRemindersFrom(ref);
    if (!mounted) return;
    setState(() => _resetting = false);
    showSnack(context,
        '${cardIds.length} ${cardIds.length == 1 ? 'card' : 'cards'} queued for review');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final session = _session;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Results')),
        body: const EmptyState(
          icon: Icons.help_outline,
          title: 'Session not found',
          message: 'This quiz is no longer stored on the device.',
        ),
      );
    }

    final percent = (session.score * 100).round();
    final color = percent >= 80
        ? const Color(0xFF10B981)
        : percent >= 50
            ? const Color(0xFFF59E0B)
            : theme.colorScheme.error;
    final correct = _questions.where((q) => q.isCorrect == true).length;
    final focusAreas = session.feedback
        .split('\n')
        .map((f) => f.trim())
        .where((f) => f.isNotEmpty)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Results'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
            child: const Text('Done'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 26),
                child: Column(
                  children: [
                    Text(
                      '$percent%',
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$correct of ${_questions.length} correct',
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${session.topicName} · ${session.difficulty}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),

            if (focusAreas.isNotEmpty) ...[
              const SectionHeader('Pay attention to'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final area in focusAreas)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 6, right: 10),
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(area,
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(height: 1.45)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],

            if (_missed.isNotEmpty) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _resetting ? null : _resetMissedCards,
                icon: _resetting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(
                    'Study the ${_missed.length} ${_missed.length == 1 ? 'card' : 'cards'} you missed'),
              ),
            ],

            const SectionHeader('Every question'),
            for (var i = 0; i < _questions.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _QuestionReview(question: _questions[i], number: i + 1),
              ),
          ],
        ),
      ),
    );
  }
}

class _QuestionReview extends StatelessWidget {
  const _QuestionReview({required this.question, required this.number});

  final QuizQuestion question;
  final int number;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final correct = question.isCorrect;
    final options = decodeOptions(question.optionsJson);

    final (icon, tone) = switch (correct) {
      true => (Icons.check_circle, const Color(0xFF10B981)),
      false => (Icons.cancel, theme.colorScheme.error),
      null => (Icons.help_outline, theme.colorScheme.onSurfaceVariant),
    };

    final userAnswerText = question.kind == 'mcq'
        ? _optionLabel(options, question.userAnswer)
        : (question.userAnswer?.trim().isEmpty ?? true
            ? 'No answer'
            : question.userAnswer!);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(icon, color: tone),
        title: Text(
          question.prompt,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        subtitle: Text(
          question.awardedScore == null
              ? 'Not graded'
              : 'Question $number · ${(question.awardedScore! * 100).round()}%',
          style: theme.textTheme.bodySmall,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CardContent(
            data: question.prompt,
            baseStyle: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 16),
          _Labelled(label: 'Your answer', value: userAnswerText, tone: tone),
          if (question.kind == 'mcq' && question.correctIndex != null)
            _Labelled(
              label: 'Correct answer',
              value: _optionLabel(options, '${question.correctIndex}'),
            )
          else if (question.expectedAnswer != null &&
              question.expectedAnswer!.trim().isNotEmpty)
            _Labelled(
                label: 'Expected', value: question.expectedAnswer!.trim()),
          if (question.explanation != null &&
              question.explanation!.trim().isNotEmpty)
            _Labelled(label: 'Why', value: question.explanation!.trim()),
        ],
      ),
    );
  }

  static String _optionLabel(List<String> options, String? rawIndex) {
    final index = int.tryParse(rawIndex ?? '');
    if (index == null || index < 0 || index >= options.length) {
      return 'No answer';
    }
    return '${String.fromCharCode(65 + index)}. ${options[index]}';
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.value, this.tone});

  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: theme.textTheme.bodyMedium
                ?.copyWith(height: 1.45, color: tone),
          ),
        ],
      ),
    );
  }
}
