const MARKDOWN_MAX_LENGTH = 256 * 1024;
const MARKDOWN_MAX_LINES = 500;
const MARKDOWN_MAX_PIPES = 1000;
const MARKDOWN_INLINE_MAX_DEPTH = 12;
const MARKDOWN_INLINE_MAX_NODES = 5000;
const MARKDOWN_INLINE_SEARCH_WINDOW = 500;

function normalizeMarkdownLineEndings(text) {
  return text.replace(/\r\n?/g, '\n');
}

function markdownWithinRenderingLimits(text) {
  if (text.length > MARKDOWN_MAX_LENGTH) return false;
  const normalized = normalizeMarkdownLineEndings(text);
  let lines = 1;
  let pipes = 0;
  for (const character of normalized) {
    if (character === '\n') {
      lines += 1;
      if (lines > MARKDOWN_MAX_LINES) return false;
    } else if (character === '|') {
      pipes += 1;
      if (pipes > MARKDOWN_MAX_PIPES) return false;
    }
  }
  return true;
}

function markdownFenceLength(line) {
  let ticks = 0;
  while (line[ticks] === '`') ticks += 1;
  return ticks >= 3 ? ticks : 0;
}

function markdownIsClosingFence(line, openLength) {
  if (line.length < openLength) return false;
  for (const character of line) {
    if (character !== '`') return false;
  }
  return true;
}

function markdownHeading(line) {
  let level = 0;
  while (line[level] === '#') level += 1;
  if (level < 1 || level > 6 || line[level] !== ' ') return null;
  return { level, text: line.slice(level + 1).trim() };
}

function markdownListItem(line) {
  let leading = 0;
  let indentation = 0;
  while (line[leading] === ' ' || line[leading] === '\t') {
    indentation += line[leading] === '\t' ? 4 : 1;
    leading += 1;
  }
  const body = line.slice(leading);
  const unordered = body.match(/^([-+*]) +(.*)$/);
  if (unordered) {
    return { marker: '\u2022', text: unordered[2], depth: Math.floor(indentation / 2) };
  }
  const ordered = body.match(/^(\d+\.) +(.*)$/);
  if (ordered) {
    return {
      marker: ordered[1],
      text: ordered[2],
      depth: Math.floor(indentation / 2)
    };
  }
  return null;
}

function markdownIsBlockStart(line) {
  return markdownFenceLength(line) > 0
    || markdownHeading(line) !== null
    || line.startsWith('>');
}

function markdownRowHasPipe(line) {
  let backslashes = 0;
  for (const character of line) {
    if (character === '|' && backslashes % 2 === 0) return true;
    backslashes = character === '\\' ? backslashes + 1 : 0;
  }
  return false;
}

function splitMarkdownTableRow(line) {
  const cells = [];
  let current = '';
  let backslashes = 0;
  for (const character of line) {
    if (character === '|') {
      if (backslashes % 2 === 0) {
        cells.push(current);
        current = '';
      } else {
        current = current.slice(0, -1) + '|';
      }
    } else {
      current += character;
    }
    backslashes = character === '\\' ? backslashes + 1 : 0;
  }
  cells.push(current);
  const trimmed = cells.map((cell) => cell.trim());
  if (trimmed[0] === '') trimmed.shift();
  if (trimmed[trimmed.length - 1] === '') trimmed.pop();
  return trimmed;
}

function markdownTableAlignments(line) {
  if (!markdownRowHasPipe(line)) return null;
  const cells = splitMarkdownTableRow(line);
  if (!cells.length) return null;
  const alignments = [];
  for (const cell of cells) {
    const leading = cell.startsWith(':');
    const trailing = cell.endsWith(':');
    const dashes = cell.slice(leading ? 1 : 0, trailing ? -1 : undefined);
    if (dashes.length < 3 || !dashes.split('').every((character) => character === '-')) {
      return null;
    }
    alignments.push(leading && trailing ? 'center' : trailing ? 'right' : 'left');
  }
  return alignments;
}

