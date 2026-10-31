import { useEffect, useId, useState } from 'react';

// Mermaid is loaded on demand from a pinned CDN build so the app bundle does not carry it.
// securityLevel 'strict' makes Mermaid sanitize labels and disables click handlers in diagrams.
const MERMAID_URL = 'https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs';

interface MermaidApi {
  initialize: (config: Record<string, unknown>) => void;
  render: (id: string, code: string) => Promise<{ svg: string }>;
}

let loader: Promise<MermaidApi> | null = null;

function loadMermaid(): Promise<MermaidApi> {
  if (!loader) {
    loader = import(/* @vite-ignore */ MERMAID_URL).then((mod: { default: MermaidApi }) => {
      const m = mod.default;
      m.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        theme: 'dark',
        themeVariables: { fontSize: '14px' },
      });
      return m;
    });
  }
  return loader;
}

export function MermaidBlock({ code }: { code: string }) {
  const id = `mmd-${useId().replace(/[^a-zA-Z0-9]/g, '')}`;
  const [svg, setSvg] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    loadMermaid()
      .then(m => m.render(id, code))
      .then(r => { if (!cancelled) setSvg(r.svg); })
      .catch(() => { if (!cancelled) setFailed(true); });
    return () => { cancelled = true; };
  }, [code, id]);

  if (failed) {
    return (
      <pre className="mono rounded-lg p-4 my-4 overflow-x-auto text-xs"
        style={{ background: 'var(--surface-muted)', border: '1px solid var(--border)', color: 'var(--ink-2)' }}>
        {code}
      </pre>
    );
  }

  return (
    <div className="my-5 rounded-lg p-4 overflow-x-auto"
      style={{ background: 'var(--surface-muted)', border: '1px solid var(--border)', minHeight: svg ? undefined : 120 }}>
      {svg
        // Full-width wrapper: Mermaid's SVG uses width 100% with a max-width of its natural size,
        // so it needs a sized parent (a shrink-to-fit parent collapses it to about 300px).
        ? <div className="w-full [&_svg]:block [&_svg]:mx-auto [&_svg]:h-auto" dangerouslySetInnerHTML={{ __html: svg }} />
        : <span className="text-xs" style={{ color: 'var(--subtle)' }}>Loading diagram…</span>}
    </div>
  );
}
