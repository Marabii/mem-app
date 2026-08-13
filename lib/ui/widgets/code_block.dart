import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../services/highlight/code_language.dart';
import '../../services/highlight/syntax_highlighter.dart';
import '../../theme/app_theme.dart';

/// Colours for each [CodeTokenType], in both brightnesses.
///
/// Two hand-picked palettes rather than shades of the seed colour: code is
/// read by shape, and the categories have to stay apart from each other at a
/// glance on a phone screen.
@immutable
class CodeTheme {
  const CodeTheme({
    required this.background,
    required this.header,
    required this.border,
    required this.plain,
    required this.keyword,
    required this.type,
    required this.literal,
    required this.number,
    required this.string,
    required this.comment,
    required this.function,
    required this.meta,
  });

  final Color background;
  final Color header;
  final Color border;
  final Color plain;
  final Color keyword;
  final Color type;
  final Color literal;
  final Color number;
  final Color string;
  final Color comment;
  final Color function;
  final Color meta;

  static const dark = CodeTheme(
    background: Color(0xFF13161E),
    header: Color(0xFF1A1E28),
    border: Color(0xFF262B38),
    plain: Color(0xFFD5DAE5),
    keyword: Color(0xFFC792EA),
    type: Color(0xFFFFCB6B),
    literal: Color(0xFFF78C6C),
    number: Color(0xFFF78C6C),
    string: Color(0xFF9ECE6A),
    comment: Color(0xFF6B7385),
    function: Color(0xFF82AAFF),
    meta: Color(0xFF89DDFF),
  );

  static const light = CodeTheme(
    background: Color(0xFFF8F8FC),
    header: Color(0xFFF0F1F6),
    border: Color(0xFFE1E3EC),
    plain: Color(0xFF383A42),
    keyword: Color(0xFFA626A4),
    type: Color(0xFF9A6400),
    literal: Color(0xFFB2432F),
    number: Color(0xFFB2432F),
    string: Color(0xFF3F8F3B),
    comment: Color(0xFF9599A3),
    function: Color(0xFF3B69D6),
    meta: Color(0xFF0184BC),
  );

  static CodeTheme of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  Color colorFor(CodeTokenType type) => switch (type) {
        CodeTokenType.plain => plain,
        CodeTokenType.keyword => keyword,
        CodeTokenType.type => this.type,
        CodeTokenType.literal => literal,
        CodeTokenType.number => number,
        CodeTokenType.string => string,
        CodeTokenType.comment => comment,
        CodeTokenType.function => function,
        CodeTokenType.meta => meta,
      };
}

/// A fenced code block: language header, copy button, and the source coloured
/// by [highlightCode].
///
/// Lines are never wrapped — wrapped code is harder to read than code you
/// scroll, especially on a phone — so the body scrolls sideways on its own.
class CodeBlock extends StatefulWidget {
  const CodeBlock({
    super.key,
    required this.code,
    this.language,
    this.textStyle,
  });

  final String code;

  /// The fence's info string as written (`rust`, `c++`, or something this app
  /// cannot colour). Null for an indented block with no language at all.
  final String? language;

  final TextStyle? textStyle;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    HapticFeedback.selectionClick();
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Code copied'),
        duration: Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeTheme = CodeTheme.of(context);
    final language = CodeLanguages.lookup(widget.language) ?? CodeLanguages.plain;
    final tokens = highlightCode(widget.code, language);

    final base = widget.textStyle ?? theme.textTheme.bodyMedium!;
    final codeStyle = base.copyWith(
      fontFamily: AppTheme.monoFamily,
      fontSize: (base.fontSize ?? 15) - 1,
      height: 1.5,
      color: codeTheme.plain,
      backgroundColor: Colors.transparent,
      fontWeight: FontWeight.w400,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: codeTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: codeTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
            decoration: BoxDecoration(
              color: codeTheme.header,
              border: Border(bottom: BorderSide(color: codeTheme.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    CodeLanguages.labelFor(widget.language).toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: codeTheme.comment,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.9,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _copy,
                  tooltip: 'Copy code',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(),
                  color: codeTheme.comment,
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ),
          Scrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Text.rich(
                TextSpan(
                  children: [
                    for (final token in tokens)
                      TextSpan(
                        text: token.text,
                        style: TextStyle(
                          color: codeTheme.colorFor(token.type),
                          fontStyle: token.type == CodeTokenType.comment
                              ? FontStyle.italic
                              : FontStyle.normal,
                        ),
                      ),
                  ],
                ),
                style: codeStyle,
                softWrap: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hands every `<pre>` in a rendered card to [CodeBlock].
///
/// Registered for `pre` rather than `code` so that inline `` `spans` `` keep
/// the ordinary markdown styling — only real blocks get the header, the
/// colours and the sideways scroll.
class CodeBlockBuilder extends MarkdownElementBuilder {
  CodeBlockBuilder({this.textStyle});

  final TextStyle? textStyle;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // ```rust … ``` parses to <pre><code class="language-rust">.
    final code = element.children?.whereType<md.Element>().firstWhere(
          (child) => child.tag == 'code',
          orElse: () => element,
        );
    final className = code?.attributes['class'] ?? '';
    final language = className.startsWith('language-')
        ? className.substring('language-'.length)
        : null;

    return CodeBlock(
      code: _trimTrailingNewline(element.textContent),
      language: language,
      textStyle: textStyle,
    );
  }

  /// The parser appends a newline to every fenced block; rendering it would
  /// leave an empty line above the bottom border.
  static String _trimTrailingNewline(String code) {
    var end = code.length;
    while (end > 0 && (code[end - 1] == '\n' || code[end - 1] == '\r')) {
      end--;
    }
    return code.substring(0, end);
  }
}
