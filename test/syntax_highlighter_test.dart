import 'dart:math';

import 'package:flutter_application_1/services/highlight/code_language.dart';
import 'package:flutter_application_1/services/highlight/syntax_highlighter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// The tokens of [type] in [source], in order — enough to assert on a
  /// scanner's output without pinning down every space and bracket.
  List<String> of(String source, CodeLanguage language, CodeTokenType type) =>
      highlightCode(source, language)
          .where((t) => t.type == type)
          .map((t) => t.text)
          .toList();

  test('round-trips the source exactly', () {
    const sources = {
      CodeLanguages.rust: r'''
#[derive(Debug)]
struct Point { x: f64 }        // a comment
fn main() { println!("{:?} {}", Point { x: 1.5 }, 'c'); }
''',
      CodeLanguages.java: '''
@Override
public static void main(String[] args) { System.out.println("hi"); }
''',
      CodeLanguages.cpp: '''
#include <vector>
template <typename T> T max(T a, T b) { return a > b ? a : b; /* pick */ }
''',
    };

    for (final entry in sources.entries) {
      final joined =
          highlightCode(entry.value, entry.key).map((t) => t.text).join();
      expect(joined, entry.value, reason: entry.key.label);
    }
  });

  test('never loses or reorders a character, whatever the input', () {
    // Half-open strings, stray quotes and lone hashes are exactly what a
    // flashcard fragment looks like, and a scanner that drops one character
    // silently corrupts the card it is meant to render.
    const nasty = [
      '',
      '"',
      "'",
      '`',
      '#',
      '/*',
      '//',
      r'"\',
      "'\\",
      'r#"',
      'R"x(',
      '0..10',
      '1.',
      '.5',
      "let x = 'a",
      '#[derive(',
      '#include <',
      '"""',
      r'$',
      r'${',
      'é_ident',
      '😀',
      "'😀'",
    ];
    final random = Random(20260813);
    const alphabet = '\'"`#\\/*[]{}()<>.,;: \n\t0189abzABZ_\$!-é😀';
    final fuzz = List.generate(200, (_) {
      final length = random.nextInt(40);
      return String.fromCharCodes(List.generate(
          length, (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length))));
    });

    for (final language in CodeLanguages.all) {
      for (final source in [...nasty, ...fuzz]) {
        final tokens = highlightCode(source, language);
        expect(tokens.map((t) => t.text).join(), source,
            reason: '${language.id}: ${source.replaceAll('\n', r'\n')}');
      }
    }
  });

  group('Rust', () {
    const lang = CodeLanguages.rust;

    test('picks out keywords, types, macros and literals', () {
      const src = 'pub fn parse(s: &str) -> Option<u32> { None }';
      expect(of(src, lang, CodeTokenType.keyword), ['pub', 'fn']);
      expect(of(src, lang, CodeTokenType.type), containsAll(['str', 'u32']));
      expect(of(src, lang, CodeTokenType.function), ['parse']);
      expect(of(src, lang, CodeTokenType.literal), ['None']);
    });

    test('macro invocations keep their bang', () {
      expect(of('println!("x");', lang, CodeTokenType.function), ['println!']);
      expect(of('if a != b {}', lang, CodeTokenType.function), isEmpty);
    });

    test('lifetimes are not character literals', () {
      const src = "fn longest<'a>(x: &'a str, y: &'a str) -> &'a str";
      expect(of(src, lang, CodeTokenType.meta), ["'a", "'a", "'a", "'a"]);
      expect(of(src, lang, CodeTokenType.string), isEmpty);
    });

    test('character literals still work next to lifetimes', () {
      const src = "let c: char = 'x'; // &'a";
      expect(of(src, lang, CodeTokenType.string), ["'x'"]);
      expect(of(src, lang, CodeTokenType.comment), ["// &'a"]);
    });

    test('raw strings and nested block comments', () {
      expect(of(r'let p = r#"a "quoted" path"#;', lang, CodeTokenType.string),
          [r'r#"a "quoted" path"#']);
      expect(of('/* outer /* inner */ still */ code', lang,
          CodeTokenType.comment), ['/* outer /* inner */ still */']);
    });

    test('attributes are one meta token', () {
      expect(of('#[derive(Debug, Clone)]\nstruct S;', lang, CodeTokenType.meta),
          ['#[derive(Debug, Clone)]']);
    });

    test('a range is not a float', () {
      expect(of('for i in 0..10 {}', lang, CodeTokenType.number), ['0', '10']);
      expect(of('let x = 1_000.5e-3;', lang, CodeTokenType.number),
          ['1_000.5e-3']);
    });
  });

  group('Java', () {
    const lang = CodeLanguages.java;

    test('annotations, types and calls', () {
      const src = '@Override public String name() { return null; }';
      expect(of(src, lang, CodeTokenType.meta), ['@Override']);
      expect(of(src, lang, CodeTokenType.type), ['String']);
      expect(of(src, lang, CodeTokenType.function), ['name']);
      expect(of(src, lang, CodeTokenType.literal), ['null']);
    });

    test('escaped quotes stay inside the string', () {
      expect(of(r'String s = "a \" b"; int i;', lang, CodeTokenType.string),
          [r'"a \" b"']);
    });
  });

  group('C and C++', () {
    test('preprocessor directives and their include paths', () {
      const src = '#include <stdio.h>\n#define MAX 10';
      expect(of(src, CodeLanguages.c, CodeTokenType.meta),
          ['#include', '#define']);
      expect(of(src, CodeLanguages.c, CodeTokenType.string), ['<stdio.h>']);
    });

    test('C leaves SCREAMING_CASE alone, C++ colours type names', () {
      expect(of('MAX_SIZE + 1;', CodeLanguages.c, CodeTokenType.type), isEmpty);
      expect(of('std::vector<Widget> v;', CodeLanguages.cpp, CodeTokenType.type),
          containsAll(['std', 'vector', 'Widget']));
    });

    test('C++ raw strings', () {
      expect(
        of('auto s = R"json({"a": 1})json";', CodeLanguages.cpp,
            CodeTokenType.string),
        [r'R"json({"a": 1})json"'],
      );
    });

    test('a lone apostrophe does not swallow the rest of the line', () {
      expect(of("// it's fine\nint x;", CodeLanguages.c, CodeTokenType.comment),
          ["// it's fine"]);
      expect(of("int x; // don't\nint y;", CodeLanguages.c,
          CodeTokenType.string), isEmpty);
    });
  });

  group('other languages', () {
    test('Python f-strings, triple quotes and comments', () {
      const src = 'def f(x):\n    """doc"""\n    return f"{x}"  # done';
      expect(of(src, CodeLanguages.python, CodeTokenType.string),
          ['"""doc"""', 'f"{x}"']);
      expect(of(src, CodeLanguages.python, CodeTokenType.comment), ['# done']);
    });

    test('SQL keywords are case-insensitive', () {
      expect(of('SELECT * FROM t WHERE a = 1', CodeLanguages.sql,
          CodeTokenType.keyword), ['SELECT', 'FROM', 'WHERE']);
      expect(of('-- note\nselect 1', CodeLanguages.sql, CodeTokenType.comment),
          ['-- note']);
    });

    test('shell variables', () {
      expect(of(r'echo "$HOME ${USER}"', CodeLanguages.bash,
          CodeTokenType.string), [r'"$HOME ${USER}"']);
      expect(of(r'cd $HOME', CodeLanguages.bash, CodeTokenType.meta), [r'$HOME']);
    });

    test('plain text is one token', () {
      final tokens = highlightCode('just words 1 2 3', CodeLanguages.plain);
      expect(tokens, hasLength(1));
      expect(tokens.single.type, CodeTokenType.plain);
    });
  });

  group('lookup', () {
    test('resolves ids and aliases, case-insensitively', () {
      expect(CodeLanguages.lookup('rs'), CodeLanguages.rust);
      expect(CodeLanguages.lookup('C++'), CodeLanguages.cpp);
      expect(CodeLanguages.lookup(' Java '), CodeLanguages.java);
      expect(CodeLanguages.lookup('haskell'), isNull);
      expect(CodeLanguages.lookup(''), isNull);
    });

    test('labels unknown languages with what the fence said', () {
      expect(CodeLanguages.labelFor('haskell'), 'haskell');
      expect(CodeLanguages.labelFor(null), 'Plain text');
      expect(CodeLanguages.labelFor('cpp'), 'C++');
    });
  });
}
