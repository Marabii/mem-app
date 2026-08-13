import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/fsrs_mapping.dart';
import '../../state/providers.dart';
import '../card/card_editor_screen.dart';
import '../review/review_screen.dart';
import '../widgets/common.dart';
import 'topic_editor_sheet.dart';

class TopicDetailScreen extends ConsumerStatefulWidget {
  const TopicDetailScreen({super.key, required this.topicId});

  final int topicId;

  @override
  ConsumerState<TopicDetailScreen> createState() => _TopicDetailScreenState();
}

class _TopicDetailScreenState extends ConsumerState<TopicDetailScreen> {
  final _searchController = TextEditingController();
  String _search = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statsAsync = ref.watch(topicStatsProvider);
    final cardsAsync = ref.watch(
      cardsProvider(CardQuery(topicId: widget.topicId, search: _search)),
    );

    final stats = statsAsync.valueOrNull
        ?.where((s) => s.topic.id == widget.topicId)
        .firstOrNull;

    // The topic was deleted (possibly from the browser) while this was open.
    if (statsAsync.hasValue && stats == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final topic = stats?.topic;
    final accent =
        topic == null ? theme.colorScheme.primary : Color(topic.colorValue);

    return Scaffold(
      appBar: AppBar(
        title: Text(topic?.name ?? 'Topic'),
        actions: [
          if (topic != null)
            IconButton(
              tooltip: 'Edit topic',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => showTopicEditor(context, topic: topic),
            ),
          if (topic != null)
            IconButton(
              tooltip: 'Delete topic',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteTopic(topic, stats!.total),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (stats != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 16, horizontal: 18),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            StatChip(
                                label: 'due',
                                value: '${stats.due}',
                                color: stats.due > 0 ? accent : null),
                            StatChip(label: 'new', value: '${stats.fresh}'),
                            StatChip(
                                label: 'studied', value: '${stats.studied}'),
                            StatChip(label: 'total', value: '${stats.total}'),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: accent),
                      onPressed: stats.due == 0
                          ? null
                          : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ReviewScreen(
                                    topicId: widget.topicId,
                                    title: topic!.name,
                                  ),
                                ),
                              ),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(stats.due == 0
                          ? 'Nothing due right now'
                          : 'Study ${stats.due} ${stats.due == 1 ? 'card' : 'cards'}'),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _searchController,
                      onChanged: (v) => setState(() => _search = v),
                      decoration: InputDecoration(
                        hintText: 'Search cards…',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: _search.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _search = '');
                                },
                              ),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            Expanded(
              child: cardsAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => EmptyState(
                  icon: Icons.error_outline,
                  title: 'Could not load cards',
                  message: '$e',
                ),
                data: (cards) => cards.isEmpty
                    ? EmptyState(
                        icon: _search.isEmpty
                            ? Icons.note_add_outlined
                            : Icons.search_off,
                        title: _search.isEmpty
                            ? 'No cards yet'
                            : 'No matches',
                        message: _search.isEmpty
                            ? 'Add your first card to this topic and MemApp will '
                                'schedule it for you.'
                            : 'Nothing matched "$_search".',
                        action: _search.isEmpty
                            ? FilledButton.icon(
                                onPressed: _addCard,
                                icon: const Icon(Icons.add),
                                label: const Text('Add a card'),
                              )
                            : null,
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                        itemCount: cards.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => _CardTile(
                          card: cards[i],
                          accent: accent,
                          onDelete: () => _deleteCard(cards[i]),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCard,
        icon: const Icon(Icons.add),
        label: const Text('New card'),
      ),
    );
  }

  void _addCard() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CardEditorScreen(topicId: widget.topicId),
      ),
    );
  }

  Future<void> _deleteCard(MemCard card) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete card?',
      message: 'This removes the card and its review history permanently.',
    );
    if (!ok) return;
    await ref.read(databaseProvider).deleteCard(card.id);
    if (!mounted) return;
    await refreshRemindersFrom(ref);
    if (!mounted) return;
    showSnack(context, 'Card deleted');
  }

  Future<void> _deleteTopic(Topic topic, int cardCount) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete "${topic.name}"?',
      message: cardCount == 0
          ? 'This topic has no cards.'
          : 'This deletes $cardCount ${cardCount == 1 ? 'card' : 'cards'} and '
              'all their review history. This cannot be undone.',
    );
    if (!ok) return;
    await ref.read(databaseProvider).deleteTopic(topic.id);
    if (!mounted) return;
    await refreshRemindersFrom(ref);
    if (!mounted) return;
    Navigator.pop(context);
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile({
    required this.card,
    required this.accent,
    required this.onDelete,
  });

  final MemCard card;
  final Color accent;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dismissible(
      key: ValueKey(card.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        onDelete();
        return false;
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Icon(Icons.delete_outline,
            color: theme.colorScheme.onErrorContainer),
      ),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CardEditorScreen(
                topicId: card.topicId,
                card: card,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cardPreviewText(card.front),
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (card.back.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    cardPreviewText(card.back),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    _Tag(
                      label: card.suspended
                          ? 'Paused'
                          : card.isNew
                              ? 'New'
                              : card.isDue
                                  ? 'Due'
                                  : _relativeDue(card.dueUtc),
                      color: card.suspended
                          ? theme.colorScheme.onSurfaceVariant
                          : card.isDue || card.isNew
                              ? accent
                              : null,
                      filled: !card.suspended && (card.isDue || card.isNew),
                    ),
                    if (card.lapses > 0) ...[
                      const SizedBox(width: 6),
                      _Tag(
                        label: '${card.lapses} ${card.lapses == 1 ? 'lapse' : 'lapses'}',
                        color: theme.colorScheme.error,
                      ),
                    ],
                    for (final tag in card.tagList.take(2)) ...[
                      const SizedBox(width: 6),
                      _Tag(label: tag),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _relativeDue(DateTime dueUtc) {
    final diff = dueUtc.toLocal().difference(DateTime.now());
    return 'in ${formatInterval(diff)}';
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.color, this.filled = false});

  final String label;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: filled ? tone : Colors.transparent,
        border: Border.all(
            color: filled ? Colors.transparent : theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: filled ? Colors.white : tone,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
