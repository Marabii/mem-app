import 'package:flutter/foundation.dart';

import 'code_language.dart';

/// The colourable classes of source text. Anything the scanner cannot place
/// (operators, brackets, whitespace) comes back as [plain].
enum CodeTokenType {
  plain,
  keyword,
  type,
  literal,
  number,
  string,
  comment,
  function,

  /// Attributes, annotations, preprocessor directives, shell variables and
  /// Rust lifetimes — the "this is about the code" layer.
  meta,
}

@immutable
class CodeToken {
  const CodeToken(this.type, this.text);

  final CodeTokenType type;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is CodeToken && other.type == type && other.text == text;

  @override
  int get hashCode => Object.hash(type, text);

  @override
  String toString() => '${type.name}(${text.replaceAll('\n', r'\n')})';
}

/// Splits [source] into coloured spans according to [language].
///
/// A single forward pass, no backtracking, no regular expressions: card bodies
/// are short but this runs on every frame a card is rebuilt, and the result is
/// tokens the widget layer turns into `TextSpan`s.
///
/// Unterminated strings and comments are common in a flashcard fragment, so
/// every scanner ends at the end of the source rather than giving up — half a
/// string still colours as a string.
List<CodeToken> highlightCode(String source, CodeLanguage language) {
  if (source.isEmpty) return const <CodeToken>[];
  if (language.isPlain) return <CodeToken>[CodeToken(CodeTokenType.plain, source)];
  return _Scanner(source, language).run();
}

class _Scanner {
  _Scanner(this.src, this.lang);

  final String src;
  final CodeLanguage lang;

  final List<CodeToken> _out = <CodeToken>[];
  final StringBuffer _plain = StringBuffer();
  int _i = 0;

  List<CodeToken> run() {
    while (_i < src.length) {
      final consumed = _comment() ||
          _metaPrefix() ||
          _rawString() ||
          _string() ||
          _quoteLike() ||
          _number() ||
          _word();
      if (!consumed) {
        _plain.write(src[_i]);
        _i++;
      }
    }
    _flush();
    return _out;
  }

  // ------------------------------------------------------------- emitting

  void _flush() {
    if (_plain.isEmpty) return;
    _out.add(CodeToken(CodeTokenType.plain, _plain.toString()));
    _plain.clear();
  }

  /// Emits `src[_i..end)` as [type] and moves the cursor to `end`.
  bool _emit(CodeTokenType type, int end) {
    _flush();
    _out.add(CodeToken(type, src.substring(_i, end)));
    _i = end;
    return true;
  }

  // ------------------------------------------------------------- scanners

  bool _comment() {
    for (final marker in lang.lineComments) {
      if (_startsWith(marker)) {
        final newline = src.indexOf('\n', _i);
        return _emit(CodeTokenType.comment,
            newline == -1 ? src.length : newline);
      }
    }

    final block = lang.blockComment;
    if (block == null || !_startsWith(block.$1)) return false;

    var depth = 0;
    var j = _i;
    while (j < src.length) {
      if (src.startsWith(block.$2, j)) {
        depth--;
        j += block.$2.length;
        if (depth == 0) break;
      } else if (src.startsWith(block.$1, j)) {
        // Without nesting, an inner `/*` is just text inside the comment.
        if (depth == 0 || lang.nestedBlockComments) depth++;
        j += block.$1.length;
      } else {
        j++;
      }
    }
    return _emit(CodeTokenType.comment, j);
  }

  /// `#include`, `#[derive(Debug)]`, `@Override`, `$HOME`.
  bool _metaPrefix() {
    final c = src[_i];

    if (lang.attributes && (_startsWith('#[') || _startsWith('#!['))) {
      var depth = 0;
      var j = _i;
      while (j < src.length) {
        final ch = src[j];
        if (ch == '[') depth++;
        if (ch == ']') {
          j++;
          depth--;
          if (depth == 0) break;
          continue;
        }
        if (ch == '\n' && depth == 0) break;
        j++;
      }
      return _emit(CodeTokenType.meta, j);
    }

    if (c == '#' && lang.preprocessor && _atLineStart()) {
      var j = _i + 1;
      while (j < src.length && (src[j] == ' ' || src[j] == '\t')) {
        j++;
      }
      while (j < src.length && _isWordChar(src.codeUnitAt(j))) {
        j++;
      }
      _emit(CodeTokenType.meta, j);
      // `#include <stdio.h>` — the angle-bracket path is a string, not a
      // less-than comparison.
      final rest = _skipSpaces(_i);
      if (rest < src.length && src[rest] == '<') {
        final close = src.indexOf('>', rest);
        final newline = src.indexOf('\n', rest);
        if (close != -1 && (newline == -1 || close < newline)) {
          _plain.write(src.substring(_i, rest));
          _i = rest;
          _emit(CodeTokenType.string, close + 1);
        }
      }
      return true;
    }

    if (c == '@' && lang.annotations && _i + 1 < src.length &&
        _isWordStart(src.codeUnitAt(_i + 1))) {
      var j = _i + 1;
      while (j < src.length && (_isWordChar(src.codeUnitAt(j)) || src[j] == '.')) {
        j++;
      }
      return _emit(CodeTokenType.meta, j);
    }

    if (c == r'$' && lang.dollarVariables && _i + 1 < src.length) {
      final next = src[_i + 1];
      if (next == '{') {
        final close = src.indexOf('}', _i);
        return _emit(CodeTokenType.meta,
            close == -1 ? src.length : close + 1);
      }
      if (_isWordChar(src.codeUnitAt(_i + 1))) {
        var j = _i + 1;
        while (j < src.length && _isWordChar(src.codeUnitAt(j))) {
          j++;
        }
        return _emit(CodeTokenType.meta, j);
      }
    }

    return false;
  }

