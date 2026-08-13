import 'package:flutter/foundation.dart';

/// Lexical description of one language, consumed by
/// `lib/services/highlight/syntax_highlighter.dart`.
///
/// This is deliberately a hand-rolled rule set rather than a highlighting
/// package: everything here is a few hundred bytes of const data, it needs no
/// grammar files at runtime, and it keeps the dependency list of an offline
/// app from growing for the sake of colouring twenty lines of code.
@immutable
class CodeLanguage {
  const CodeLanguage({
    required this.id,
    required this.label,
    this.aliases = const <String>[],
    this.keywords = const <String>{},
    this.types = const <String>{},
    this.literals = const <String>{},
    this.lineComments = const <String>['//'],
    this.blockComment,
    this.nestedBlockComments = false,
    this.stringDelimiters = const <String>{'"'},
    this.charLiterals = false,
    this.tripleQuotes = false,
    this.stringPrefixes = const <String>{},
    this.rustRawStrings = false,
    this.cppRawStrings = false,
    this.preprocessor = false,
    this.attributes = false,
    this.annotations = false,
    this.dollarVariables = false,
    this.macroBang = false,
    this.lifetimes = false,
    this.typesByCase = true,
    this.caseInsensitiveKeywords = false,
  });

  /// Canonical name, and what gets written into the ```` ```fence ```` .
  final String id;

  /// Human label for pickers and the code block header.
  final String label;

  /// Other names accepted in a fence info string (`c++`, `py`, `js`, …).
  final List<String> aliases;

  final Set<String> keywords;
  final Set<String> types;

  /// `true` / `null` / `None` — constants that read as values, not keywords.
  final Set<String> literals;

  final List<String> lineComments;
  final (String open, String close)? blockComment;

  /// Rust allows `/* /* … */ */`; C-family languages do not.
  final bool nestedBlockComments;

  final Set<String> stringDelimiters;

  /// `'a'` is a character, not the start of a string (C, C++, Java, Rust).
  final bool charLiterals;

  /// Python's `"""…"""`.
  final bool tripleQuotes;

  /// Letters allowed directly before a quote: `f"…"`, `b"…"`, `u"…"`.
  final Set<String> stringPrefixes;

  /// `r"…"`, `r#"…"#`, `br"…"`.
  final bool rustRawStrings;

  /// `R"delim(…)delim"`.
  final bool cppRawStrings;

  /// `#include`, `#define`, `#ifdef`.
  final bool preprocessor;

  /// `#[derive(Debug)]`, `#![no_std]`.
  final bool attributes;

  /// `@Override`, `@Deprecated`.
  final bool annotations;

  /// `$HOME`, `${PATH}`, `$1`.
  final bool dollarVariables;

  /// `println!` reads as a call, not an identifier followed by `!`.
  final bool macroBang;

  /// `&'a str` — a leading quote that is not a character literal.
  final bool lifetimes;

  /// Treat `CapitalisedIdentifiers` as type names. Right for Rust, Java, C++
  /// and Kotlin; wrong for C, where `SOME_MACRO` is not a type.
  final bool typesByCase;

  /// SQL's `SELECT` and `select` are the same word.
  final bool caseInsensitiveKeywords;

  bool get isPlain =>
      keywords.isEmpty &&
      types.isEmpty &&
      literals.isEmpty &&
      lineComments.isEmpty &&
      blockComment == null &&
      stringDelimiters.isEmpty;
}

/// Every language the app can colour, plus lookup by fence info string.
abstract final class CodeLanguages {
  // ------------------------------------------------------------------ Rust

  static const rust = CodeLanguage(
    id: 'rust',
    label: 'Rust',
    aliases: ['rs'],
    keywords: {
      'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn',
      'else', 'enum', 'extern', 'fn', 'for', 'if', 'impl', 'in', 'let', 'loop',
      'macro_rules', 'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return',
      'self', 'static', 'struct', 'super', 'trait', 'type', 'union', 'unsafe',
      'use', 'where', 'while', 'yield',
    },
    types: {
      'Self', 'bool', 'char', 'f32', 'f64', 'i8', 'i16', 'i32', 'i64', 'i128',
      'isize', 'str', 'u8', 'u16', 'u32', 'u64', 'u128', 'usize', 'String',
      'Vec', 'Option', 'Result', 'Box', 'Rc', 'Arc', 'RefCell', 'Cell',
      'HashMap', 'HashSet', 'BTreeMap', 'VecDeque', 'Cow',
    },
    literals: {'true', 'false', 'None'},
    blockComment: ('/*', '*/'),
    nestedBlockComments: true,
    charLiterals: true,
    rustRawStrings: true,
    attributes: true,
    macroBang: true,
    lifetimes: true,
  );

