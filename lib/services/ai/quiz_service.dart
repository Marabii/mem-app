import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../data/database.dart';
import '../../data/fsrs_mapping.dart';
import '../scheduler_service.dart';
import '../settings_service.dart';
import 'ai_client.dart';

enum QuizDifficulty {
  easy('Easy', 'recall and definitions'),
  medium('Medium', 'application and comparison'),
  hard('Hard', 'edge cases, trade-offs and multi-step reasoning');

  const QuizDifficulty(this.label, this.brief);
  final String label;
  final String brief;
}

/// One card plus why the app thinks the user is struggling with it. Computed
/// entirely on-device — the model is only told *which* cards to target, it does
/// not decide.
class StruggleEntry {
  const StruggleEntry({
    required this.card,
    required this.score,
    required this.lapseRate,
    required this.againHardRate,
    required this.retrievability,
  });

  final MemCard card;
  final double score;
  final double lapseRate;
  final double againHardRate;
  final double retrievability;

  String get reason {
    if (card.reps == 0) return 'not studied yet';
    final bits = <String>[];
    if (card.lapses > 0) {
      bits.add('${card.lapses} ${card.lapses == 1 ? 'lapse' : 'lapses'}');
    }
    if (againHardRate >= 0.5) bits.add('often rated Again/Hard');
    if ((card.difficulty ?? 0) >= 7) bits.add('high difficulty');
    if (retrievability > 0 && retrievability < 0.6) bits.add('likely forgotten');
    return bits.isEmpty ? 'still settling' : bits.join(', ');
  }
}

class QuizGenerationResult {
  const QuizGenerationResult({required this.sessionId, required this.questions});
  final int sessionId;
  final List<QuizQuestion> questions;
}

class QuizService {
  QuizService(this._db, this._scheduler);

  final AppDatabase _db;
  final SchedulerService _scheduler;

  /// How many cards are described to the model. Enough context to write varied
  /// questions without blowing a local model's context window.
  static const _maxCardsInPrompt = 18;

  // ------------------------------------------------------- struggle analysis

  Future<List<StruggleEntry>> analyzeStruggles({
    int? topicId,
    int limit = _maxCardsInPrompt,
  }) async {
    final cards = await _db.getCards(topicId: topicId);
    if (cards.isEmpty) return const [];

    final entries = <StruggleEntry>[];
    for (final card in cards) {
      if (card.suspended) continue;

      final recent = await _db.logsForCard(card.id, limit: 8);
      final againHard =
          recent.where((l) => l.rating == 1 || l.rating == 2).length;
      final againHardRate = recent.isEmpty ? 0.0 : againHard / recent.length;
      final lapseRate = card.reps == 0 ? 0.0 : card.lapses / card.reps;

      // getCardRetrievability dereferences stability when lastReview is set, so
      // only ask when both are present.
      final retrievability =
          (card.lastReviewUtc != null && card.stability != null)
              ? _scheduler.retrievability(card)
              : 0.0;

      final difficultyNorm =
          (((card.difficulty ?? 5.0) - 1.0) / 9.0).clamp(0.0, 1.0);
      final forgetting = card.reps == 0 ? 0.0 : (1.0 - retrievability).clamp(0.0, 1.0);

      // Unseen cards get a small floor so a brand-new deck still yields a quiz
      // rather than an empty one.
      final score = card.reps == 0
          ? 0.2
          : 0.35 * lapseRate.clamp(0.0, 1.0) +
              0.25 * againHardRate +
              0.25 * difficultyNorm +
              0.15 * forgetting;

      entries.add(StruggleEntry(
        card: card,
        score: score,
        lapseRate: lapseRate,
        againHardRate: againHardRate,
        retrievability: retrievability,
      ));
    }

    entries.sort((a, b) => b.score.compareTo(a.score));
    return entries.take(limit).toList();
  }

  // ------------------------------------------------------------- generation

