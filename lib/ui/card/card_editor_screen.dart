import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/fsrs_mapping.dart';
import '../../services/highlight/code_language.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';
import 'markdown_actions.dart';

class CardEditorScreen extends ConsumerStatefulWidget {
  const CardEditorScreen({super.key, required this.topicId, this.card});

  final int topicId;
  final MemCard? card;

  @override
  ConsumerState<CardEditorScreen> createState() => _CardEditorScreenState();
}

class _CardEditorScreenState extends ConsumerState<CardEditorScreen> {
  late final _front = TextEditingController(text: widget.card?.front ?? '');
  late final _back = TextEditingController(text: widget.card?.back ?? '');
  late final _tags =
      TextEditingController(text: widget.card?.tagList.join(', ') ?? '');
  final _frontFocus = FocusNode();
  final _backFocus = FocusNode();

  late int _topicId = widget.card?.topicId ?? widget.topicId;
  late bool _suspended = widget.card?.suspended ?? false;

  bool _preview = false;
  bool _saving = false;

  bool get _isEditing => widget.card != null;

  @override
  void dispose() {
    _front.dispose();
    _back.dispose();
    _tags.dispose();
    _frontFocus.dispose();
    _backFocus.dispose();
    super.dispose();
  }

  /// Asks which language, then drops a fence into [controller] around whatever
  /// was selected.
  Future<void> _insertCodeBlock(
    TextEditingController controller,
    FocusNode focus,
  ) async {
    final settings = ref.read(settingsProvider);
    final language = await showCodeLanguageSheet(
      context,
      selected: settings.codeLanguage,
    );
    if (language == null || !mounted) return;

    if (language != settings.codeLanguage) {
      await ref
          .read(settingsProvider.notifier)
          .edit((s) => s.copyWith(codeLanguage: language));
    }
    MarkdownActions.apply(
      controller,
      MarkdownActions.insertCodeBlock(controller.value, language),
    );
    focus.requestFocus();
  }

  String get _normalizedTags => _tags.text
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .join(',');