  // --------------------------------------------------------------------- C

  static const _cKeywords = <String>{
    'alignas', 'alignof', 'auto', 'break', 'case', 'const', 'continue',
    'default', 'do', 'else', 'enum', 'extern', 'for', 'goto', 'if', 'inline',
    'register', 'restrict', 'return', 'sizeof', 'static', 'struct', 'switch',
    'typedef', 'union', 'volatile', 'while', '_Atomic', '_Static_assert',
  };

  static const _cTypes = <String>{
    'bool', 'char', 'double', 'float', 'int', 'long', 'short', 'signed',
    'unsigned', 'void', 'size_t', 'ssize_t', 'ptrdiff_t', 'wchar_t',
    'int8_t', 'int16_t', 'int32_t', 'int64_t',
    'uint8_t', 'uint16_t', 'uint32_t', 'uint64_t', 'FILE', 'va_list',
  };

  static const c = CodeLanguage(
    id: 'c',
    label: 'C',
    aliases: ['h'],
    keywords: _cKeywords,
    types: _cTypes,
    literals: {'NULL', 'true', 'false'},
    blockComment: ('/*', '*/'),
    charLiterals: true,
    preprocessor: true,
    // SCREAMING_CASE macros are the norm in C; capitalisation says nothing
    // about whether a name is a type.
    typesByCase: false,
  );

  static const cpp = CodeLanguage(
    id: 'cpp',
    label: 'C++',
    aliases: ['c++', 'cc', 'cxx', 'hpp', 'hxx'],
    keywords: {
      ..._cKeywords,
      'catch', 'class', 'co_await', 'co_return', 'co_yield', 'concept',
      'consteval', 'constexpr', 'constinit', 'const_cast', 'decltype',
      'delete', 'dynamic_cast', 'explicit', 'export', 'final', 'friend',
      'mutable', 'namespace', 'new', 'noexcept', 'operator', 'override',
      'private', 'protected', 'public', 'reinterpret_cast', 'requires',
      'static_assert', 'static_cast', 'template', 'this', 'throw', 'try',
      'typeid', 'typename', 'using', 'virtual',
    },
    types: {
      ..._cTypes,
      'std', 'string', 'string_view', 'vector', 'array', 'map', 'set',
      'unordered_map', 'unordered_set', 'pair', 'tuple', 'optional',
      'variant', 'shared_ptr', 'unique_ptr', 'weak_ptr', 'span', 'auto',
    },
    literals: {'nullptr', 'true', 'false', 'NULL'},
    blockComment: ('/*', '*/'),
    charLiterals: true,
    cppRawStrings: true,
    preprocessor: true,
  );

  // ------------------------------------------------------------------ Java

  static const java = CodeLanguage(
    id: 'java',
    label: 'Java',
    keywords: {
      'abstract', 'assert', 'break', 'case', 'catch', 'class', 'continue',
      'default', 'do', 'else', 'enum', 'extends', 'final', 'finally', 'for',
      'goto', 'if', 'implements', 'import', 'instanceof', 'interface',
      'native', 'new', 'package', 'permits', 'private', 'protected', 'public',
      'record', 'return', 'sealed', 'static', 'strictfp', 'super', 'switch',
      'synchronized', 'this', 'throw', 'throws', 'transient', 'try', 'var',
      'volatile', 'while', 'yield',
    },
    types: {
      'boolean', 'byte', 'char', 'double', 'float', 'int', 'long', 'short',
      'void', 'String', 'Object', 'Integer', 'Long', 'Double', 'Float',
      'Boolean', 'Character', 'List', 'ArrayList', 'Map', 'HashMap', 'Set',
      'HashSet', 'Optional', 'Stream', 'Exception', 'RuntimeException',
    },
    literals: {'true', 'false', 'null'},
    blockComment: ('/*', '*/'),
    charLiterals: true,
    annotations: true,
  );

  // ---------------------------------------------------------------- others

