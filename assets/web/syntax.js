'use strict';

// Code-block colouring for the companion UI.
//
// The language table is not duplicated here: it is fetched from
// `GET /api/languages`, which serialises the same const definitions the app
// uses on the phone, so a keyword added in Dart shows up in the browser too.
// Only the scanning rules live in this file, and they are a deliberately
// simpler regular-expression pass than the Dart scanner — good enough for a
// preview, without the nested-comment and lifetime bookkeeping.

const Syntax = (() => {
  /** @type {Map<string, object>} id/alias -> spec */
  const byName = new Map();
  /** @type {object[]} in the order the app lists them */
  let ordered = [];
  const compiled = new Map();

  async function load() {
    try {
      const res = await fetch('/api/languages');
      const body = await res.json();
      ordered = body.languages || [];
      byName.clear();
      compiled.clear();
      for (const spec of ordered) {
        byName.set(spec.id, spec);
        for (const alias of spec.aliases || []) byName.set(alias, spec);
      }
    } catch (_) {
      // Highlighting is a nicety; without the table everything renders plain.
      ordered = [];
    }
    return ordered;
  }

  const languages = () => ordered;

  function escapeHtml(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  /** Builds the one big alternation used to walk a source string. */
  function compile(spec) {
    if (compiled.has(spec.id)) return compiled.get(spec.id);
    const parts = [];

    // Group names have to be unique inside one pattern, hence the indices.
    (spec.lineComments || []).forEach((marker, i) => {
      parts.push(`(?<cmt${i}>${escapeRe(marker)}[^\\n]*)`);
    });
    if (spec.blockComment) {
      const [open, close] = spec.blockComment;
      parts.push(`(?<cmtb>${escapeRe(open)}[\\s\\S]*?(?:${escapeRe(close)}|$))`);
    }
    if (spec.rawStrings) {
      parts.push('(?<rawstr>\\bb?r#*"[\\s\\S]*?"#*|\\bR"[^(]*\\([\\s\\S]*?\\)[^"]*")');
    }
    if (spec.tripleQuotes) {
      parts.push('(?<triple>"""[\\s\\S]*?(?:"""|$)|\'\'\'[\\s\\S]*?(?:\'\'\'|$))');
    }
    for (const quote of spec.stringDelimiters || []) {
      const q = escapeRe(quote);
      const body = quote === '`' ? '[^`\\\\]' : `[^${q}\\\\\\n]`;
      parts.push(`(?<str${quote.charCodeAt(0)}>${q}(?:\\\\.|${body})*${q}?)`);
    }
    if (spec.charLiterals) {
      parts.push("(?<char>'(?:\\\\.[0-9a-fA-F]*|[^'\\\\\\n])')");
    }
    if (spec.lifetimes) parts.push("(?<life>'[A-Za-z_]\\w*)");
    if (spec.attributes) parts.push('(?<attr>#!?\\[[^\\]\\n]*\\])');
    if (spec.preprocessor) parts.push('(?<pre>^[ \\t]*#[ \\t]*\\w+)');
    if (spec.annotations) parts.push('(?<anno>@[A-Za-z_][\\w.]*)');
    if (spec.dollarVariables) parts.push('(?<dollar>\\$\\{[^}\\n]*\\}|\\$\\w+)');
    parts.push('(?<num>\\b\\d[\\w.]*\\b)');
    parts.push('(?<word>[A-Za-z_$][\\w$]*)');

    const re = new RegExp(parts.join('|'), 'gm');
    const sets = {
      keywords: new Set(spec.keywords || []),
      types: new Set(spec.types || []),
      literals: new Set(spec.literals || []),
    };
    const entry = { re, sets, spec };
    compiled.set(spec.id, entry);
    return entry;
  }

  function classifyWord(word, after, entry) {
    const { spec, sets } = entry;
    const needle = spec.caseInsensitiveKeywords ? word.toLowerCase() : word;
    if (sets.keywords.has(needle)) return 'kw';
    if (sets.literals.has(needle)) return 'lit';
    if (sets.types.has(needle)) return 'typ';
    if (spec.macroBang && after.startsWith('!') && !after.startsWith('!=')) return 'fn';
    if (/^[ \t]*\(/.test(after)) return 'fn';
    if (spec.typesByCase && /^[A-Z]/.test(word)) return 'typ';
    return null;
  }

  const CLASS_OF = {
    rawstr: 'str', triple: 'str', char: 'str',
    life: 'meta', attr: 'meta', pre: 'meta', anno: 'meta', dollar: 'meta',
    num: 'num',
  };

  /** Source -> HTML with `tok-*` spans. Unknown languages come back escaped. */
  function highlight(code, languageName) {
    const spec = byName.get(String(languageName || '').toLowerCase());
    if (!spec || spec.id === 'text') return escapeHtml(code);

    const entry = compile(spec);
    const { re } = entry;
    re.lastIndex = 0;

    let out = '';
    let last = 0;
    let match;
    while ((match = re.exec(code)) !== null) {
      const groups = match.groups || {};
      let cls = null;
      for (const [name, value] of Object.entries(groups)) {
        if (value === undefined) continue;
        if (name === 'word') {
          // A short lookahead is all the `(` and `!` rules need.
          cls = classifyWord(value, code.slice(re.lastIndex, re.lastIndex + 8), entry);
          // `println!` and friends keep their bang.
          if (cls === 'fn' && spec.macroBang && code[re.lastIndex] === '!' &&
              code[re.lastIndex + 1] !== '=') {
            re.lastIndex += 1;
          }
        } else if (name.startsWith('str')) {
          cls = 'str';
        } else if (name.startsWith('cmt')) {
          cls = 'cmt';
        } else {
          cls = CLASS_OF[name] || null;
        }
        break;
      }

      const text = code.slice(match.index, re.lastIndex);
      out += escapeHtml(code.slice(last, match.index));
      out += cls ? `<span class="tok-${cls}">${escapeHtml(text)}</span>` : escapeHtml(text);
      last = re.lastIndex;
      // A zero-width match would spin forever.
      if (re.lastIndex === match.index) re.lastIndex++;
    }
    return out + escapeHtml(code.slice(last));
  }

  /**
   * Renders card text: fenced blocks become highlighted <pre> blocks, inline
   * `spans` become <code>, everything else stays plain escaped text. This is
   * not a full markdown renderer — the phone does that — it is enough to read
   * a card at a glance.
   */
  function renderCardText(text) {
    const source = String(text ?? '');
    const fence = /```([^\n`]*)\n?([\s\S]*?)(?:```|$)/g;
    let out = '';
    let last = 0;
    let match;
    while ((match = fence.exec(source)) !== null) {
      out += inline(source.slice(last, match.index));
      const language = (match[1] || '').trim();
      const label = labelFor(language);
      out +=
        `<pre class="code-block" data-lang="${escapeHtml(label)}">` +
        `<code>${highlight(match[2].replace(/\n$/, ''), language)}</code></pre>`;
      last = fence.lastIndex;
    }
    return out + inline(source.slice(last));
  }

  function labelFor(name) {
    const spec = byName.get(String(name || '').toLowerCase());
    if (spec) return spec.label;
    return name ? name : 'Code';
  }

  function inline(text) {
    return escapeHtml(text)
      .replace(/`([^`\n]+)`/g, '<code class="inline-code">$1</code>')
      .replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  }

  return { load, languages, highlight, renderCardText, labelFor, escapeHtml };
})();
