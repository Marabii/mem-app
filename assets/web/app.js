'use strict';

// MemApp companion UI. Talks to the shelf server running inside the Android
// app. No external requests — the phone may have no internet at all.

const TOPIC_COLORS = [
  0xFF6366F1, 0xFF0EA5E9, 0xFF10B981, 0xFFF59E0B, 0xFFEF4444,
  0xFFEC4899, 0xFF8B5CF6, 0xFF14B8A6, 0xFF64748B,
];

const state = {
  topics: [],
  cards: [],
  selectedTopicId: null,
  search: '',
  editingCardId: null,
  editingTopicId: null,
  pendingImport: null,
  pickedColor: TOPIC_COLORS[0],
};

const $ = (id) => document.getElementById(id);

/** ARGB int from the app -> #rrggbb for CSS. */
function argbToHex(value) {
  return '#' + (value & 0xFFFFFF).toString(16).padStart(6, '0');
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

let toastTimer = null;
function toast(message, isError = false) {
  const el = $('toast');
  el.textContent = message;
  el.classList.toggle('error', isError);
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, isError ? 6000 : 3000);
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  });
  const text = await res.text();
  let body = null;
  if (text) {
    try { body = JSON.parse(text); } catch (_) { body = null; }
  }
  if (!res.ok) {
    throw new Error((body && body.error) || `Request failed (${res.status})`);
  }
  return body;
}

// ---------------------------------------------------------------- loading

async function refresh({ quiet = false } = {}) {
  try {
    const [topicsRes, statsRes] = await Promise.all([
      api('/api/topics'),
      api('/api/stats'),
    ]);
    state.topics = topicsRes.topics || [];
    renderTopics();
    renderGlobalStats(statsRes);
    await loadCards();
  } catch (e) {
    if (!quiet) toast(e.message, true);
  }
}

async function loadCards() {
  const params = new URLSearchParams();
  if (state.selectedTopicId != null) params.set('topicId', state.selectedTopicId);
  if (state.search.trim()) params.set('q', state.search.trim());
  const res = await api('/api/cards?' + params.toString());
  state.cards = res.cards || [];
  renderCards();
  renderHeader();
}

// --------------------------------------------------------------- rendering

function renderGlobalStats(stats) {
  if (!stats) return;
  $('global-stats').textContent =
    `${stats.cards} cards · ${stats.due} due · ${stats.topics} topics`;
}

function renderTopics() {
  const list = $('topic-list');
  list.innerHTML = '';

  list.appendChild(topicButton({
    id: null,
    name: 'All cards',
    color: 0xFF64748B,
    due: state.topics.reduce((sum, t) => sum + (t.due || 0), 0),
    total: state.topics.reduce((sum, t) => sum + (t.total || 0), 0),
  }));

  for (const topic of state.topics) {
    list.appendChild(topicButton(topic));
  }

  if (state.topics.length === 0) {
    const hint = document.createElement('p');
    hint.className = 'muted tiny';
    hint.style.padding = '10px';
    hint.textContent = 'No topics yet. Create one to start adding cards.';
    list.appendChild(hint);
  }
}

function topicButton(topic) {
  const btn = document.createElement('button');
  btn.className = 'topic-item' + (state.selectedTopicId === topic.id ? ' active' : '');
  btn.type = 'button';

  const count = topic.due > 0
    ? `<span class="badge due">${topic.due}</span>`
    : `<span class="badge">${topic.total ?? 0}</span>`;

  btn.innerHTML = `
    <span class="dot" style="background:${argbToHex(topic.color)}"></span>
    <span class="name">${escapeHtml(topic.name)}</span>
    ${count}`;

  btn.addEventListener('click', () => {
    state.selectedTopicId = topic.id;
    renderTopics();
    loadCards().catch((e) => toast(e.message, true));
  });
  return btn;
}

function renderHeader() {
  const topic = state.topics.find((t) => t.id === state.selectedTopicId);
  $('topic-title').textContent = topic ? topic.name : 'All cards';
  $('edit-topic-btn').hidden = !topic;

  const shown = state.cards.length;
  const due = state.cards.filter((c) => c.isDue).length;
  const fresh = state.cards.filter((c) => c.isNew).length;
  const bits = [`${shown} ${shown === 1 ? 'card' : 'cards'}`];
  if (due) bits.push(`${due} due`);
  if (fresh) bits.push(`${fresh} new`);
  $('topic-subtitle').textContent =
    (topic && topic.description ? topic.description + ' · ' : '') + bits.join(' · ');
}