  static const python = CodeLanguage(
    id: 'python',
    label: 'Python',
    aliases: ['py'],
    keywords: {
      'and', 'as', 'assert', 'async', 'await', 'break', 'case', 'class',
      'continue', 'def', 'del', 'elif', 'else', 'except', 'finally', 'for',
      'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'match',
      'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try', 'while',
      'with', 'yield',
    },
    types: {
      'bool', 'bytes', 'complex', 'dict', 'float', 'frozenset', 'int', 'list',
      'object', 'set', 'str', 'tuple', 'type',
    },
    literals: {'True', 'False', 'None', 'self', 'cls'},
    lineComments: ['#'],
    stringDelimiters: {'"', "'"},
    tripleQuotes: true,
    stringPrefixes: {'f', 'r', 'b', 'u', 'rb', 'br', 'fr', 'rf'},
    annotations: true,
    typesByCase: false,
  );

  static const javascript = CodeLanguage(
    id: 'javascript',
    label: 'JavaScript',
    aliases: ['js', 'ts', 'typescript', 'jsx', 'tsx'],
    keywords: {
      'as', 'async', 'await', 'break', 'case', 'catch', 'class', 'const',
      'continue', 'debugger', 'default', 'delete', 'do', 'else', 'export',
      'extends', 'finally', 'for', 'from', 'function', 'if', 'implements',
      'import', 'in', 'instanceof', 'interface', 'let', 'new', 'of',
      'private', 'protected', 'public', 'readonly', 'return', 'static',
      'super', 'switch', 'this', 'throw', 'try', 'type', 'typeof', 'var',
      'void', 'while', 'with', 'yield',
    },
    types: {
      'Array', 'Boolean', 'Date', 'Error', 'JSON', 'Map', 'Math', 'Number',
      'Object', 'Promise', 'RegExp', 'Set', 'String', 'Symbol', 'any',
      'boolean', 'never', 'number', 'string', 'unknown',
    },
    literals: {'true', 'false', 'null', 'undefined', 'NaN', 'Infinity'},
    blockComment: ('/*', '*/'),
    stringDelimiters: {'"', "'", '`'},
  );

  static const dart = CodeLanguage(
    id: 'dart',
    label: 'Dart',
    keywords: {
      'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
      'catch', 'class', 'const', 'continue', 'covariant', 'default',
      'deferred', 'do', 'else', 'enum', 'export', 'extends', 'extension',
      'external', 'factory', 'final', 'finally', 'for', 'get', 'hide', 'if',
      'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
      'mixin', 'new', 'on', 'operator', 'part', 'required', 'rethrow',
      'return', 'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync',
      'this', 'throw', 'try', 'typedef', 'var', 'void', 'while', 'with',
      'yield',
    },
    types: {
      'bool', 'double', 'dynamic', 'int', 'num', 'String', 'List', 'Map',
      'Set', 'Iterable', 'Future', 'Stream', 'Object', 'Record', 'Function',
    },
    literals: {'true', 'false', 'null'},
    blockComment: ('/*', '*/'),
    stringDelimiters: {'"', "'"},
    annotations: true,
  );

  static const kotlin = CodeLanguage(
    id: 'kotlin',
    label: 'Kotlin',
    aliases: ['kt', 'kts'],
    keywords: {
      'abstract', 'actual', 'annotation', 'as', 'break', 'by', 'catch',
      'class', 'companion', 'const', 'constructor', 'continue', 'crossinline',
      'data', 'do', 'else', 'enum', 'expect', 'external', 'final', 'finally',
      'for', 'fun', 'get', 'if', 'import', 'in', 'infix', 'init', 'inline',
      'inner', 'interface', 'internal', 'is', 'lateinit', 'noinline',
      'object', 'open', 'operator', 'out', 'override', 'package', 'private',
      'protected', 'public', 'reified', 'return', 'sealed', 'set', 'super',
      'suspend', 'this', 'throw', 'try', 'typealias', 'val', 'var', 'vararg',
      'when', 'where', 'while',
    },
    types: {
      'Any', 'Boolean', 'Byte', 'Char', 'Double', 'Float', 'Int', 'List',
      'Long', 'Map', 'MutableList', 'MutableMap', 'Nothing', 'Set', 'Short',
      'String', 'Unit', 'Array', 'Pair',
    },
    literals: {'true', 'false', 'null', 'it'},
    blockComment: ('/*', '*/'),
    stringDelimiters: {'"'},
    tripleQuotes: true,
    annotations: true,
  );

