/* Folio — markdown render pipeline.
   Swift calls window.folio.*; this file posts back through the `folio`
   message handler. Everything here runs offline against vendored libraries. */
'use strict';

const state = {
  markdown: '',
  docDir: '/',
  ext: 'md',
  theme: 'light',
  renderSeq: 0,
  /// The in-flight settle() for the current render, so an export can await it.
  settled: Promise.resolve(),
  /// Diagram sources for the current render, addressed by index from the DOM.
  mermaidSources: [],
};

const content = document.getElementById('content');

function post(message) {
  try {
    window.webkit.messageHandlers.folio.postMessage(message);
  } catch (_) {
    /* Running outside the app shell. */
  }
}

// ── Escaping ─────────────────────────────────────────────────────────────

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}
const escapeAttr = escapeHtml;

// ── Paths ────────────────────────────────────────────────────────────────

function isAbsoluteURL(s) {
  return /^[a-z][a-z0-9+.\-]*:/i.test(s) || s.startsWith('//');
}

/** Normalises `rel` against `base`, collapsing `.` and `..`. */
function resolvePath(base, rel) {
  const joined = rel.startsWith('/') ? rel : base.replace(/\/+$/, '') + '/' + rel;
  const parts = [];
  for (const segment of joined.split('/')) {
    if (segment === '' || segment === '.') continue;
    if (segment === '..') { parts.pop(); continue; }
    parts.push(segment);
  }
  return '/' + parts.join('/');
}

/** Maps a document-relative reference onto the custom scheme Swift serves. */
function docURL(reference) {
  const bare = reference.split('#')[0].split('?')[0];
  if (!bare) return null;
  let decoded;
  try { decoded = decodeURIComponent(bare); } catch (_) { decoded = bare; }
  return 'folio://doc/?p=' + encodeURIComponent(resolvePath(state.docDir, decoded));
}

// ── Slugs ────────────────────────────────────────────────────────────────

function slugify(text) {
  const base = String(text)
    .toLowerCase()
    .replace(/[‘’“”]/g, '')
    .replace(/[^\p{Letter}\p{Number}\s-]/gu, '')
    .trim()
    .replace(/\s+/g, '-');
  return base || 'section';
}

// ── Math ─────────────────────────────────────────────────────────────────

function renderMath(tex, displayMode) {
  try {
    return katex.renderToString(tex, {
      displayMode,
      throwOnError: false,
      strict: false,
      output: 'html',
      trust: false,
    });
  } catch (error) {
    return '<span class="math-error">' + escapeHtml(String(error.message || error)) + '</span>';
  }
}

// ── Fenced code ──────────────────────────────────────────────────────────

function renderCode(text, lang) {
  const language = String(lang || '').trim().split(/\s+/)[0].toLowerCase();

  if (language === 'mermaid') {
    // The source is kept out of the DOM deliberately. DOMPurify drops any
    // attribute whose value contains `-->` (it guards against smuggling a
    // comment terminator through markup), and `-->` is the ordinary mermaid
    // arrow — so passing the diagram through an attribute silently emptied
    // every flowchart. An index survives sanitising untouched.
    const index = state.mermaidSources.push(text) - 1;
    return '<div class="mermaid-wrap" data-mermaid-index="' + index + '"></div>';
  }

  let highlighted;
  let label = language;
  if (language && hljs.getLanguage(language)) {
    highlighted = hljs.highlight(text, { language, ignoreIllegals: true }).value;
  } else if (!language && text.length > 24) {
    const auto = hljs.highlightAuto(text);
    highlighted = auto.value;
    label = auto.language || 'text';
  } else {
    highlighted = escapeHtml(text);
    label = language || 'text';
  }

  const lineCount = text.replace(/\n+$/, '').split('\n').length;
  let gutter = '';
  for (let i = 1; i <= lineCount; i++) gutter += (i > 1 ? '\n' : '') + i;

  return '<div class="codeblock" data-lang="' + escapeAttr(label) + '">'
    + '<div class="cb-head"><span class="cb-lang">' + escapeHtml(label) + '</span>'
    + '<button class="cb-copy" type="button">Copy</button></div>'
    + '<pre><span class="gutter" aria-hidden="true">' + gutter + '</span>'
    + '<code class="hljs language-' + escapeAttr(label) + '">' + highlighted + '</code></pre>'
    + '</div>';
}

// ── marked extensions ────────────────────────────────────────────────────

