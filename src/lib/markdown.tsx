/**
 * Minimal Markdown renderer for the in-app docs (no dependencies).
 * Supports: # to ### headings, paragraphs, - and 1. lists, tables, > quotes, ``` code blocks,
 * --- rules, **bold**, `code` and [links](url). Output is React elements only (never raw HTML),
 * and links are limited to http(s) URLs and in-page anchors, so fetched content cannot inject markup.
 */
import React from 'react';

export interface DocHeading { level: number; text: string; id: string }

export function slugify(text: string): string {
  return text.toLowerCase().replace(/[`*]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

function safeHref(url: string): string | null {
  if (url.startsWith('#')) return url;
  try {
    const u = new URL(url);
    return u.protocol === 'https:' || u.protocol === 'http:' ? u.toString() : null;
  } catch {
    return null;
  }
}

/** Inline formatting: links, bold, code. */
function inline(text: string, keyBase: string): React.ReactNode[] {
  const out: React.ReactNode[] = [];
  const re = /(\[([^\]]+)\]\(([^)\s]+)\))|(\*\*([^*]+)\*\*)|(`([^`]+)`)/g;
  let last = 0;
  let m: RegExpExecArray | null;
  let i = 0;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const key = `${keyBase}-${i++}`;
    if (m[1]) {
      const href = safeHref(m[3]);
      const label = inline(m[2], key);
      out.push(href
        ? <a key={key} href={href} target={href.startsWith('#') ? undefined : '_blank'} rel="noopener noreferrer"
            style={{ color: 'var(--accent)', textDecoration: 'underline', textUnderlineOffset: 2 }}>{label}</a>
        : <span key={key}>{label}</span>);
    } else if (m[4]) {
      out.push(<strong key={key} style={{ color: 'var(--ink)' }}>{inline(m[5], key)}</strong>);
    } else if (m[6]) {
      out.push(<code key={key} className="mono" style={{ background: 'var(--surface-muted)', padding: '1px 5px', borderRadius: 4, fontSize: '0.85em' }}>{m[7]}</code>);
    }
    last = re.lastIndex;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

function splitRow(line: string): string[] {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(c => c.trim());
}

export function parseHeadings(md: string): DocHeading[] {
  const hs: DocHeading[] = [];
  let inCode = false;
  for (const line of md.split('\n')) {
    if (line.startsWith('```')) inCode = !inCode;
    if (inCode) continue;
    const m = /^(#{1,3})\s+(.*)$/.exec(line);
    if (m) hs.push({ level: m[1].length, text: m[2].trim(), id: slugify(m[2]) });
  }
  return hs;
}

export function renderMarkdown(md: string): React.ReactNode[] {
  const lines = md.replace(/\r\n/g, '\n').split('\n');
  const blocks: React.ReactNode[] = [];
  let i = 0;
  let k = 0;
  const text = 'var(--ink-2)';

  while (i < lines.length) {
    const line = lines[i];
    const key = `b${k++}`;

    if (line.trim() === '') { i++; continue; }

    if (line.startsWith('```')) {
      const code: string[] = [];
      i++;
      while (i < lines.length && !lines[i].startsWith('```')) code.push(lines[i++]);
      i++;
      blocks.push(
        <pre key={key} className="mono rounded-lg p-4 my-4 overflow-x-auto text-xs"
          style={{ background: 'var(--surface-muted)', border: '1px solid var(--border)', color: text }}>
          {code.join('\n')}
        </pre>
      );
      continue;
    }

    const h = /^(#{1,3})\s+(.*)$/.exec(line);
    if (h) {
      const level = h[1].length;
      const id = slugify(h[2]);
      const content = inline(h[2], key);
      if (level === 1) blocks.push(<h1 key={key} id={id} className="display text-3xl font-bold mb-3" style={{ color: 'var(--ink)', letterSpacing: '-0.03em', scrollMarginTop: 24 }}>{content}</h1>);
      else if (level === 2) blocks.push(<h2 key={key} id={id} className="display text-xl font-bold mt-10 mb-3" style={{ color: 'var(--ink)', letterSpacing: '-0.02em', scrollMarginTop: 24 }}>{content}</h2>);
      else blocks.push(<h3 key={key} id={id} className="text-base font-semibold mt-6 mb-2" style={{ color: 'var(--ink)', scrollMarginTop: 24 }}>{content}</h3>);
      i++;
      continue;
    }

    if (/^---+\s*$/.test(line)) {
      blocks.push(<hr key={key} className="my-8" style={{ borderColor: 'var(--border)' }} />);
      i++;
      continue;
    }

    if (line.startsWith('>')) {
      const quote: string[] = [];
      while (i < lines.length && lines[i].startsWith('>')) quote.push(lines[i++].replace(/^>\s?/, ''));
      blocks.push(
        <div key={key} className="rounded-lg px-4 py-3 my-4 text-sm leading-relaxed"
          style={{ background: 'rgba(245, 158, 11, 0.08)', border: '1px solid rgba(245, 158, 11, 0.25)', color: text }}>
          {inline(quote.join(' '), key)}
        </div>
      );
      continue;
    }

    if (line.trim().startsWith('|')) {
      const rows: string[] = [];
      while (i < lines.length && lines[i].trim().startsWith('|')) rows.push(lines[i++]);
      const header = splitRow(rows[0]);
      const body = rows.slice(2).map(splitRow);
      blocks.push(
        <div key={key} className="my-4 overflow-x-auto rounded-lg" style={{ border: '1px solid var(--border)' }}>
          <table className="w-full text-sm" style={{ borderCollapse: 'collapse' }}>
            <thead>
              <tr style={{ background: 'var(--surface-muted)' }}>
                {header.map((c, ci) => (
                  <th key={ci} className="text-left px-3 py-2 text-xs font-semibold" style={{ color: 'var(--muted)', borderBottom: '1px solid var(--border)' }}>
                    {inline(c, `${key}-h${ci}`)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {body.map((r, ri) => (
                <tr key={ri} style={{ borderTop: ri ? '1px solid var(--border)' : undefined }}>
                  {r.map((c, ci) => (
                    <td key={ci} className={`px-3 py-2 align-top ${ci === 0 ? 'whitespace-nowrap' : ''}`} style={{ color: text }}>{inline(c, `${key}-${ri}-${ci}`)}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
      continue;
    }

    const ul = /^\s*-\s+/;
    const ol = /^\s*\d+\.\s+/;
    if (ul.test(line) || ol.test(line)) {
      const ordered = ol.test(line);
      const items: { text: string; nested: string[] }[] = [];
      while (i < lines.length && (ul.test(lines[i]) || ol.test(lines[i]))) {
        const indented = /^\s{2,}/.test(lines[i]);
        const content = lines[i].replace(ordered && !indented ? ol : ul, '').replace(ol, '');
        if (indented && items.length) items[items.length - 1].nested.push(content);
        else items.push({ text: content, nested: [] });
        i++;
      }
      const Tag = ordered ? 'ol' : 'ul';
      blocks.push(
        <Tag key={key} className={`my-3 pl-6 space-y-1.5 text-sm leading-relaxed ${ordered ? 'list-decimal' : 'list-disc'}`} style={{ color: text }}>
          {items.map((it, ii) => (
            <li key={ii}>
              {inline(it.text, `${key}-${ii}`)}
              {it.nested.length > 0 && (
                <ul className="list-[circle] pl-5 mt-1 space-y-1">
                  {it.nested.map((n, ni) => <li key={ni}>{inline(n, `${key}-${ii}-${ni}`)}</li>)}
                </ul>
              )}
            </li>
          ))}
        </Tag>
      );
      continue;
    }

    // Paragraph: consecutive non-blank lines; single newlines become line breaks.
    const para: string[] = [];
    while (i < lines.length && lines[i].trim() !== '' && !/^(#{1,3}\s|```|>|\||---+\s*$|\s*-\s+|\s*\d+\.\s+)/.test(lines[i])) {
      para.push(lines[i++]);
    }
    if (para.length === 0) { i++; continue; }
    blocks.push(
      <p key={key} className="my-3 text-sm leading-relaxed" style={{ color: text }}>
        {para.map((p, pi) => (
          <React.Fragment key={pi}>{pi > 0 && <br />}{inline(p, `${key}-${pi}`)}</React.Fragment>
        ))}
      </p>
    );
  }
  return blocks;
}