function renderCards() {
  const list = $('card-list');
  const empty = $('empty');
  list.innerHTML = '';

  if (state.cards.length === 0) {
    list.hidden = true;
    empty.hidden = false;
    empty.innerHTML = state.search.trim()
      ? `<h3>No matches</h3><p>Nothing matched “${escapeHtml(state.search)}”.</p>`
      : `<h3>No cards here yet</h3><p>Use <strong>New card</strong> to add your first one.</p>`;
    return;
  }

  list.hidden = false;
  empty.hidden = true;

  for (const card of state.cards) {
    const el = document.createElement('article');
    el.className = 'card';

    const pills = [];
    if (card.suspended) pills.push('<span class="pill suspended">Suspended</span>');
    else if (card.isNew) pills.push('<span class="pill new">New</span>');
    else if (card.isDue) pills.push('<span class="pill due">Due</span>');
    for (const tag of card.tags || []) {
      pills.push(`<span class="pill">${escapeHtml(tag)}</span>`);
    }

    el.innerHTML = `
      <div class="front">${Syntax.renderCardText(card.front)}</div>
      <div class="back">${Syntax.renderCardText(card.back)}</div>
      <div class="card-meta">${pills.join('')}</div>`;

    el.addEventListener('click', () => openCardDialog(card));
    list.appendChild(el);
  }
}

// ------------------------------------------------------- editor toolbars

const CODE_LANGUAGE_KEY = 'memapp.codeLanguage';
// Used until /api/languages answers, and if it never does.
const FALLBACK_LANGUAGES = [
  { id: 'rust', label: 'Rust' }, { id: 'java', label: 'Java' },
  { id: 'c', label: 'C' }, { id: 'cpp', label: 'C++' },
];

function preferredLanguage() {
  return localStorage.getItem(CODE_LANGUAGE_KEY) || 'rust';
}

/** Fills the toolbar next to each textarea. Called once the languages load. */
function buildFormatBars() {
  const languages = Syntax.languages().length
    ? Syntax.languages()
    : FALLBACK_LANGUAGES;

  for (const bar of document.querySelectorAll('.format-bar')) {
    const field = () => $(bar.dataset.field);
    bar.innerHTML = '';

    const button = (html, title, onClick, className = 'fmt') => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = className;
      b.title = title;
      b.innerHTML = html;
      b.addEventListener('click', onClick);
      bar.appendChild(b);
      return b;
    };

    button('<strong>B</strong>', 'Bold', () => wrapInline(field(), '**'));
    button('<em>I</em>', 'Italic', () => wrapInline(field(), '*'));
    button('&lt;/&gt;', 'Inline code', () => wrapInline(field(), '`'));

    const select = document.createElement('select');
    select.className = 'lang-select';
    select.setAttribute('aria-label', 'Code block language');
    select.innerHTML = languages
      .map((l) => `<option value="${l.id}">${escapeHtml(l.label)}</option>`)
      .join('');
    select.value = preferredLanguage();
    select.addEventListener('change', () => {
      localStorage.setItem(CODE_LANGUAGE_KEY, select.value);
      // Keep every bar in the dialog on the same language.
      for (const other of document.querySelectorAll('.lang-select')) {
        other.value = select.value;
      }
    });
    bar.appendChild(select);

    button('Code block', 'Insert a fenced code block',
      () => insertCodeBlock(field(), select.value), 'fmt code');
  }
}

/**
 * Wraps the selection in a fenced block, or drops in an empty one with the
 * caret inside. Mirrors MarkdownActions on the Dart side, including the blank
 * lines a fence needs to start a block.
 */
function insertCodeBlock(el, language) {
  if (!el) return;
  const value = el.value;
  const start = el.selectionStart ?? value.length;
  const end = el.selectionEnd ?? start;
  const before = value.slice(0, start);
  const after = value.slice(end);
  const body = value.slice(start, end).trim();

  const lead = before.length === 0 || before.endsWith('\n\n') ? ''
    : before.endsWith('\n') ? '\n' : '\n\n';
  const trail = after.length === 0 ? '\n' : after.startsWith('\n') ? '' : '\n\n';
  const open = '```' + language + '\n';

  el.value = `${before}${lead}${open}${body}\n\`\`\`${trail}${after}`;
  const cursor = before.length + lead.length + open.length + body.length;
  el.focus();
  el.setSelectionRange(cursor, cursor);
  el.dispatchEvent(new Event('input'));
}