  Future<bool> _save({bool keepOpen = false}) async {
    final front = _front.text.trim();
    if (front.isEmpty) {
      showSnack(context, 'The front of the card cannot be empty',
          isError: true);
      return false;
    }
    setState(() => _saving = true);
    final db = ref.read(databaseProvider);

    try {
      if (_isEditing) {
        await db.updateCard(widget.card!.copyWith(
          topicId: _topicId,
          front: front,
          back: _back.text.trim(),
          tags: _normalizedTags,
          suspended: _suspended,
        ));
      } else {
        await db.insertCard(newCardCompanion(
          topicId: _topicId,
          front: front,
          back: _back.text.trim(),
          tags: _normalizedTags,
        ));
      }
      if (!mounted) return false;
      await refreshRemindersFrom(ref);
      if (!mounted) return false;

      if (keepOpen) {
        // Quick-add: clear the fields and stay put so a run of cards can be
        // typed without bouncing back to the list each time.
        setState(() {
          _front.clear();
          _back.clear();
          _saving = false;
          _preview = false;
        });
        _frontFocus.requestFocus();
        showSnack(context, 'Saved — add another');
        return true;
      }

      Navigator.pop(context);
      return true;
    } catch (e) {
      if (!mounted) return false;
      setState(() => _saving = false);
      showSnack(context, 'Could not save: $e', isError: true);
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topics = ref.watch(topicsProvider).valueOrNull ?? const <Topic>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit card' : 'New card'),
        actions: [
          IconButton(
            tooltip: _preview ? 'Edit' : 'Preview markdown',
            icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined),
            onPressed: () => setState(() => _preview = !_preview),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
          children: [
            if (topics.length > 1) ...[
              DropdownButtonFormField<int>(
                initialValue: topics.any((t) => t.id == _topicId)
                    ? _topicId
                    : topics.first.id,
                decoration: const InputDecoration(labelText: 'Topic'),
                items: [
                  for (final topic in topics)
                    DropdownMenuItem(
                      value: topic.id,
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: Color(topic.colorValue),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(topic.name),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _topicId = v ?? _topicId),
              ),
              const SizedBox(height: 16),
            ],
            _FieldLabel(
              'Front',
              hint: 'the question',
              trailing: _preview
                  ? null
                  : _FormatBar(
                      controller: _front,
                      focusNode: _frontFocus,
                      onInsertCode: () => _insertCodeBlock(_front, _frontFocus),
                    ),
            ),
            if (_preview)
              _PreviewBox(data: _front.text)
            else
              TextField(
                controller: _front,
                focusNode: _frontFocus,
                autofocus: !_isEditing,
                maxLines: null,
                minLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'What does Rust\'s `?` operator do?',
                ),
              ),
            const SizedBox(height: 20),
            _FieldLabel(
              'Back',
              hint: 'the answer',
              trailing: _preview
                  ? null
                  : _FormatBar(
                      controller: _back,
                      focusNode: _backFocus,
                      onInsertCode: () => _insertCodeBlock(_back, _backFocus),
                    ),
            ),
            if (_preview)
              _PreviewBox(data: _back.text)
            else
              TextField(
                controller: _back,
                focusNode: _backFocus,
                maxLines: null,
                minLines: 6,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(height: 1.5),
                decoration: const InputDecoration(
                  hintText:
                      'Markdown works here.\n\n```rust\nlet f = File::open(p)?;\n```',
                ),
              ),
            const SizedBox(height: 20),
            _FieldLabel('Tags', hint: 'comma separated, optional'),
            TextField(
              controller: _tags,
              decoration: const InputDecoration(hintText: 'ownership, errors'),
            ),
            if (_isEditing) ...[
              const SizedBox(height: 24),
              SettingsGroup(children: [
                SwitchListTile(
                  value: _suspended,
                  onChanged: (v) => setState(() => _suspended = v),
                  title: const Text('Pause this card'),
                  subtitle: const Text(
                      'Keeps it out of reviews without deleting it'),
                ),
              ]),
              const SizedBox(height: 16),
              _ScheduleSummary(card: widget.card!),
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Row(
            children: [
              if (!_isEditing) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => _save(keepOpen: true),
                    child: const Text('Save & add another'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: FilledButton(
                  onPressed: _saving
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          _save();
                        },
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : Text(_isEditing ? 'Save' : 'Add card'),
                ),
              ),
            ],
          ),
        ),
      ),
      // Give the preview toggle somewhere obvious to live on small screens.
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      backgroundColor: theme.scaffoldBackgroundColor,
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label, {this.hint, this.trailing});

  final String label;
  final String? hint;

  /// Formatting buttons for the field this label belongs to.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Row(
        children: [
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (hint != null) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '— ${hint!}',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// Markdown shortcuts for one text field: a code block, plus the three inline
/// markers that are awkward to type on a phone keyboard.
class _FormatBar extends StatelessWidget {
  const _FormatBar({
    required this.controller,
    required this.focusNode,
    required this.onInsertCode,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onInsertCode;

  void _wrap(String marker) {
    MarkdownActions.apply(
      controller,
      MarkdownActions.wrapInline(controller.value, marker),
    );
    focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget button(IconData icon, String tooltip, VoidCallback onPressed) =>
        IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          icon: Icon(icon),
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(),
          color: theme.colorScheme.onSurfaceVariant,
        );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(Icons.format_bold, 'Bold', () => _wrap('**')),
        button(Icons.format_italic, 'Italic', () => _wrap('*')),
        button(Icons.code, 'Inline code', () => _wrap('`')),
        const SizedBox(width: 4),
        // The headline action, so it gets a label rather than an icon.
        TextButton.icon(
          onPressed: onInsertCode,
          icon: const Icon(Icons.data_object, size: 17),
          label: const Text('Code block'),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            textStyle: theme.textTheme.labelMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// Language picker for a new code block. Returns the fence info string to use,
/// or null if the sheet was dismissed.
Future<String?> showCodeLanguageSheet(
  BuildContext context, {
  required String selected,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                child: Text('Code block language',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Text(
                  'The block is highlighted here and in the browser editor.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final language in CodeLanguages.all)
                      ListTile(
                        onTap: () => Navigator.pop(context, language.id),
                        title: Text(language.label),
                        subtitle: Text('```${language.id}'),
                        dense: true,
                        trailing: language.id == selected
                            ? Icon(Icons.check_rounded,
                                color: theme.colorScheme.primary)
                            : null,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _PreviewBox extends StatelessWidget {
  const _PreviewBox({required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 90),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: CardContent(data: data),
    );
  }
}

/// Read-only view of what FSRS currently knows about this card.
class _ScheduleSummary extends StatelessWidget {
  const _ScheduleSummary({required this.card});

  final MemCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final due = card.dueUtc.toLocal();
    final relative = due.difference(DateTime.now());

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Schedule',
                style: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                StatChip(
                  label: card.isNew ? 'state' : 'due',
                  value: card.isNew
                      ? 'New'
                      : relative.isNegative
                          ? 'Now'
                          : formatInterval(relative),
                ),
                StatChip(label: 'reviews', value: '${card.reps}'),
                StatChip(
                  label: 'lapses',
                  value: '${card.lapses}',
                  color: card.lapses > 0 ? theme.colorScheme.error : null,
                ),
                StatChip(
                  label: 'difficulty',
                  value: card.difficulty == null
                      ? '—'
                      : card.difficulty!.toStringAsFixed(1),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