  /// Rust `r"…"` / `r#"…"#` / `br#"…"#`, and C++ `R"delim(…)delim"`.
  bool _rawString() {
    if (lang.rustRawStrings) {
      var j = _i;
      if (src[j] == 'b' && j + 1 < src.length) j++;
      if (src[j] == 'r') {
        var hashes = 0;
        var k = j + 1;
        while (k < src.length && src[k] == '#') {
          hashes++;
          k++;
        }
        if (k < src.length && src[k] == '"') {
          final terminator = '"${'#' * hashes}';
          final close = src.indexOf(terminator, k + 1);
          return _emit(CodeTokenType.string,
              close == -1 ? src.length : close + terminator.length);
        }
      }
    }

    if (lang.cppRawStrings && src[_i] == 'R' && _startsWith('R"')) {
      final open = src.indexOf('(', _i + 2);
      if (open != -1) {
        final delimiter = src.substring(_i + 2, open);
        final terminator = ')$delimiter"';
        final close = src.indexOf(terminator, open);
        return _emit(CodeTokenType.string,
            close == -1 ? src.length : close + terminator.length);
      }
    }

    return false;
  }

  bool _string() {
    var start = _i;

    // Python-style prefixes: f"", rb'', u"".
    if (lang.stringPrefixes.isNotEmpty && _isWordStart(src.codeUnitAt(_i))) {
      var j = _i;
      while (j < src.length && j - _i < 2 && _isWordChar(src.codeUnitAt(j))) {
        j++;
      }
      final prefix = src.substring(_i, j).toLowerCase();
      if (j < src.length &&
          lang.stringDelimiters.contains(src[j]) &&
          lang.stringPrefixes.contains(prefix)) {
        start = j;
      } else {
        return false;
      }
    }

    final quote = src[start];
    if (!lang.stringDelimiters.contains(quote)) return false;

    if (lang.tripleQuotes && src.startsWith(quote * 3, start)) {
      final terminator = quote * 3;
      final close = src.indexOf(terminator, start + 3);
      return _emit(CodeTokenType.string,
          close == -1 ? src.length : close + 3);
    }

    final end = _scanQuoted(start, quote);
    return _emit(CodeTokenType.string, end);
  }

  /// A leading `'` that is either a character literal or a Rust lifetime.
  bool _quoteLike() {
    if (src[_i] != "'") return false;
    if (!lang.charLiterals && !lang.lifetimes) return false;

    if (lang.charLiterals) {
      final end = _scanCharLiteral(_i);
      if (end != -1) return _emit(CodeTokenType.string, end);
    }

    if (lang.lifetimes &&
        _i + 1 < src.length &&
        _isWordStart(src.codeUnitAt(_i + 1))) {
      var j = _i + 1;
      while (j < src.length && _isWordChar(src.codeUnitAt(j))) {
        j++;
      }
      return _emit(CodeTokenType.meta, j);
    }

    return false;
  }

  bool _number() {
    final c = src.codeUnitAt(_i);
    // `.5` is a number; the `.10` inside Rust's `0..10` is not.
    final isLeadingDot = c == 0x2E && // '.'
        _i + 1 < src.length &&
        _isDigit(src.codeUnitAt(_i + 1)) &&
        (_i == 0 || src[_i - 1] != '.');
    if (!_isDigit(c) && !isLeadingDot) return false;

    var j = isLeadingDot ? _i + 1 : _i;
    while (j < src.length) {
      final u = src.codeUnitAt(j);
      // `1e-9`, `0x1p+3`.
      if ((u == 0x65 || u == 0x45 || u == 0x70 || u == 0x50) &&
          j + 1 < src.length &&
          (src[j + 1] == '+' || src[j + 1] == '-')) {
        j += 2;
        continue;
      }
      if (_isWordChar(u)) {
        j++;
        continue;
      }
      // A dot only continues the number when a digit follows, so Rust's
      // `0..10` and Dart's `1.toString()` stay intact.
      if (u == 0x2E && j + 1 < src.length && _isDigit(src.codeUnitAt(j + 1))) {
        j++;
        continue;
      }
      break;
    }
    return _emit(CodeTokenType.number, j);
  }