  Future<QuizGenerationResult> generateQuiz({
    required AiClient client,
    required AppSettings settings,
    int? topicId,
    String topicName = 'All topics',
    QuizDifficulty difficulty = QuizDifficulty.medium,
    int questionCount = 8,
  }) async {
    final struggles = await analyzeStruggles(topicId: topicId);
    if (struggles.isEmpty) {
      throw const AiException(
          'There are no cards to build a quiz from. Add some cards first.');
    }

    final raw = await client.complete([
      const AiMessage.system(
        'You are an exacting tutor who writes diagnostic quizzes. '
        'You reply with a single JSON object and nothing else — no prose, no '
        'markdown fences. Questions must be answerable from the study material '
        'you are given, and must probe understanding rather than quote it back.',
      ),
      AiMessage.user(_generationPrompt(
        struggles: struggles,
        topicName: topicName,
        difficulty: difficulty,
        questionCount: questionCount,
      )),
    ]);

    final parsed = extractJsonObject(raw);
    final questionsRaw = parsed?['questions'];
    if (questionsRaw is! List || questionsRaw.isEmpty) {
      throw AiException(
        'The model did not return any usable questions.',
        detail: truncateForDisplay(raw),
      );
    }

    final validIds = {for (final s in struggles) s.card.id};
    final sessionId = await _db.insertQuizSession(QuizSessionsCompanion.insert(
      difficulty: difficulty.label,
      createdAtUtc: DateTime.now().toUtc(),
      topicId: Value(topicId),
      topicName: Value(topicName),
    ));

    var position = 0;
    for (final q in questionsRaw) {
      if (q is! Map) continue;
      final prompt = (q['prompt'] ?? q['question'])?.toString().trim() ?? '';
      if (prompt.isEmpty) continue;

      final optionsRaw = q['options'];
      final options = optionsRaw is List
          ? optionsRaw.map((o) => o.toString()).toList()
          : const <String>[];
      final isMcq = (q['kind']?.toString().toLowerCase() == 'mcq') ||
          options.length >= 2;

      var correctIndex = _asInt(q['correctIndex']);
      if (isMcq && (correctIndex == null || correctIndex < 0 || correctIndex >= options.length)) {
        // Some models answer with the option text instead of its index.
        final answer = q['answer']?.toString().trim();
        final byText = answer == null
            ? -1
            : options.indexWhere(
                (o) => o.trim().toLowerCase() == answer.toLowerCase());
        correctIndex = byText >= 0 ? byText : 0;
      }

      final sourceId = _asInt(q['sourceCardId']);

      await _db.insertQuizQuestion(QuizQuestionsCompanion.insert(
        sessionId: sessionId,
        position: position++,
        kind: isMcq ? 'mcq' : 'short',
        prompt: prompt,
        optionsJson: Value(isMcq ? jsonEncode(options) : null),
        correctIndex: Value(isMcq ? correctIndex : null),
        expectedAnswer: Value(
            (q['expectedAnswer'] ?? q['answer'])?.toString().trim()),
        explanation: Value(q['explanation']?.toString().trim()),
        sourceCardId:
            Value(validIds.contains(sourceId) ? sourceId : null),
      ));
    }

    final questions = await _db.questionsForSession(sessionId);
    if (questions.isEmpty) {
      await _db.deleteQuizSession(sessionId);
      throw AiException(
        'The model\'s questions could not be parsed.',
        detail: truncateForDisplay(raw),
      );
    }

    await _db.updateQuizSession(
      (await _sessionById(sessionId))!.copyWith(totalQuestions: questions.length),
    );

    return QuizGenerationResult(sessionId: sessionId, questions: questions);
  }

  String _generationPrompt({
    required List<StruggleEntry> struggles,
    required String topicName,
    required QuizDifficulty difficulty,
    required int questionCount,
  }) {
    final material = [
      for (final s in struggles)
        {
          'cardId': s.card.id,
          'question': s.card.front,
          'answer': s.card.back,
          if (s.card.tags.isNotEmpty) 'tags': s.card.tagList,
          'struggleScore': double.parse(s.score.toStringAsFixed(2)),
          'lapses': s.card.lapses,
          'timesReviewed': s.card.reps,
        },
    ];

    final mcqCount = math.max(1, (questionCount * 0.6).round());
    final shortCount = math.max(1, questionCount - mcqCount);

    return '''
Topic: $topicName
Difficulty: ${difficulty.label} — focus on ${difficulty.brief}.

Write exactly $questionCount questions: $mcqCount multiple-choice and $shortCount short-answer.
Weight them towards the cards with the highest struggleScore.

Rules:
- Every question must be answerable from the study material below.
- Do not copy a card's question verbatim; rephrase, combine, or apply it.
- Multiple choice: exactly 4 options, exactly one correct, distractors must be
  plausible to someone with a partial understanding.
- Short answer: answerable in one or two sentences.
- "explanation" states why the answer is right, in one or two sentences.
- "sourceCardId" must be one of the cardId values given below.

Reply with this JSON object and nothing else:
{
  "questions": [
    {"kind":"mcq","prompt":"...","options":["...","...","...","..."],"correctIndex":0,"explanation":"...","sourceCardId":12},
    {"kind":"short","prompt":"...","expectedAnswer":"...","explanation":"...","sourceCardId":15}
  ]
}

Study material:
${const JsonEncoder.withIndent('  ').convert(material)}
''';
  }

  // ---------------------------------------------------------------- grading