  static const go = CodeLanguage(
    id: 'go',
    label: 'Go',
    aliases: ['golang'],
    keywords: {
      'break', 'case', 'chan', 'const', 'continue', 'default', 'defer',
      'else', 'fallthrough', 'for', 'func', 'go', 'goto', 'if', 'import',
      'interface', 'map', 'package', 'range', 'return', 'select', 'struct',
      'switch', 'type', 'var',
    },
    types: {
      'any', 'bool', 'byte', 'complex64', 'complex128', 'error', 'float32',
      'float64', 'int', 'int8', 'int16', 'int32', 'int64', 'rune', 'string',
      'uint', 'uint8', 'uint16', 'uint32', 'uint64', 'uintptr',
    },
    literals: {'true', 'false', 'nil', 'iota'},
    blockComment: ('/*', '*/'),
    stringDelimiters: {'"', '`'},
    charLiterals: true,
  );

  static const sql = CodeLanguage(
    id: 'sql',
    label: 'SQL',
    keywords: {
      'add', 'all', 'alter', 'and', 'as', 'asc', 'begin', 'between', 'by',
      'case', 'cascade', 'check', 'commit', 'constraint', 'create', 'default',
      'delete', 'desc', 'distinct', 'drop', 'else', 'end', 'exists', 'foreign',
      'from', 'full', 'group', 'having', 'if', 'in', 'index', 'inner',
      'insert', 'into', 'is', 'join', 'key', 'left', 'like', 'limit', 'not',
      'null', 'offset', 'on', 'or', 'order', 'outer', 'primary', 'references',
      'returning', 'right', 'rollback', 'select', 'set', 'table', 'then',
      'transaction', 'union', 'unique', 'update', 'values', 'view', 'when',
      'where', 'with',
    },
    types: {
      'bigint', 'blob', 'boolean', 'char', 'date', 'datetime', 'decimal',
      'double', 'float', 'int', 'integer', 'numeric', 'real', 'serial',
      'text', 'timestamp', 'varchar',
    },
    lineComments: ['--'],
    blockComment: ('/*', '*/'),
    stringDelimiters: {"'", '"'},
    typesByCase: false,
    caseInsensitiveKeywords: true,
  );

  static const bash = CodeLanguage(
    id: 'bash',
    label: 'Shell',
    aliases: ['sh', 'shell', 'zsh', 'console'],
    keywords: {
      'alias', 'break', 'case', 'continue', 'declare', 'do', 'done', 'elif',
      'else', 'esac', 'eval', 'exec', 'exit', 'export', 'fi', 'for',
      'function', 'if', 'in', 'local', 'read', 'readonly', 'return', 'select',
      'set', 'shift', 'source', 'then', 'trap', 'unset', 'until', 'while',
    },
    types: {
      'apt', 'awk', 'cargo', 'cat', 'cd', 'chmod', 'cp', 'curl', 'echo',
      'find', 'g++', 'gcc', 'git', 'grep', 'java', 'javac', 'kill', 'ls',
      'make', 'mkdir', 'mv', 'printf', 'rm', 'rustc', 'sed', 'sudo', 'tar',
      'wget',
    },
    lineComments: ['#'],
    stringDelimiters: {'"', "'"},
    dollarVariables: true,
    typesByCase: false,
  );

  static const json = CodeLanguage(
    id: 'json',
    label: 'JSON',
    literals: {'true', 'false', 'null'},
    lineComments: <String>[],
    typesByCase: false,
  );

  static const plain = CodeLanguage(
    id: 'text',
    label: 'Plain text',
    aliases: ['plain', 'plaintext', 'txt', 'none', 'output'],
    lineComments: <String>[],
    stringDelimiters: <String>{},
    typesByCase: false,
  );

  /// The languages this app is built around lead the picker; the rest follow
  /// in the order below.
  static const all = <CodeLanguage>[
    rust,
    java,
    c,
    cpp,
    python,
    javascript,
    dart,
    kotlin,
    go,
    sql,
    bash,
    json,
    plain,
  ];

  /// Resolves a fence info string (`rust`, `C++`, `py`) to a language.
  /// Returns null when nothing matches, so callers can decide whether to fall
  /// back to plain text or keep the unknown label.
  static CodeLanguage? lookup(String? name) {
    if (name == null) return null;
    final needle = name.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final language in all) {
      if (language.id == needle || language.aliases.contains(needle)) {
        return language;
      }
    }
    return null;
  }

  /// Display name for a fence info string, even one that is not supported —
  /// an unknown `haskell` block still says "haskell" in its header.
  static String labelFor(String? name) {
    final known = lookup(name);
    if (known != null) return known.label;
    final raw = name?.trim() ?? '';
    return raw.isEmpty ? plain.label : raw;
  }
}
