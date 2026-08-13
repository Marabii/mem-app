import 'package:flutter/material.dart';
import 'package:flutter_application_1/ui/card/markdown_actions.dart';
import 'package:flutter_application_1/ui/widgets/code_block.dart';
import 'package:flutter_application_1/ui/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('inserting a code block', () {
    TextEditingValue at(String text, int offset) => TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: offset),
        );

    test('into an empty field leaves the caret inside the fence', () {
      final result = MarkdownActions.insertCodeBlock(at('', 0), 'rust');

      expect(result.text, '```rust\n\n```\n');
      expect(result.selection.baseOffset, '```rust\n'.length);
    });

    test('after a paragraph adds the blank line a fence needs', () {
      final result =
          MarkdownActions.insertCodeBlock(at('The answer:', 11), 'java');

      expect(result.text, 'The answer:\n\n```java\n\n```\n');
    });

    test('does not stack blank lines that are already there', () {
      final result =
          MarkdownActions.insertCodeBlock(at('Answer:\n\n', 9), 'c');

      expect(result.text, 'Answer:\n\n```c\n\n```\n');
    });

    test('wraps the selection and keeps the text around it', () {
      const text = 'before\nint x = 1;\nafter';
      final result = MarkdownActions.insertCodeBlock(
        const TextEditingValue(
          text: text,
          selection: TextSelection(baseOffset: 7, extentOffset: 17),
        ),
        'cpp',
      );

      // The line break already after the selection is reused, not doubled.
      expect(result.text, 'before\n\n```cpp\nint x = 1;\n```\nafter');
      // Caret at the end of the wrapped code, ready to keep typing.
      expect(result.text.substring(0, result.selection.baseOffset),
          'before\n\n```cpp\nint x = 1;');
    });

    test('a field that was never focused appends rather than throwing', () {
      const value = TextEditingValue(
        text: 'Question',
        selection: TextSelection.collapsed(offset: -1),
      );

      expect(MarkdownActions.insertCodeBlock(value, 'rust').text,
          'Question\n\n```rust\n\n```\n');
    });
  });

  group('inline markers', () {
    test('wrap a selection and put it back inside the markers', () {
      final result = MarkdownActions.wrapInline(
        const TextEditingValue(
          text: 'a word here',
          selection: TextSelection(baseOffset: 2, extentOffset: 6),
        ),
        '**',
      );

      expect(result.text, 'a **word** here');
      expect(result.selection.textInside(result.text), 'word');
    });

    test('an empty selection leaves the caret between the markers', () {
      final result = MarkdownActions.wrapInline(
        const TextEditingValue(
          text: 'x',
          selection: TextSelection.collapsed(offset: 1),
        ),
        '`',
      );

      expect(result.text, 'x``');
      expect(result.selection.baseOffset, 2);
    });

    test('applying the same marker twice removes it again', () {
      final wrapped = MarkdownActions.wrapInline(
        const TextEditingValue(
          text: 'a word',
          selection: TextSelection(baseOffset: 2, extentOffset: 6),
        ),
        '*',
      );
      final unwrapped = MarkdownActions.wrapInline(wrapped, '*');

      expect(wrapped.text, 'a *word*');
      expect(unwrapped.text, 'a word');
      expect(unwrapped.selection.textInside(unwrapped.text), 'word');
    });
  });

  group('list previews', () {
    test('unwrap a fenced block instead of showing its markers', () {
      expect(
        cardPreviewText('Propagates the error:\n\n```rust\nlet f = '
            'File::open(p)?;\n```'),
        'Propagates the error: let f = File::open(p)?;',
      );
    });

    test('drop inline markers and collapse whitespace', () {
      expect(cardPreviewText('The **`?`** operator\n\nunwraps'),
          'The ? operator unwraps');
    });

    test('survive an unclosed fence', () {
      expect(cardPreviewText('```java\nint x = 1;'), 'int x = 1;');
    });
  });

  group('rendering a card', () {
    Widget wrap(String data) => MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: CardContent(data: data))),
        );

    testWidgets('a fenced block becomes a CodeBlock with its language header',
        (tester) async {
      await tester.pumpWidget(wrap('Answer:\n\n```rust\nfn main() {}\n```'));

      final block = tester.widget<CodeBlock>(find.byType(CodeBlock));
      expect(block.language, 'rust');
      expect(block.code, 'fn main() {}');
      expect(find.text('RUST'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsOneWidget);
    });

    testWidgets('the language name survives an alias and unknown languages',
        (tester) async {
      await tester.pumpWidget(wrap('```c++\nint main() {}\n```'));
      expect(find.text('C++'), findsOneWidget);

      await tester.pumpWidget(wrap('```haskell\nmain = pure ()\n```'));
      expect(find.text('HASKELL'), findsOneWidget);
    });

    testWidgets('inline code is left as inline code', (tester) async {
      await tester.pumpWidget(wrap('Use the `?` operator'));

      expect(find.byType(CodeBlock), findsNothing);
    });

    testWidgets('tokens are coloured by class', (tester) async {
      await tester.pumpWidget(wrap('```rust\nlet x = 1; // note\n```'));

      final rich = tester.widget<Text>(
        find.descendant(of: find.byType(CodeBlock), matching: find.byType(Text)).last,
      );
      final spans = (rich.textSpan! as TextSpan).children!.cast<TextSpan>();
      Color? colorOf(String text) =>
          spans.firstWhere((s) => s.text == text).style?.color;

      expect(colorOf('let'), isNot(colorOf('x')));
      expect(colorOf('// note'), isNotNull);
      expect(spans.map((s) => s.text).join(), 'let x = 1; // note');
    });
  });
}