  /// Grades a finished attempt.
  ///
  /// Multiple choice is scored locally and never needs the network. Short
  /// answers go to the model in a single batched call; if that call fails the
  /// MCQ score still stands and the short answers are reported as ungraded
  /// rather than throwing the session away.
  Future<QuizSession> gradeSession({
    required int sessionId,
    required Map<int, String> answers,
    AiClient? client,
  }) async {
    final session = await _sessionById(sessionId);
    if (session == null) {
      throw const AiException('That quiz session no longer exists.');
    }
    final questions = await _db.questionsForSession(sessionId);

    var earned = 0.0;
    var graded = 0;
    final shortAnswers = <QuizQuestion>[];

    for (final q in questions) {
      final answer = answers[q.id]?.trim() ?? '';
      if (q.kind == 'mcq') {
        final picked = int.tryParse(answer);
        final correct = picked != null && picked == q.correctIndex;
        await _db.updateQuizQuestion(q.copyWith(
          userAnswer: Value(answer),
          isCorrect: Value(correct),
          awardedScore: Value(correct ? 1.0 : 0.0),
        ));
        if (correct) earned += 1;
        graded++;
      } else {
        await _db.updateQuizQuestion(q.copyWith(userAnswer: Value(answer)));
        shortAnswers.add(q);
      }
    }

    var feedback = '';
    if (shortAnswers.isNotEmpty && client != null) {
      try {
        final result = await _gradeShortAnswers(
          client: client,
          questions: shortAnswers,
          answers: answers,
        );
        earned += result.earned;
        graded += shortAnswers.length;
        feedback = result.feedback;
      } on AiException catch (e) {
        feedback = 'Short answers could not be graded: ${e.message}';
      }
    } else if (shortAnswers.isNotEmpty) {
      feedback = 'Short answers were not graded — no AI model is configured.';
    }

    final score = graded == 0 ? 0.0 : earned / graded;
    final updated = session.copyWith(
      score: score,
      totalQuestions: questions.length,
      feedback: feedback,
      completed: true,
    );
    await _db.updateQuizSession(updated);
    return updated;
  }

  Future<({double earned, String feedback})> _gradeShortAnswers({
    required AiClient client,
    required List<QuizQuestion> questions,
    required Map<int, String> answers,
  }) async {
    final payload = [
      for (var i = 0; i < questions.length; i++)
        {
          'index': i,
          'question': questions[i].prompt,
          'expectedAnswer': questions[i].expectedAnswer ?? '',
          'studentAnswer': answers[questions[i].id]?.trim() ?? '',
        },
    ];

    final raw = await client.complete([
      const AiMessage.system(
        'You grade short free-recall answers. Be fair but not lenient: award '
        'credit for correct understanding even when the wording differs, and '
        'withhold it when a key idea is missing or wrong. Reply with a single '
        'JSON object and nothing else.',
      ),
      AiMessage.user('''
Grade each answer. score is 0.0 to 1.0 (partial credit allowed).
feedback is one sentence addressed to the student, naming what was missing.
focusAreas lists 2-4 concrete concepts to revisit, based on the mistakes.

Reply with this JSON object and nothing else:
{
  "gradings": [{"index":0,"score":1.0,"feedback":"..."}],
  "focusAreas": ["...", "..."]
}

Answers to grade:
${const JsonEncoder.withIndent('  ').convert(payload)}
'''),
    ]);

    final parsed = extractJsonObject(raw);
    final gradings = parsed?['gradings'];
    if (gradings is! List) {
      throw AiException(
        'The grading response could not be parsed.',
        detail: truncateForDisplay(raw),
      );
    }

    var earned = 0.0;
    for (final g in gradings) {
      if (g is! Map) continue;
      final index = _asInt(g['index']);
      if (index == null || index < 0 || index >= questions.length) continue;
      final score = (_asDouble(g['score']) ?? 0.0).clamp(0.0, 1.0);
      earned += score;
      await _db.updateQuizQuestion(questions[index].copyWith(
        awardedScore: Value(score),
        isCorrect: Value(score >= 0.6),
        explanation: Value(g['feedback']?.toString().trim() ??
            questions[index].explanation),
      ));
    }

    final focus = parsed?['focusAreas'];
    final feedback = focus is List && focus.isNotEmpty
        ? focus.map((f) => f.toString().trim()).where((f) => f.isNotEmpty).join('\n')
        : '';

    return (earned: earned, feedback: feedback);
  }

  Future<QuizSession?> _sessionById(int id) => (_db.select(_db.quizSessions)
        ..where((s) => s.id.equals(id)))
      .getSingleOrNull();

  static int? _asInt(Object? v) => switch (v) {
        final int i => i,
        final double d => d.round(),
        final String s => int.tryParse(s),
        _ => null,
      };

  static double? _asDouble(Object? v) => switch (v) {
        final double d => d,
        final int i => i.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };
}
