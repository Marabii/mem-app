import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The pure text half of the card editor's formatting toolbar: given what is
/// in a field and where the cursor is, work out what should be in it next.
///
/// Kept free of widgets so the fiddly cases — an empty selection, a cursor
/// mid-line, a field that has never been focused — can be tested directly.
abstract final class MarkdownActions {
  /// Wraps [selection] in a fenced block, or drops in an empty one with the
  /// cursor already inside it.
  ///
  /// Fences only start a block at the beginning of a line and need a blank
  /// line after a paragraph, so surrounding newlines are added as needed and
  /// never doubled up.
  static TextEditingValue insertCodeBlock(
    TextEditingValue value,
    String language,
  ) {
    final selection = _safeSelection(value);
    final before = value.text.substring(0, selection.start);
    final after = value.text.substring(selection.end);
    final body = value.text.substring(selection.start, selection.end).trim();

    final lead = _leadingBreak(before);
    final trail = _trailingBreak(after);
    final open = '```$language\n';
    const close = '\n```';

    final text = '$before$lead$open$body$close$trail$after';
    // Empty block: sit on the blank line between the fences. Wrapped text:
    // sit at the end of it, ready to keep typing.
    final cursor = before.length + lead.length + open.length + body.length;

    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
      composing: TextRange.empty,
    );
  }

  /// `**bold**`, `*italic*`, `` `code` `` — wraps the selection, or leaves the
  /// cursor between a fresh pair of markers.
  static TextEditingValue wrapInline(TextEditingValue value, String marker) {
    final selection = _safeSelection(value);
    final before = value.text.substring(0, selection.start);
    final after = value.text.substring(selection.end);
    final body = value.text.substring(selection.start, selection.end);

    // Toggle off when the selection is already wrapped, so tapping bold twice
    // returns the text to where it started.
    if (before.endsWith(marker) && after.startsWith(marker)) {
      final text = before.substring(0, before.length - marker.length) +
          body +
          after.substring(marker.length);
      final start = before.length - marker.length;
      return TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: start, extentOffset: start + body.length),
        composing: TextRange.empty,
      );
    }

    final text = '$before$marker$body$marker$after';
    final start = before.length + marker.length;
    return TextEditingValue(
      text: text,
      selection: body.isEmpty
          ? TextSelection.collapsed(offset: start)
          : TextSelection(baseOffset: start, extentOffset: start + body.length),
      composing: TextRange.empty,
    );
  }

  /// Applies [edit] to [controller] and keeps the keyboard where it was.
  static void apply(
    TextEditingController controller,
    TextEditingValue edit, {
    bool haptic = true,
  }) {
    controller.value = edit;
    if (haptic) HapticFeedback.selectionClick();
  }

  /// A field that has never held the cursor reports an invalid selection;
  /// treat that as "append at the end".
  static TextSelection _safeSelection(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: value.text.length);
    }
    return TextSelection(
      baseOffset: selection.start,
      extentOffset: selection.end,
    );
  }

  static String _leadingBreak(String before) {
    if (before.isEmpty || before.endsWith('\n\n')) return '';
    return before.endsWith('\n') ? '\n' : '\n\n';
  }

  static String _trailingBreak(String after) {
    if (after.isEmpty) return '\n';
    return after.startsWith('\n') ? '' : '\n\n';
  }
}