const wikiLinkExtension = {
  name: 'wikiLink',
  level: 'inline',
  start(src) {
    const embed = src.indexOf('![[');
    if (embed >= 0) return embed;
    const plain = src.indexOf('[[');
    return plain < 0 ? undefined : plain;
  },
  tokenizer(src) {
    const match = /^(!?)\[\[([^\]|#]+?)(?:#([^\]|]+?))?(?:\|([^\]]+?))?\]\]/.exec(src);
    if (!match) return undefined;
    return {
      type: 'wikiLink',
      raw: match[0],
      embed: match[1] === '!',
      target: match[2].trim(),
      hash: (match[3] || '').trim(),
      alias: (match[4] || '').trim(),
    };
  },
  renderer(token) {
    if (token.embed) {
      return '<img src="' + escapeAttr(token.target) + '" alt="'
        + escapeAttr(token.alias || token.target) + '">';
    }
    const href = 'wiki:' + encodeURIComponent(token.target)
      + (token.hash ? '#' + encodeURIComponent(token.hash) : '');
    const label = token.alias || token.target + (token.hash ? ' › ' + token.hash : '');
    return '<a class="wiki" href="' + escapeAttr(href) + '">' + escapeHtml(label) + '</a>';
  },
};

const markExtension = {
  name: 'markHighlight',
  level: 'inline',
  start(src) { const i = src.indexOf('=='); return i < 0 ? undefined : i; },
  tokenizer(src) {
    const match = /^==(?=[^\s=])([\s\S]*?[^\s=])==/.exec(src);
    if (!match) return undefined;
    return {
      type: 'markHighlight',
      raw: match[0],
      tokens: this.lexer.inlineTokens(match[1]),
    };
  },
  renderer(token) { return '<mark>' + this.parser.parseInline(token.tokens) + '</mark>'; },
};

const mathBlockExtension = {
  name: 'mathBlock',
  level: 'block',
  start(src) { const i = src.indexOf('$$'); return i < 0 ? undefined : i; },
  tokenizer(src) {
    const match = /^ {0,3}\$\$([\s\S]+?)\$\$[ \t]*(?:\n+|$)/.exec(src);
    if (!match) return undefined;
    return { type: 'mathBlock', raw: match[0], text: match[1].trim() };
  },
  renderer(token) { return renderMath(token.text, true); },
};

const mathInlineExtension = {
  name: 'mathInline',
  level: 'inline',
  start(src) { const i = src.indexOf('$'); return i < 0 ? undefined : i; },
  tokenizer(src) {
    const match = /^\$(?!\$)((?:\\[\s\S]|[^\\$])+?)\$(?!\d)/.exec(src);
    if (!match) return undefined;
    // "$ x $" and "$5 to $6" are prose, not math.
    if (/^\s|\s$/.test(match[1])) return undefined;
    return { type: 'mathInline', raw: match[0], text: match[1] };
  },
  renderer(token) { return renderMath(token.text, false); },
};

marked.use({
  gfm: true,
  breaks: false,
  pedantic: false,
  extensions: [wikiLinkExtension, markExtension, mathBlockExtension, mathInlineExtension],
  renderer: {
    // marked >= 13 passes a token; older versions pass positional arguments.
    code(tokenOrCode, infostring) {
      if (tokenOrCode && typeof tokenOrCode === 'object') {
        return renderCode(tokenOrCode.text, tokenOrCode.lang);
      }
      return renderCode(tokenOrCode, infostring);
    },
  },
});

// ── Frontmatter ──────────────────────────────────────────────────────────

function parseFrontmatter(source) {
  const match = /^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(source);
  if (!match) return { meta: null, body: source };

  const meta = [];
  let pending = null;
  for (const rawLine of match[1].split(/\r?\n/)) {
    const listItem = /^\s*-\s+(.*)$/.exec(rawLine);
    if (listItem && pending) {
      pending.values.push(listItem[1].trim().replace(/^["']|["']$/g, ''));
      continue;
    }
    const pair = /^([A-Za-z0-9_.\- ]+):[ \t]*(.*)$/.exec(rawLine);
    if (!pair) continue;
    const key = pair[1].trim();
    const value = pair[2].trim();
    if (!value) {
      pending = { key, values: [] };
      meta.push(pending);
    } else {
      const inline = /^\[(.*)\]$/.exec(value);
      const values = inline
        ? inline[1].split(',').map((v) => v.trim().replace(/^["']|["']$/g, '')).filter(Boolean)
        : [value.replace(/^["']|["']$/g, '')];
      meta.push({ key, values });
      pending = null;
    }
  }
  return { meta: meta.filter((entry) => entry.values.length), body: source.slice(match[0].length) };
}

function frontmatterHTML(meta) {
  if (!meta || !meta.length) return '';
  const rows = meta.map((entry) => {
    const isTagLike = /^(tags?|keywords?|categor(y|ies)|aliases)$/i.test(entry.key);
    const value = isTagLike
      ? entry.values.map((v) => '<span class="tag">' + escapeHtml(v) + '</span>').join('')
      : escapeHtml(entry.values.join(', '));
    return '<dt>' + escapeHtml(entry.key) + '</dt><dd>' + value + '</dd>';
  }).join('');
  return '<div class="frontmatter"><dl>' + rows + '</dl></div>';
}

// ── Non-markdown text kinds ──────────────────────────────────────────────

function parseCSVRows(text) {
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else { quoted = false; }
      } else { field += ch; }
      continue;
    }
    if (ch === '"') { quoted = true; }
    else if (ch === ',') { row.push(field); field = ''; }
    else if (ch === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else if (ch !== '\r') { field += ch; }
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.some((cell) => cell.trim() !== ''));
}

function csvHTML(text) {
  const rows = parseCSVRows(text);
  if (!rows.length) return '<p><em>Empty file.</em></p>';
  const [header, ...body] = rows;
  const head = header.map((cell) => '<th>' + escapeHtml(cell) + '</th>').join('');
  const rest = body.map((r) =>
    '<tr>' + r.map((cell) => '<td>' + escapeHtml(cell) + '</td>').join('') + '</tr>'
  ).join('');
  return '<div class="table-scroll"><table><thead><tr>' + head + '</tr></thead>'
    + '<tbody>' + rest + '</tbody></table></div>'
    + '<p><em>' + body.length + ' rows · ' + header.length + ' columns</em></p>';
}

// ── Render ───────────────────────────────────────────────────────────────

/** Remembers roughly where the reader was, so live reload does not jump. */
function captureScroll() {
  const headings = [...content.querySelectorAll('h1,h2,h3,h4,h5,h6')];
  const anchor = headings.reverse().find((h) => h.getBoundingClientRect().top <= 12);
  const height = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
  return {
    id: anchor ? anchor.id : null,
    offset: anchor ? anchor.getBoundingClientRect().top : 0,
    ratio: window.scrollY / height,
  };
}

function restoreScroll(mark) {
  if (!mark) return;
  if (mark.id) {
    const target = document.getElementById(mark.id);
    if (target) {
      window.scrollTo({ top: window.scrollY + target.getBoundingClientRect().top - mark.offset });
      return;
    }
  }
  const height = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
  window.scrollTo({ top: mark.ratio * height });
}

function render(preserveScroll) {
  const mark = preserveScroll ? captureScroll() : null;
  state.renderSeq += 1;
  state.mermaidSources = [];

  let html;
  if (state.ext === 'csv') {
    html = csvHTML(state.markdown);
  } else if (state.ext === 'log') {
    html = renderCode(state.markdown, 'accesslog');
  } else {
    const { meta, body } = parseFrontmatter(state.markdown);
    html = frontmatterHTML(meta) + marked.parse(body);
  }

  content.innerHTML = DOMPurify.sanitize(html, {
    USE_PROFILES: { html: true, svg: true, svgFilters: true, mathMl: true },
    // data-mermaid-index links a placeholder back to its diagram source.
    ADD_ATTR: ['id', 'class', 'style', 'target', 'align', 'disabled', 'checked',
               'colspan', 'rowspan', 'start', 'type', 'aria-hidden', 'data-mermaid-index'],
  });

  decorateHeadings();
  decorateTables();
  decorateCallouts();
  decorateTaskLists();
  rewriteReferences();
  observeHeadings();

  // Export needs to know when the page has stopped moving. Diagrams, webfonts
  // and images all land after this function returns, so the signal is posted
  // from settle() rather than here.
  const sequence = state.renderSeq;
  state.settled = settle(renderMermaid()).then(() => {
    if (sequence === state.renderSeq) post({ type: 'rendered', seq: sequence });
  });

  if (preserveScroll) restoreScroll(mark);
  else window.scrollTo({ top: 0 });
}

/// Resolves once diagrams, fonts and images have settled, so an export
/// captures the finished page instead of a half-painted one.
async function settle(diagrams) {
  await diagrams;
  try {
    await document.fonts.ready;
  } catch (_) {
    /* Older WebKit: fonts are already blocking, so nothing to wait for. */
  }
  await Promise.all([...document.images].map((image) => (
    image.complete ? null : new Promise((done) => {
      image.addEventListener('load', done, { once: true });
      image.addEventListener('error', done, { once: true });
    })
  )));
}

function decorateHeadings() {
  const used = new Map();
  const items = [];
  for (const heading of content.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
    let slug = heading.id || slugify(heading.textContent);
    const seen = used.get(slug) || 0;
    used.set(slug, seen + 1);
    if (seen) slug = slug + '-' + seen;
    heading.id = slug;

    const anchor = document.createElement('a');
    anchor.className = 'anchor';
    anchor.href = '#' + slug;
    anchor.textContent = '#';
    anchor.setAttribute('aria-hidden', 'true');
    heading.insertBefore(anchor, heading.firstChild);

    items.push({
      id: slug,
      title: heading.textContent.replace(/^#/, '').trim(),
      level: Number(heading.tagName.slice(1)),
    });
  }
  post({ type: 'outline', items });
}

function decorateTables() {
  for (const table of content.querySelectorAll('table')) {
    if (table.parentElement && table.parentElement.classList.contains('table-scroll')) continue;
    const wrapper = document.createElement('div');
    wrapper.className = 'table-scroll';
    table.parentElement.insertBefore(wrapper, table);
    wrapper.appendChild(table);
  }
}

const CALLOUT_ICONS = {
  note: 'ℹ', tip: '✓', important: '★', warning: '⚠', caution: '⛔',
  info: 'ℹ', hint: '✓', danger: '⛔', error: '⛔', success: '✓',
  question: '?', abstract: '≡', example: '⌘', quote: '❝', todo: '☐', bug: '✖',
};
const CALLOUT_KINDS = {
  info: 'note', hint: 'tip', success: 'tip', danger: 'caution', error: 'caution',
  bug: 'caution', question: 'important', abstract: 'note', example: 'note',
  quote: 'note', todo: 'note',
};

function decorateCallouts() {
  for (const quote of content.querySelectorAll('blockquote')) {
    const first = quote.firstElementChild;
    if (!first || first.tagName !== 'P') continue;
    const match = /^\[!([A-Za-z]+)\]([+-]?)[ \t]*(.*)$/.exec(first.textContent.trim());
    if (!match) continue;

    const raw = match[1].toLowerCase();
    const kind = CALLOUT_KINDS[raw] || raw;
    const heading = match[3].trim() || raw.charAt(0).toUpperCase() + raw.slice(1);

    // Drop the marker line, keeping any text that followed it on the same line.
    const rest = first.innerHTML.replace(/^\s*\[!([A-Za-z]+)\][+-]?[ \t]*/, '');
    if (rest.trim()) first.innerHTML = rest; else first.remove();

    const callout = document.createElement('div');
    callout.className = 'callout';
    callout.dataset.kind = kind;
    const title = document.createElement('div');
    title.className = 'callout-title';
    title.textContent = (CALLOUT_ICONS[raw] || 'ℹ') + ' ' + heading;
    callout.appendChild(title);
    while (quote.firstChild) callout.appendChild(quote.firstChild);
    quote.replaceWith(callout);
  }
}

function decorateTaskLists() {
  for (const item of content.querySelectorAll('li')) {
    const box = item.querySelector(':scope > input[type="checkbox"]');
    if (!box) continue;
    item.classList.add('task-list-item');
    if (box.checked) item.classList.add('done');
  }
}

function rewriteReferences() {
  for (const image of content.querySelectorAll('img[src]')) {
    const source = image.getAttribute('src');
    if (isAbsoluteURL(source)) continue;
    const mapped = docURL(source);
    if (!mapped) continue;
    image.addEventListener('error', () => image.classList.add('missing'), { once: true });
    image.setAttribute('src', mapped);
  }
  for (const link of content.querySelectorAll('a[href]')) {
    const href = link.getAttribute('href');
    if (href.startsWith('#') || href.startsWith('wiki:')) continue;
    if (isAbsoluteURL(href)) link.setAttribute('target', '_blank');
  }
}

let headingObserver = null;
function observeHeadings() {
  if (headingObserver) headingObserver.disconnect();
  const visible = new Set();
  headingObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) visible.add(entry.target.id);
      else visible.delete(entry.target.id);
    }
    const order = [...content.querySelectorAll('h1,h2,h3,h4,h5,h6')].map((h) => h.id);
    const active = order.find((id) => visible.has(id));
    if (active) post({ type: 'active', id: active });
  }, { rootMargin: '0px 0px -75% 0px' });

  for (const heading of content.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
    headingObserver.observe(heading);
  }
}

// ── Mermaid (loaded on demand: it is by far the largest dependency) ──────

let mermaidLoader = null;
function ensureMermaid() {
  if (mermaidLoader) return mermaidLoader;
  mermaidLoader = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'vendor/mermaid.min.js';
    script.onload = () => resolve(window.mermaid);
    script.onerror = () => reject(new Error('Could not load the diagram renderer'));
    document.head.appendChild(script);
  });
  return mermaidLoader;
}

async function renderMermaid() {
  const nodes = [...content.querySelectorAll('.mermaid-wrap[data-mermaid-index]')];
  if (!nodes.length) return;
  const sequence = state.renderSeq;
  let mermaid;
  try {
    mermaid = await ensureMermaid();
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: state.theme === 'dark' ? 'dark' : 'default',
      fontFamily: getComputedStyle(document.body).fontFamily,
    });
  } catch (error) {
    for (const node of nodes) {
      node.innerHTML = '<div class="math-error">' + escapeHtml(error.message) + '</div>';
    }
    return;
  }

  for (let index = 0; index < nodes.length; index++) {
    if (sequence !== state.renderSeq) return; // A newer render superseded this one.
    const source = state.mermaidSources[Number(nodes[index].dataset.mermaidIndex)] || '';
    try {
      const { svg } = await mermaid.render('folio-mermaid-' + sequence + '-' + index, source);
      nodes[index].innerHTML = svg;
    } catch (error) {
      nodes[index].innerHTML = '<div class="math-error">'
        + escapeHtml(String((error && error.message) || error)) + '</div>';
    }
  }
}

// ── Interaction ──────────────────────────────────────────────────────────

document.addEventListener('click', (event) => {
  const copy = event.target.closest('.cb-copy');
  if (copy) {
    const code = copy.closest('.codeblock').querySelector('code');
    navigator.clipboard.writeText(code.innerText).then(() => {
      copy.textContent = 'Copied';
      copy.classList.add('ok');
      setTimeout(() => { copy.textContent = 'Copy'; copy.classList.remove('ok'); }, 1200);
    }, () => { copy.textContent = 'Failed'; });
    return;
  }

  const link = event.target.closest('a[href]');
  if (!link) return;
  const href = link.getAttribute('href');
  event.preventDefault();

  if (href.startsWith('#')) {
    const target = document.getElementById(decodeURIComponent(href.slice(1)));
    if (target) {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
      post({ type: 'active', id: target.id });
    }
    return;
  }
  post({ type: 'link', href });
});

// ── Public API used from Swift ───────────────────────────────────────────

window.folio = {
  render(payload) {
    state.markdown = payload.markdown || '';
    state.docDir = payload.docDir || '/';
    state.ext = (payload.ext || 'md').toLowerCase();
    render(Boolean(payload.preserveScroll));
  },

  /// Renders, then resolves once the page has finished settling. Headless
  /// export awaits this so it never captures a half-drawn diagram.
  renderAndSettle(payload) {
    window.folio.render(payload);
    return state.settled;
  },

  setTheme(theme) {
    state.theme = theme === 'dark' ? 'dark' : 'light';
    document.documentElement.dataset.theme = state.theme;
    document.getElementById('hljs-light').disabled = state.theme === 'dark';
    document.getElementById('hljs-dark').disabled = state.theme !== 'dark';
    renderMermaid();
  },

  setTypography(options) {
    const root = document.documentElement;
    root.style.setProperty('--body-size', (options.fontSize || 16) + 'px');
    const family = { serif: 'var(--font-serif)', mono: 'var(--font-mono)' }[options.family]
      || 'var(--font-sans)';
    root.style.setProperty('--body-font', family);
    root.style.setProperty('--gutter-display', options.lineNumbers ? 'block' : 'none');
    root.classList.toggle('wide', Boolean(options.wide));
  },

  scrollTo(anchor) {
    const target = document.getElementById(anchor);
    if (target) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
  },

  beginExport() {
    document.documentElement.classList.add('exporting');
    document.documentElement.dataset.theme = 'light';
    document.getElementById('hljs-light').disabled = false;
    document.getElementById('hljs-dark').disabled = true;
    return document.documentElement.scrollHeight;
  },

  endExport() {
    document.documentElement.classList.remove('exporting');
    window.folio.setTheme(state.theme);
  },

  selectedText() { return String(window.getSelection() || ''); },
};

post({ type: 'ready' });