function parseMarkdownBlocks(value) {
  const text = normalizeMarkdownLineEndings(String(value ?? ''));
  const lines = text.split('\n');
  const blocks = [];
  let paragraph = [];
  let index = 0;

  const flushParagraph = () => {
    if (!paragraph.length) return;
    blocks.push({ type: 'paragraph', text: paragraph.join('\n') });
    paragraph = [];
  };

  while (index < lines.length) {
    const line = lines[index];
    const trimmed = line.trim();
    const fenceLength = markdownFenceLength(trimmed);
    if (fenceLength) {
      flushParagraph();
      const code = [];
      index += 1;
      while (index < lines.length
          && !markdownIsClosingFence(lines[index].trim(), fenceLength)) {
        code.push(lines[index]);
        index += 1;
      }
      if (index < lines.length) index += 1;
      blocks.push({ type: 'code', text: code.join('\n') });
      continue;
    }

    if (!trimmed) {
      flushParagraph();
      index += 1;
      continue;
    }

    const heading = markdownHeading(trimmed);
    if (heading) {
      flushParagraph();
      blocks.push({ type: 'heading', level: heading.level, text: heading.text });
      index += 1;
      continue;
    }

    if (trimmed.startsWith('>')) {
      flushParagraph();
      const quote = [];
      while (index < lines.length) {
        const candidate = lines[index].trim();
        if (!candidate.startsWith('>')) break;
        quote.push(candidate.slice(1).trim());
        index += 1;
      }
      blocks.push({ type: 'quote', text: quote.join('\n') });
      continue;
    }

    if (markdownListItem(line)) {
      flushParagraph();
      const items = [];
      while (index < lines.length) {
        const item = markdownListItem(lines[index]);
        if (item) {
          items.push(item);
          index += 1;
          continue;
        }
        const continuation = lines[index].trim();
        if (items.length && continuation && !markdownIsBlockStart(continuation)) {
          items[items.length - 1].text += ` ${continuation}`;
          index += 1;
          continue;
        }
        break;
      }
      blocks.push({ type: 'list', items });
      continue;
    }

    if (index + 1 < lines.length && markdownRowHasPipe(trimmed)) {
      const alignments = markdownTableAlignments(lines[index + 1].trim());
      const header = splitMarkdownTableRow(trimmed);
      if (alignments && header.length === alignments.length) {
        flushParagraph();
        index += 2;
        const rows = [];
        while (index < lines.length) {
          const row = lines[index].trim();
          if (!row || !markdownRowHasPipe(row)) break;
          if (!row.startsWith('|')) {
            if (markdownIsBlockStart(row)) break;
            const item = markdownListItem(lines[index]);
            if (item && !item.text.startsWith('|')) break;
          }
          rows.push(splitMarkdownTableRow(row));
          index += 1;
        }
        blocks.push({ type: 'table', header, alignments, rows });
        continue;
      }
    }

    paragraph.push(line);
    index += 1;
  }

  flushParagraph();
  return blocks;
}

function markdownAnchor(href, label) {
  let url = null;
  try { url = new URL(href); } catch (_) {}
  if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')) return null;
  const anchor = document.createElement('a');
  anchor.className = 'terminal-link';
  anchor.href = url.href;
  anchor.target = '_blank';
  anchor.rel = 'noopener noreferrer';
  anchor.textContent = label;
  anchor.onclick = (event) => event.stopPropagation();
  return anchor;
}

// Finds `needle` within a bounded window starting at `start` so a single
// delimiter search never scans more than MARKDOWN_INLINE_SEARCH_WINDOW
// characters. Without this, adversarial input (e.g. a long run of `[`
// with no closing `](`) makes every cursor position rescan the rest of
// the string, which is quadratic in the input length.
function boundedIndexOf(text, needle, start) {
  if (start >= text.length) return -1;
  const end = Math.min(text.length, start + MARKDOWN_INLINE_SEARCH_WINDOW);
  const found = text.slice(start, end).indexOf(needle);
  return found === -1 ? -1 : start + found;
}