  bool _word() {
    if (!_isWordStart(src.codeUnitAt(_i))) return false;

    var j = _i;
    while (j < src.length && _isWordChar(src.codeUnitAt(j))) {
      j++;
    }
    final word = src.substring(_i, j);
    final needle = lang.caseInsensitiveKeywords ? word.toLowerCase() : word;

    if (lang.keywords.contains(needle)) return _emit(CodeTokenType.keyword, j);
    if (lang.literals.contains(needle)) return _emit(CodeTokenType.literal, j);
    if (lang.types.contains(needle)) return _emit(CodeTokenType.type, j);

    // `println!(…)`, `vec![…]`.
    if (lang.macroBang && j < src.length && src[j] == '!' &&
        (j + 1 >= src.length || src[j + 1] != '=')) {
      return _emit(CodeTokenType.function, j + 1);
    }

    final next = _skipSpaces(j);
    if (next < src.length && src[next] == '(') {
      return _emit(CodeTokenType.function, j);
    }
    if (lang.typesByCase && _isUpper(src.codeUnitAt(_i))) {
      return _emit(CodeTokenType.type, j);
    }

    return _emit(CodeTokenType.plain, j);
  }

  // -------------------------------------------------------------- helpers

  /// End of the character literal opening at [start], or -1 if what follows
  /// the quote is not one.
  ///
  /// The shape has to be checked exactly rather than "scan to the next quote":
  /// in `fn longest<'a>(x: &'a str)` a loose scan would swallow everything
  /// between the two lifetimes and call it a character.
  int _scanCharLiteral(int start) {
    var j = start + 1;
    if (j >= src.length) return -1;

    if (src[j] == r'\') {
      j++;
      if (j >= src.length) return -1;
      if (src[j] == 'u' && j + 1 < src.length && src[j + 1] == '{') {
        final close = src.indexOf('}', j);
        if (close == -1) return -1;
        j = close + 1;
      } else {
        j++; // the escaped letter itself
        // Numeric escapes: \x41, A, \101.
        while (j < src.length && _isHexDigit(src.codeUnitAt(j))) {
          j++;
        }
      }
    } else {
      final u = src.codeUnitAt(j);
      if (u == 0x27 || u == 0x0A) return -1; // '' or a line break
      // Keep a surrogate pair (an emoji, say) together.
      j += (u >= 0xD800 && u <= 0xDBFF) ? 2 : 1;
    }

    if (j < src.length && src[j] == "'") return j + 1;
    return -1;
  }

  /// Scans from an opening [quote] at [start] to its unescaped partner, a
  /// newline, or [limit] characters — whichever comes first.
  int _scanQuoted(int start, String quote, {int? limit}) {
    final stop = limit == null ? src.length : (start + limit).clamp(0, src.length);
    var j = start + 1;
    while (j < stop) {
      final ch = src[j];
      if (ch == r'\') {
        j += 2;
        continue;
      }
      if (ch == '\n') return j;
      j++;
      if (ch == quote) return j;
    }
    return stop;
  }

  int _skipSpaces(int from) {
    var j = from;
    while (j < src.length && (src[j] == ' ' || src[j] == '\t')) {
      j++;
    }
    return j;
  }

  bool _startsWith(String pattern) => src.startsWith(pattern, _i);

  bool _atLineStart() {
    for (var j = _i - 1; j >= 0; j--) {
      final ch = src[j];
      if (ch == '\n') return true;
      if (ch != ' ' && ch != '\t') return false;
    }
    return true;
  }

  static bool _isDigit(int u) => u >= 0x30 && u <= 0x39;

  static bool _isHexDigit(int u) =>
      _isDigit(u) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66);

  static bool _isUpper(int u) => u >= 0x41 && u <= 0x5A;

  static bool _isWordStart(int u) =>
      (u >= 0x41 && u <= 0x5A) ||
      (u >= 0x61 && u <= 0x7A) ||
      u == 0x5F || // _
      u == 0x24 || // $
      u > 0x7F; // keep identifiers with accents in one piece

  static bool _isWordChar(int u) => _isWordStart(u) || _isDigit(u);
}
