import { useEffect, useMemo, useState } from 'react';
import { BookOpen, ExternalLink } from 'lucide-react';
import bundledGuide from '../../docs/user-guide.md?raw';
import { parseHeadings, renderMarkdown } from '../lib/markdown';

// The guide lives in the repo (docs/user-guide.md). The page loads the latest version from GitHub and
// falls back to the copy bundled at build time (offline, rate-limited, or while the repo is private).
const REPO = '0xhaz/DefiVault-Finance';
const PATH = 'docs/user-guide.md';
const RAW_URL = `https://raw.githubusercontent.com/${REPO}/main/${PATH}`;
const VIEW_URL = `https://github.com/${REPO}/blob/main/${PATH}`;

export function DocsPage() {
  const [markdown, setMarkdown] = useState<string>(bundledGuide);
  const [source, setSource] = useState<'github' | 'bundled'>('bundled');

  useEffect(() => {
    let cancelled = false;
    fetch(RAW_URL, { cache: 'no-cache' })
      .then(r => (r.ok ? r.text() : Promise.reject(new Error(String(r.status)))))
      .then(text => {
        if (!cancelled && text.trim().startsWith('#')) { setMarkdown(text); setSource('github'); }
      })
      .catch(() => { /* keep bundled copy */ });
    return () => { cancelled = true; };
  }, []);

  const content = useMemo(() => renderMarkdown(markdown), [markdown]);
  const toc = useMemo(() => parseHeadings(markdown).filter(h => h.level === 2), [markdown]);

  return (
    <div className="grid grid-cols-1 lg:grid-cols-[200px_minmax(0,1fr)] gap-8">
      <aside className="hidden lg:block">
        <div className="sticky top-6 space-y-1">
          <p className="flex items-center gap-2 text-xs uppercase mb-3" style={{ color: 'var(--subtle)', letterSpacing: '0.08em' }}>
            <BookOpen size={13} /> User Guide
          </p>
          {toc.map(h => (
            <a key={h.id} href={`#${h.id}`} className="block text-sm py-1 transition-colors"
              style={{ color: 'var(--muted)' }}
              onClick={e => { e.preventDefault(); document.getElementById(h.id)?.scrollIntoView({ behavior: 'smooth' }); }}>
              {h.text}
            </a>
          ))}
        </div>
      </aside>

      <article className="min-w-0 rounded-xl px-5 sm:px-8 py-8"
        style={{ background: 'var(--surface)', border: '1px solid var(--border)' }}>
        <div className="flex items-center justify-between gap-3 mb-6 text-xs" style={{ color: 'var(--subtle)' }}>
          <span>Source: {source === 'github' ? 'GitHub (latest)' : 'bundled copy'}</span>
          <a href={VIEW_URL} target="_blank" rel="noopener noreferrer" className="flex items-center gap-1"
            style={{ color: 'var(--accent)' }}>
            View on GitHub <ExternalLink size={12} />
          </a>
        </div>
        {content}
      </article>
    </div>
  );
}
