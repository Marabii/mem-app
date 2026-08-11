import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fsrs/fsrs.dart' as fsrs;

import '../../data/database.dart';
import '../../data/fsrs_mapping.dart';
import '../../services/scheduler_service.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

/// One pass through the due queue for a topic (or everything, when [topicId]
/// is null).
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key, this.topicId, required this.title});

  final int? topicId;
  final String title;

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  List<MemCard> _queue = [];
  int _index = 0;
  bool _revealed = false;
  bool _loading = true;
  bool _busy = false;

  DateTime _shownAt = DateTime.now();
  final _counts = <fsrs.Rating, int>{};
  Duration _timeSpent = Duration.zero;

  /// Snapshot of the last graded card so a mis-tap can be walked back.
  ({MemCard card, int logId})? _lastReview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsProvider);
    final cards = await ref.read(databaseProvider).dueCards(
          topicId: widget.topicId,
          limit: settings.sessionLimit,
        );
    if (!mounted) return;
    setState(() {
      _queue = cards;
      _loading = false;
      _shownAt = DateTime.now();
    });
  }

  MemCard? get _current => _index < _queue.length ? _queue[_index] : null;

  Future<void> _rate(fsrs.Rating rating) async {
    final card = _current;
    if (card == null || _busy) return;
    setState(() => _busy = true);

    final elapsed = DateTime.now().difference(_shownAt);
    try {
      final outcome = await ref
          .read(schedulerServiceProvider)
          .rate(card, rating, timeSpent: elapsed);

      if (!mounted) return;
      setState(() {
        _counts[rating] = (_counts[rating] ?? 0) + 1;
        _timeSpent += elapsed;
        _lastReview = (card: card, logId: outcome.logId);
        _index++;
        _revealed = false;
        _busy = false;
        _shownAt = DateTime.now();
      });

      if (_index >= _queue.length) await _finish();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, 'Could not save that review: $e', isError: true);
    }
  }

  Future<void> _undo() async {
    final last = _lastReview;
    if (last == null || _busy) return;
    setState(() => _busy = true);
    await ref.read(schedulerServiceProvider).undo(last.card, last.logId);
    if (!mounted) return;
    setState(() {
      _index = (_index - 1).clamp(0, _queue.length);
      _queue[_index] = last.card;
      _lastReview = null;
      _revealed = true;
      _busy = false;
      _shownAt = DateTime.now();
    });
  }

  Future<void> _finish() async {
    // Due counts changed, so the pre-computed reminder window is now stale.
    await refreshRemindersFrom(ref);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final card = _current;
    if (card == null) {
      return _SessionSummary(
        title: widget.title,
        counts: _counts,
        timeSpent: _timeSpent,
        reviewed: _index,
        onUndo: _lastReview == null ? null : _undo,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_lastReview != null)
            IconButton(
              tooltip: 'Undo last review',
              onPressed: _busy ? null : _undo,
              icon: const Icon(Icons.undo),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: _queue.isEmpty ? 0 : _index / _queue.length,
            minHeight: 4,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_index + 1} of ${_queue.length}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  _StateBadge(card: card),
                ],
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _revealed
                    ? null
                    : () => setState(() => _revealed = true),
                child: _CardFace(card: card, revealed: _revealed),
              ),
            ),
            _AnswerBar(
              card: card,
              revealed: _revealed,
              busy: _busy,
              onReveal: () => setState(() => _revealed = true),
              onRate: _rate,
            ),
          ],
        ),
      ),
    );
  }
}

class _CardFace extends StatelessWidget {
  const _CardFace({required this.card, required this.revealed});

  final MemCard card;
  final bool revealed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardContent(
            data: card.front,
            baseStyle: theme.textTheme.headlineSmall
                ?.copyWith(height: 1.35, fontWeight: FontWeight.w600),
          ),
          if (card.tagList.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in card.tagList)
                  Chip(
                    label: Text(tag),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ],
          if (revealed) ...[
            const SizedBox(height: 28),
            Divider(color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 24),
            CardContent(
              data: card.back,
              baseStyle: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
            ),
          ] else ...[
            const SizedBox(height: 40),
            Center(
              child: Text(
                'Tap to reveal the answer',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.card});

  final MemCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = card.isNew ? 'New' : card.state.label;
    final color = card.isNew
        ? theme.colorScheme.tertiary
        : switch (card.state) {
            fsrs.State.learning => theme.colorScheme.primary,
            fsrs.State.review => theme.colorScheme.secondary,
            fsrs.State.relearning => theme.colorScheme.error,
          };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Reveal button before the answer, four graded buttons after — each labelled
/// with the interval it would actually produce.
class _AnswerBar extends ConsumerWidget {
  const _AnswerBar({
    required this.card,
    required this.revealed,
    required this.busy,
    required this.onReveal,
    required this.onRate,
  });

  final MemCard card;
  final bool revealed;
  final bool busy;
  final VoidCallback onReveal;
  final void Function(fsrs.Rating) onRate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    if (!revealed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: onReveal,
            child: const Text('Show answer'),
          ),
        ),
      );
    }

    final SchedulerService scheduler = ref.read(schedulerServiceProvider);
    final previews = scheduler.previewIntervals(card);

    const colors = {
      fsrs.Rating.again: Color(0xFFEF4444),
      fsrs.Rating.hard: Color(0xFFF59E0B),
      fsrs.Rating.good: Color(0xFF10B981),
      fsrs.Rating.easy: Color(0xFF0EA5E9),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      child: Row(
        children: [
          for (final rating in fsrs.Rating.values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FilledButton(
                  onPressed: busy
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          onRate(rating);
                        },
                  style: FilledButton.styleFrom(
                    backgroundColor: colors[rating],
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        rating.label,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        formatInterval(previews[rating] ?? Duration.zero),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SessionSummary extends StatelessWidget {
  const _SessionSummary({
    required this.title,
    required this.counts,
    required this.timeSpent,
    required this.reviewed,
    this.onUndo,
  });

  final String title;
  final Map<fsrs.Rating, int> counts;
  final Duration timeSpent;
  final int reviewed;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (reviewed == 0) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: EmptyState(
          icon: Icons.check_circle_outline,
          title: 'Nothing due',
          message:
              'Every card here is scheduled for later. Come back when one comes up, '
              'or add more cards.',
          action: FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back'),
          ),
        ),
      );
    }

    final perCard = timeSpent.inMilliseconds / reviewed / 1000;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(Icons.celebration_outlined,
                  size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 18),
              Text(
                'Session complete',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                '$reviewed ${reviewed == 1 ? 'card' : 'cards'} · '
                '${perCard.toStringAsFixed(1)}s each',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 32),
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 18, horizontal: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final rating in fsrs.Rating.values)
                        StatChip(
                          label: rating.label,
                          value: '${counts[rating] ?? 0}',
                          color: switch (rating) {
                            fsrs.Rating.again => const Color(0xFFEF4444),
                            fsrs.Rating.hard => const Color(0xFFF59E0B),
                            fsrs.Rating.good => const Color(0xFF10B981),
                            fsrs.Rating.easy => const Color(0xFF0EA5E9),
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              if (onUndo != null)
                OutlinedButton.icon(
                  onPressed: onUndo,
                  icon: const Icon(Icons.undo),
                  label: const Text('Undo last review'),
                ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