function appendMarkdownInline(parent, value, depth = 0, budget = { remaining: MARKDOWN_INLINE_MAX_NODES }) {
  const text = String(value ?? '');
  if (depth >= MARKDOWN_INLINE_MAX_DEPTH || budget.remaining <= 0) {
    parent.append(document.createTextNode(text));
    return;
  }

  let cursor = 0;
  let plainStart = 0;
  const appendNode = (node) => {
    parent.append(node);
    budget.remaining -= 1;
  };
  const flushPlain = (end) => {
    if (end > plainStart) {
      appendNode(document.createTextNode(text.slice(plainStart, end)));
    }
  };
  // CommonMark only treats a lone "_" as emphasis when it isn't nestled
  // between two word characters, so identifiers like "snake_case_id"
  // stay literal while " _italic_ " still renders as emphasis.
  const isWordCharacter = (char) => char !== undefined && /[A-Za-z0-9]/.test(char);
  const isIntrawordUnderscore = (openStart, closeStart, markerLength) =>
    isWordCharacter(text[openStart - 1]) && isWordCharacter(text[closeStart + markerLength]);

  while (cursor < text.length) {
    if (budget.remaining <= 0) break;

    if (text[cursor] === '\\' && cursor + 1 < text.length
        && '\\`*[]()_~'.includes(text[cursor + 1])) {
      flushPlain(cursor);
      appendNode(document.createTextNode(text[cursor + 1]));
      cursor += 2;
      plainStart = cursor;
      continue;
    }

    if (text[cursor] === '`') {
      let ticks = 1;
      while (text[cursor + ticks] === '`') ticks += 1;
      const marker = '`'.repeat(ticks);
      const close = boundedIndexOf(text, marker, cursor + ticks);
      if (close >= 0) {
        flushPlain(cursor);
        const code = document.createElement('code');
        code.textContent = text.slice(cursor + ticks, close);
        appendNode(code);
        cursor = close + ticks;
        plainStart = cursor;
        continue;
      }
    }

    if (text.startsWith('![', cursor)) {
      const labelEnd = boundedIndexOf(text, '](', cursor + 2);
      const urlEnd = labelEnd >= 0 ? boundedIndexOf(text, ')', labelEnd + 2) : -1;
      if (labelEnd >= 0 && urlEnd >= 0) {
        flushPlain(cursor);
        appendNode(document.createTextNode(
          `[Image: ${text.slice(cursor + 2, labelEnd)}]`
        ));
        cursor = urlEnd + 1;
        plainStart = cursor;
        continue;
      }
    }

    if (text[cursor] === '[') {
      const labelEnd = boundedIndexOf(text, '](', cursor + 1);
      const urlEnd = labelEnd >= 0 ? boundedIndexOf(text, ')', labelEnd + 2) : -1;
      if (labelEnd >= 0 && urlEnd >= 0) {
        const label = text.slice(cursor + 1, labelEnd);
        const anchor = markdownAnchor(text.slice(labelEnd + 2, urlEnd), label);
        if (anchor) {
          flushPlain(cursor);
          appendNode(anchor);
          cursor = urlEnd + 1;
          plainStart = cursor;
          continue;
        }
      }
    }

    if (text.startsWith('http://', cursor) || text.startsWith('https://', cursor)) {
      let end = cursor;
      while (end < text.length && !/[\s<>()\[\]]/.test(text[end])) end += 1;
      while (end > cursor && '.,;:!?'.includes(text[end - 1])) end -= 1;
      const href = text.slice(cursor, end);
      const anchor = markdownAnchor(href, href);
      if (anchor) {
        flushPlain(cursor);
        appendNode(anchor);
        cursor = end;
        plainStart = cursor;
        continue;
      }
    }

    const pairedMarkers = [
      ['**', 'strong'],
      ['__', 'strong'],
      ['~~', 'del'],
      ['*', 'em'],
      ['_', 'em']
    ];
    let matched = false;
    for (const [marker, tag] of pairedMarkers) {
      if (!text.startsWith(marker, cursor)) continue;
      const close = boundedIndexOf(text, marker, cursor + marker.length);
      if (close <= cursor + marker.length) continue;
      if (marker === '_' && isIntrawordUnderscore(cursor, close, marker.length)) continue;
      flushPlain(cursor);
      const element = document.createElement(tag);
      appendMarkdownInline(
        element,
        text.slice(cursor + marker.length, close),
        depth + 1,
        budget
      );
      appendNode(element);
      cursor = close + marker.length;
      plainStart = cursor;
      matched = true;
      break;
    }
    if (matched) continue;

    cursor += 1;
  }

  flushPlain(text.length);
}

