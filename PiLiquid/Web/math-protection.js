(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.PiMath = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const DELIMITERS = [
    { left: '$$', right: '$$' },
    { left: '\\[', right: '\\]' },
    { left: '\\(', right: '\\)' },
    { left: '$', right: '$' }
  ];
  const PLACEHOLDER_PREFIX = 'PILIQUIDMATH';

  function hashText(text) {
    let hash = 0x811c9dc5;
    for (let i = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193);
    }
    return (hash >>> 0).toString(36);
  }

  function isEscaped(text, index) {
    let slashes = 0;
    for (let i = index - 1; i >= 0 && text[i] === '\\'; i--) slashes++;
    return slashes % 2 === 1;
  }

  // Mirrors KaTeX auto-render's delimiter search: escaped characters are
  // skipped and a closing delimiter inside braces does not end the formula.
  function findMathEnd(text, right, start) {
    let braces = 0;
    for (let i = start; i < text.length; i++) {
      if (braces <= 0 && text.slice(i, i + right.length) === right) return i;
      if (text[i] === '\\') i++;
      else if (text[i] === '{') braces++;
      else if (text[i] === '}') braces--;
    }
    return -1;
  }

  function lineEnd(text, start) {
    const newline = text.indexOf('\n', start);
    return newline < 0 ? text.length : newline + 1;
  }

  // Return the end of a Markdown fenced code block, or -1 when `index` is not
  // an opening fence. Math delimiters inside code must never pair with text
  // outside that code block.
  function fencedCodeEnd(text, index) {
    const marker = text[index];
    if (marker !== '`' && marker !== '~') return -1;

    const startOfLine = index === 0 || text[index - 1] === '\n';
    if (!startOfLine) {
      const previousNewline = text.lastIndexOf('\n', index - 1);
      const prefix = text.slice(previousNewline + 1, index);
      if (prefix.length > 3 || !/^ {0,3}$/.test(prefix)) return -1;
    }

    let run = 1;
    while (text[index + run] === marker) run++;
    if (run < 3) return -1;

    let cursor = lineEnd(text, index + run);
    while (cursor < text.length) {
      let i = cursor;
      let spaces = 0;
      while (spaces < 3 && text[i] === ' ') { spaces++; i++; }

      let closingRun = 0;
      while (text[i + closingRun] === marker) closingRun++;
      if (closingRun >= run) {
        const restEnd = text.indexOf('\n', i + closingRun);
        const end = restEnd < 0 ? text.length : restEnd;
        if (/^[ \t\r]*$/.test(text.slice(i + closingRun, end))) {
          return restEnd < 0 ? text.length : restEnd + 1;
        }
      }
      cursor = lineEnd(text, cursor);
    }

    // An unclosed fence consumes the rest of the Markdown document.
    return text.length;
  }

  function codeSpanEnd(text, index) {
    if (text[index] !== '`') return -1;
    let run = 1;
    while (text[index + run] === '`') run++;
    const marker = '`'.repeat(run);
    const close = text.indexOf(marker, index + run);
    return close < 0 ? -1 : close + run;
  }

  function protect(markdown) {
    const source = String(markdown || '');
    const items = [];
    let output = '';
    let i = 0;

    while (i < source.length) {
      const fenceEnd = fencedCodeEnd(source, i);
      if (fenceEnd >= 0) {
        output += source.slice(i, fenceEnd);
        i = fenceEnd;
        continue;
      }

      const spanEnd = codeSpanEnd(source, i);
      if (spanEnd >= 0) {
        output += source.slice(i, spanEnd);
        i = spanEnd;
        continue;
      }

      let delimiter = null;
      for (let j = 0; j < DELIMITERS.length; j++) {
        const candidate = DELIMITERS[j];
        if (source.slice(i, i + candidate.left.length) === candidate.left && !isEscaped(source, i)) {
          delimiter = candidate;
          break;
        }
      }

      if (delimiter) {
        const close = findMathEnd(source, delimiter.right, i + delimiter.left.length);
        if (close >= 0) {
          const end = close + delimiter.right.length;
          const raw = source.slice(i, end);
          const key = PLACEHOLDER_PREFIX + items.length + 'L' + raw.length + 'X' + hashText(raw) + 'Z';
          items.push({ key: key, raw: raw });
          output += key;
          i = end;
          continue;
        }
      }

      output += source[i];
      i++;
    }

    return { text: output, items: items };
  }

  // Restore into text nodes only. Formula source therefore cannot become HTML,
  // while KaTeX can still discover the original delimiters on its next pass.
  function restore(rootElement, items) {
    if (!rootElement || !items || items.length === 0) return;
    const values = new Map(items.map(function (item) { return [item.key, item.raw]; }));
    const nodes = [];
    const walker = document.createTreeWalker(rootElement, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) nodes.push(walker.currentNode);

    nodes.forEach(function (node) {
      const text = node.nodeValue || '';
      if (text.indexOf(PLACEHOLDER_PREFIX) < 0) return;

      const pattern = /PILIQUIDMATH\d+L\d+X[0-9a-z]+Z/g;
      let match;
      let offset = 0;
      let changed = false;
      const fragment = document.createDocumentFragment();
      while ((match = pattern.exec(text)) !== null) {
        const raw = values.get(match[0]);
        if (raw === undefined) continue;
        fragment.appendChild(document.createTextNode(text.slice(offset, match.index)));
        fragment.appendChild(document.createTextNode(raw));
        offset = match.index + match[0].length;
        changed = true;
      }
      if (!changed) return;
      fragment.appendChild(document.createTextNode(text.slice(offset)));
      node.parentNode.replaceChild(fragment, node);
    });
  }

  return { protect: protect, restore: restore };
});
