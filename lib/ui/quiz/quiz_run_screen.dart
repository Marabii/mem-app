import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../services/ai/ai_client.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import 'quiz_result_screen.dart';

/// One question per screen. Multiple choice is graded offline; short answers
/// are sent for grading once, at the end.
class QuizRunScreen extends ConsumerStatefulWidget {
  const QuizRunScreen({
    super.key,
    required this.sessionId,
    required this.questions,
    required this.topicName,
  });

  final int sessionId;
  final List<QuizQuestion> questions;
  final String topicName;

  @override
  ConsumerState<QuizRunScreen> createState() => _QuizRunScreenState();
}

class _QuizRunScreenState extends ConsumerState<QuizRunScreen> {
  int _index = 0;
  final _answers = <int, String>{};
  final _shortController = TextEditingController();
  bool _submitting = false;

  QuizQuestion get _current => widget.questions[_index];
  bool get _isLast => _index == widget.questions.length - 1;

  @override
  void dispose() {
    _shortController.dispose();
    super.dispose();
  }

  void _syncShortAnswer() {
    if (_current.kind == 'short') {
      _answers[_current.id] = _shortController.text.trim();
    }
  }

  void _next() {
    _syncShortAnswer();
    setState(() {
      _index++;
      _shortController.text = _answers[_current.id] ?? '';
    });
  }

  void _previous() {
    _syncShortAnswer();
    setState(() {
      _index--;
      _shortController.text = _answers[_current.id] ?? '';
    });
  }

  Future<void> _submit() async {
    _syncShortAnswer();

    final unanswered =
        widget.questions.where((q) => (_answers[q.id] ?? '').isEmpty).length;
    if (unanswered > 0) {
      final go = await confirmDialog(
        context,
        title: 'Submit anyway?',
        message:
            '$unanswered ${unanswered == 1 ? 'question is' : 'questions are'} '
            'unanswered. They will be marked wrong.',
        confirmLabel: 'Submit',
        destructive: false,
      );
      if (!go) return;
    }

    setState(() => _submitting = true);
    try {
      await ref.read(quizServiceProvider).gradeSession(
            sessionId: widget.sessionId,
            answers: _answers,
            client: ref.read(aiClientProvider),
          );
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => QuizResultScreen(sessionId: widget.sessionId),
        ),
      );
    } on AiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showSnack(context, e.message, isError: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showSnack(context, 'Could not grade the quiz: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final question = _current;
    final answered = (_answers[question.id] ?? '').isNotEmpty;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await confirmDialog(
          context,
          title: 'Leave the quiz?',
          message: 'Your answers so far will be discarded.',
          confirmLabel: 'Leave',
        );
        if (leave && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.topicName),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(
              value: (_index + 1) / widget.questions.length,
              minHeight: 4,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                  children: [
                    Row(
                      children: [
                        Text(
                          'Question ${_index + 1} of ${widget.questions.length}',
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            question.kind == 'mcq'
                                ? 'Multiple choice'
                                : 'Short answer',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    CardContent(
                      data: question.prompt,
                      baseStyle: theme.textTheme.titleLarge
                          ?.copyWith(height: 1.4, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 26),
                    if (question.kind == 'mcq')
                      _McqOptions(
                        question: question,
                        selected: int.tryParse(_answers[question.id] ?? ''),
                        onSelect: (i) => setState(
                            () => _answers[question.id] = i.toString()),
                      )
                    else
                      TextField(
                        controller: _shortController,
                        maxLines: null,
                        minLines: 4,
                        autofocus: true,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          hintText: 'Answer in a sentence or two…',
                        ),
                        onChanged: (v) =>
                            setState(() => _answers[question.id] = v.trim()),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                child: Row(
                  children: [
                    if (_index > 0) ...[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _submitting ? null : _previous,
                          child: const Text('Back'),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: _submitting
                            ? null
                            : _isLast
                                ? _submit
                                : _next,
                        child: _submitting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2.4),
                              )
                            : Text(_isLast
                                ? 'Finish and grade'
                                : answered
                                    ? 'Next'
                                    : 'Skip'),
                      ),
                    ),
                  ],
                ),
              ),
              if (_submitting)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text(
                    'Grading your short answers…',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _McqOptions extends StatelessWidget {
  const _McqOptions({
    required this.question,
    required this.selected,
    required this.onSelect,
  });

  final QuizQuestion question;
  final int? selected;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final options = decodeOptions(question.optionsJson);

    return Column(
      children: [
        for (var i = 0; i < options.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: () => onSelect(i),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: selected == i
                      ? theme.colorScheme.primary.withValues(alpha: 0.10)
                      : theme.colorScheme.surface,
                  border: Border.all(
                    color: selected == i
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                    width: selected == i ? 1.8 : 1,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected == i
                            ? theme.colorScheme.primary
                            : Colors.transparent,
                        border: Border.all(
                            color: selected == i
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        String.fromCharCode(65 + i),
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: selected == i
                              ? theme.colorScheme.onPrimary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(options[i],
                          style: theme.textTheme.bodyLarge?.copyWith(height: 1.4)),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

List<String> decodeOptions(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    return decoded is List ? decoded.map((e) => e.toString()).toList() : const [];
  } catch (_) {
    return const [];
  }
}
