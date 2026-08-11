import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../state/providers.dart';
import '../review/review_screen.dart';
import '../topic/topic_detail_screen.dart';
import '../topic/topic_editor_sheet.dart';
import '../widgets/common.dart';

class TopicsScreen extends ConsumerWidget {
  const TopicsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(topicStatsProvider);

    return Scaffold(
      body: SafeArea(
        child: statsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline,
            title: 'Could not load your topics',
            message: '$e',
          ),
          data: (stats) => _TopicsBody(stats: stats),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showTopicEditor(context),
        icon: const Icon(Icons.add),
        label: const Text('New topic'),
      ),
    );
  }
}

class _TopicsBody extends ConsumerWidget {
  const _TopicsBody({required this.stats});

  final List<TopicStats> stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final totalDue = stats.fold<int>(0, (sum, s) => sum + s.due);
    final totalCards = stats.fold<int>(0, (sum, s) => sum + s.total);

    if (stats.isEmpty) {
      return EmptyState(
        icon: Icons.auto_stories_outlined,
        title: 'Nothing to study yet',
        message:
            'Create a topic — Rust, DSA, anything you want to keep in memory — '
            'then fill it with cards.',
        action: FilledButton.icon(
          onPressed: () => showTopicEditor(context),
          icon: const Icon(Icons.add),
          label: const Text('Create your first topic'),
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'MemApp',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
                ),
                const SizedBox(height: 4),
                Text(
                  totalDue > 0
                      ? '$totalDue ${totalDue == 1 ? 'card is' : 'cards are'} ready for review'
                      : '$totalCards ${totalCards == 1 ? 'card' : 'cards'} · nothing due right now',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
                if (totalDue > 0)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ReviewScreen(title: 'All topics'),
                        ),
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text('Study all · $totalDue due'),
                    ),
                  ),
                const SizedBox(height: 22),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
          sliver: SliverList.separated(
            itemCount: stats.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _TopicTile(stats: stats[i]),
          ),
        ),
      ],
    );
  }
}

class _TopicTile extends ConsumerWidget {
  const _TopicTile({required this.stats});

  final TopicStats stats;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accent = Color(stats.topic.colorValue);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailScreen(topicId: stats.topic.id),
          ),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 5, color: accent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              stats.topic.name,
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (stats.due > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${stats.due} due',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (stats.topic.description != null &&
                          stats.topic.description!.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          stats.topic.description!,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: stats.progress,
                          minHeight: 5,
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation(accent),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _MiniStat(
                              label: 'total', value: '${stats.total}'),
                          _MiniStat(
                              label: 'new',
                              value: '${stats.fresh}',
                              color: stats.fresh > 0 ? accent : null),
                          _MiniStat(
                              label: 'studied', value: '${stats.studied}'),
                          if (stats.suspended > 0)
                            _MiniStat(
                                label: 'paused', value: '${stats.suspended}'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodySmall,
          children: [
            TextSpan(
              text: value,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: color ?? theme.colorScheme.onSurface,
              ),
            ),
            TextSpan(
              text: ' $label',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