/** `**bold**`, `*italic*`, `` `code` `` — wraps, or unwraps when already applied. */
function wrapInline(el, marker) {
  if (!el) return;
  const value = el.value;
  const start = el.selectionStart ?? value.length;
  const end = el.selectionEnd ?? start;
  const before = value.slice(0, start);
  const after = value.slice(end);
  const body = value.slice(start, end);

  let text;
  let from;
  if (before.endsWith(marker) && after.startsWith(marker)) {
    text = before.slice(0, -marker.length) + body + after.slice(marker.length);
    from = before.length - marker.length;
  } else {
    text = before + marker + body + marker + after;
    from = before.length + marker.length;
  }

  el.value = text;
  el.focus();
  el.setSelectionRange(from, from + body.length);
  el.dispatchEvent(new Event('input'));
}

function toggleCardPreview() {
  const panel = $('card-preview');
  const show = panel.hidden;
  panel.hidden = !show;
  $('card-preview-toggle').textContent = show ? 'Hide preview' : 'Preview';
  renderCardPreview();
}

function renderCardPreview() {
  const panel = $('card-preview');
  if (panel.hidden) return;
  panel.innerHTML =
    Syntax.renderCardText($('card-front').value) +
    '<hr class="preview-divider">' +
    Syntax.renderCardText($('card-back').value);
}

// ----------------------------------------------------------- card dialog

function openCardDialog(card) {
  if (state.topics.length === 0) {
    toast('Create a topic first', true);
    return;
  }
  state.editingCardId = card ? card.id : null;
  $('card-dialog-title').textContent = card ? 'Edit card' : 'New card';
  $('card-delete').hidden = !card;

  const select = $('card-topic');
  select.innerHTML = state.topics
    .map((t) => `<option value="${t.id}">${escapeHtml(t.name)}</option>`)
    .join('');
  select.value = String(
    (card && card.topicId) || state.selectedTopicId || state.topics[0].id);

  $('card-front').value = card ? card.front : '';
  $('card-back').value = card ? card.back : '';
  $('card-tags').value = card ? (card.tags || []).join(', ') : '';

  $('card-preview').hidden = true;
  $('card-preview-toggle').textContent = 'Preview';

  $('card-dialog').showModal();
  setTimeout(() => $('card-front').focus(), 30);
}

async function saveCard(event) {
  event.preventDefault();
  const payload = {
    topicId: Number($('card-topic').value),
    front: $('card-front').value.trim(),
    back: $('card-back').value.trim(),
    tags: $('card-tags').value.split(',').map((t) => t.trim()).filter(Boolean),
  };
  if (!payload.front) {
    toast('The front of the card cannot be empty', true);
    return;
  }

  try {
    if (state.editingCardId == null) {
      await api('/api/cards', { method: 'POST', body: JSON.stringify(payload) });
      toast('Card added');
    } else {
      await api(`/api/cards/${state.editingCardId}`,
        { method: 'PUT', body: JSON.stringify(payload) });
      toast('Card saved');
    }
    $('card-dialog').close();
    await refresh();
  } catch (e) {
    toast(e.message, true);
  }
}

async function deleteCard() {
  if (state.editingCardId == null) return;
  if (!confirm('Delete this card? Its review history goes with it.')) return;
  try {
    await api(`/api/cards/${state.editingCardId}`, { method: 'DELETE' });
    $('card-dialog').close();
    toast('Card deleted');
    await refresh();
  } catch (e) {
    toast(e.message, true);
  }
}

// ---------------------------------------------------------- topic dialog

function openTopicDialog(topic) {
  state.editingTopicId = topic ? topic.id : null;
  state.pickedColor = topic ? topic.color : TOPIC_COLORS[0];
  $('topic-dialog-title').textContent = topic ? 'Edit topic' : 'New topic';
  $('topic-delete').hidden = !topic;
  $('topic-name').value = topic ? topic.name : '';
  $('topic-desc').value = topic ? (topic.description || '') : '';
  renderColorRow();
  $('topic-dialog').showModal();
  setTimeout(() => $('topic-name').focus(), 30);
}

function renderColorRow() {
  const row = $('topic-colors');
  row.innerHTML = '';
  for (const color of TOPIC_COLORS) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'swatch' + (color === state.pickedColor ? ' selected' : '');
    b.style.background = argbToHex(color);
    b.setAttribute('aria-label', 'Colour ' + argbToHex(color));
    b.addEventListener('click', () => {
      state.pickedColor = color;
      renderColorRow();
    });
    row.appendChild(b);
  }
}