function appendMarkdown(parent, value) {
  const text = String(value ?? '');
  const body = document.createElement('div');
  body.className = 'markdown';
  if (!markdownWithinRenderingLimits(text)) {
    const paragraph = document.createElement('p');
    appendLinkedText(paragraph, text);
    body.append(paragraph);
    parent.append(body);
    return;
  }

  // Shared across every inline call for this document render so a
  // pathological input (e.g. thousands of tiny bold spans) can't
  // amplify into an unbounded number of DOM nodes.
  const inlineBudget = { remaining: MARKDOWN_INLINE_MAX_NODES };

  parseMarkdownBlocks(text).forEach((block) => {
    if (block.type === 'heading') {
      const heading = document.createElement(`h${block.level}`);
      appendMarkdownInline(heading, block.text, 0, inlineBudget);
      body.append(heading);
    } else if (block.type === 'paragraph') {
      const paragraph = document.createElement('p');
      appendMarkdownInline(paragraph, block.text, 0, inlineBudget);
      body.append(paragraph);
    } else if (block.type === 'code') {
      const pre = document.createElement('pre');
      const code = document.createElement('code');
      code.textContent = block.text;
      pre.append(code);
      body.append(pre);
    } else if (block.type === 'quote') {
      const quote = document.createElement('blockquote');
      appendMarkdownInline(quote, block.text, 0, inlineBudget);
      body.append(quote);
    } else if (block.type === 'list') {
      const list = document.createElement('div');
      list.className = 'markdown-list';
      list.setAttribute('role', 'list');
      block.items.forEach((item) => {
        const row = document.createElement('div');
        row.className = 'markdown-list-item';
        row.setAttribute('role', 'listitem');
        row.style.setProperty(
          '--markdown-indent',
          `${Math.min(item.depth, 6) * 14}px`
        );
        const marker = document.createElement('span');
        marker.className = 'markdown-list-marker';
        marker.textContent = item.marker;
        const itemBody = document.createElement('span');
        itemBody.className = 'markdown-list-body';
        appendMarkdownInline(itemBody, item.text, 0, inlineBudget);
        row.append(marker, itemBody);
        list.append(row);
      });
      body.append(list);
    } else if (block.type === 'table') {
      const wrapper = document.createElement('div');
      wrapper.className = 'markdown-table-wrap';
      const table = document.createElement('table');
      const head = document.createElement('thead');
      const headerRow = document.createElement('tr');
      block.header.forEach((value, column) => {
        const cell = document.createElement('th');
        cell.style.textAlign = block.alignments[column] || 'left';
        appendMarkdownInline(cell, value, 0, inlineBudget);
        headerRow.append(cell);
      });
      head.append(headerRow);
      table.append(head);
      const bodyRows = document.createElement('tbody');
      block.rows.forEach((values) => {
        const row = document.createElement('tr');
        block.header.forEach((_, column) => {
          const cell = document.createElement('td');
          cell.style.textAlign = block.alignments[column] || 'left';
          appendMarkdownInline(cell, values[column] || '', 0, inlineBudget);
          row.append(cell);
        });
        bodyRows.append(row);
      });
      table.append(bodyRows);
      wrapper.append(table);
      body.append(wrapper);
    }
  });
  parent.append(body);
}
