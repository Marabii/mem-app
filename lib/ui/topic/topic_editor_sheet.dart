import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// Create/edit sheet for a topic. Returns the topic id on save, null on cancel.
Future<int?> showTopicEditor(BuildContext context, {Topic? topic}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _TopicEditor(topic: topic),
    ),
  );
}

class _TopicEditor extends ConsumerStatefulWidget {
  const _TopicEditor({this.topic});

  final Topic? topic;

  @override
  ConsumerState<_TopicEditor> createState() => _TopicEditorState();
}

class _TopicEditorState extends ConsumerState<_TopicEditor> {
  late final TextEditingController _name =
      TextEditingController(text: widget.topic?.name ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.topic?.description ?? '');
  late int _color = widget.topic?.colorValue ?? AppTheme.topicColors.first;

  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  bool get _isEditing => widget.topic != null;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final db = ref.read(databaseProvider);
    final name = _name.text.trim();
    final description = _description.text.trim();

    try {
      // The name column is unique, so a clash has to be caught before insert to
      // avoid surfacing a raw SQLite error.
      final clash = await db.topicByName(name);
      if (clash != null && clash.id != widget.topic?.id) {
        if (!mounted) return;
        setState(() => _saving = false);
        showSnack(context, 'A topic called "$name" already exists',
            isError: true);
        return;
      }

      final int id;
      if (_isEditing) {
        await db.updateTopic(widget.topic!.copyWith(
          name: name,
          description: Value(description.isEmpty ? null : description),
          colorValue: _color,
        ));
        id = widget.topic!.id;
      } else {
        id = await db.createTopic(
          name: name,
          description: description.isEmpty ? null : description,
          colorValue: _color,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, id);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(context, 'Could not save: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _isEditing ? 'Edit topic' : 'New topic',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _name,
                autofocus: !_isEditing,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Rust, DSA, Pharmacology…',
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Give the topic a name'
                    : null,
                onFieldSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Optional',
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Colour', style: theme.textTheme.labelLarge),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final value in AppTheme.topicColors)
                    _ColorDot(
                      color: Color(value),
                      selected: value == _color,
                      onTap: () => setState(() => _color = value),
                    ),
                ],
              ),
              const SizedBox(height: 26),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _saving ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          : Text(_isEditing ? 'Save' : 'Create topic'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.transparent,
            width: 3,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 20)
            : null,
      ),
    );
  }
}