async function saveTopic(event) {
  event.preventDefault();
  const payload = {
    name: $('topic-name').value.trim(),
    description: $('topic-desc').value.trim(),
    color: state.pickedColor,
  };
  if (!payload.name) {
    toast('A topic needs a name', true);
    return;
  }
  try {
    if (state.editingTopicId == null) {
      await api('/api/topics', { method: 'POST', body: JSON.stringify(payload) });
      toast('Topic created');
    } else {
      await api(`/api/topics/${state.editingTopicId}`,
        { method: 'PUT', body: JSON.stringify(payload) });
      toast('Topic saved');
    }
    $('topic-dialog').close();
    await refresh();
  } catch (e) {
    toast(e.message, true);
  }
}

async function deleteTopic() {
  if (state.editingTopicId == null) return;
  const topic = state.topics.find((t) => t.id === state.editingTopicId);
  const count = topic ? topic.total : 0;
  if (!confirm(`Delete “${topic ? topic.name : 'this topic'}” and its ${count} card(s)? This cannot be undone.`)) return;
  try {
    await api(`/api/topics/${state.editingTopicId}`, { method: 'DELETE' });
    $('topic-dialog').close();
    if (state.selectedTopicId === state.editingTopicId) state.selectedTopicId = null;
    toast('Topic deleted');
    await refresh();
  } catch (e) {
    toast(e.message, true);
  }
}

// --------------------------------------------------------------- import

function onImportFileChosen(event) {
  const file = event.target.files && event.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    state.pendingImport = String(reader.result || '');
    $('import-summary').textContent = `${file.name} — ${(file.size / 1024).toFixed(1)} KB`;
    $('import-dialog').showModal();
  };
  reader.onerror = () => toast('Could not read that file', true);
  reader.readAsText(file);
  event.target.value = '';
}

async function runImport(event) {
  event.preventDefault();
  if (!state.pendingImport) return;
  const mode = document.querySelector('input[name="import-mode"]:checked').value;
  if (mode === 'replace' &&
      !confirm('Replace deletes every topic and card on the device first. Continue?')) {
    return;
  }
  try {
    const res = await api(`/api/import?mode=${mode}`, {
      method: 'POST',
      body: state.pendingImport,
    });
    $('import-dialog').close();
    state.pendingImport = null;
    toast(res.message || 'Imported');
    await refresh();
  } catch (e) {
    toast(e.message, true);
  }
}

// ----------------------------------------------------------------- wiring

function init() {
  $('new-card-btn').addEventListener('click', () => openCardDialog(null));
  $('card-form').addEventListener('submit', saveCard);
  $('card-delete').addEventListener('click', deleteCard);

  $('card-preview-toggle').addEventListener('click', toggleCardPreview);
  for (const id of ['card-front', 'card-back']) {
    $(id).addEventListener('input', renderCardPreview);
  }

  $('new-topic-btn').addEventListener('click', () => openTopicDialog(null));
  $('edit-topic-btn').addEventListener('click', () => {
    const topic = state.topics.find((t) => t.id === state.selectedTopicId);
    if (topic) openTopicDialog(topic);
  });
  $('topic-form').addEventListener('submit', saveTopic);
  $('topic-delete').addEventListener('click', deleteTopic);

  $('import-btn').addEventListener('click', () => $('import-input').click());
  $('import-input').addEventListener('change', onImportFileChosen);
  $('import-form').addEventListener('submit', runImport);

  for (const btn of document.querySelectorAll('[data-close]')) {
    btn.addEventListener('click', () => btn.closest('dialog').close());
  }

  let searchTimer = null;
  $('search').addEventListener('input', (e) => {
    state.search = e.target.value;
    clearTimeout(searchTimer);
    searchTimer = setTimeout(
      () => loadCards().catch((err) => toast(err.message, true)), 200);
  });

  // Ctrl/Cmd+K focuses search, "n" opens a new card.
  document.addEventListener('keydown', (e) => {
    const typing = ['INPUT', 'TEXTAREA', 'SELECT'].includes(e.target.tagName);
    if ((e.ctrlKey || e.metaKey) && e.key === 'k') {
      e.preventDefault();
      $('search').focus();
    } else if (e.key === 'n' && !typing && !document.querySelector('dialog[open]')) {
      e.preventDefault();
      openCardDialog(null);
    }
  });

  // Keeps the browser in step with edits made on the phone. Quiet failures:
  // a poll that fails while the phone screen is off should not spam toasts.
  setInterval(() => {
    if (!document.hidden && !document.querySelector('dialog[open]')) {
      refresh({ quiet: true });
    }
  }, 8000);

  // The toolbars need the language table; the card list needs it to colour
  // fenced blocks. Both degrade to plain text if the request fails.
  buildFormatBars();
  Syntax.load().then(() => {
    buildFormatBars();
    renderCards();
  });

  refresh();
}

document.addEventListener('DOMContentLoaded', init);
