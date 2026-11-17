import React from 'react'

export function statusTone(s) {
  if (!s) return 'bg-slate-200 text-slate-700'
  if (s < 300) return 'bg-emerald-100 text-emerald-800'
  if (s === 429) return 'bg-amber-100 text-amber-800'
  if (s === 401 || s === 403) return 'bg-rose-100 text-rose-800'
  return 'bg-orange-100 text-orange-800'
}
export const Status = ({ s }) => <span className={`chip ${statusTone(s)}`}>{s || '…'}</span>

export function explainStatus(r) {
  if (!r) return ''
  const e = typeof r.error === 'string' ? r.error : ''
  if (r.status === 200) return r.modelServed && r.modelServed !== r.modelAsked ? `answered by ${r.modelServed}` : 'answered'
  if (r.status === 401 && /api key/i.test(e)) return 'OpenAI rejected the key (not set): ./deploy.sh ai-gateways openai-key'
  if (r.status === 401) return 'no / unknown API key (AuthPolicy)'
  if (r.status === 403 && /tier/i.test(e)) return 'tier gate in Praxis (needs gold)'
  if (r.status === 403) return 'blocked by Praxis guardrails before OpenAI'
  if (r.status === 404) return 'unknown model for this API version (Praxis)'
  if (r.status === 429) return 'rate limited (Connectivity Link / Praxis)'
  return e.slice(0, 80)
}

export function Section({ title, children, right }) {
  return (
    <div className="card p-4">
      <div className="mb-3 flex items-center justify-between gap-2">
        <h3 className="font-display text-sm font-bold text-slate-800">{title}</h3>
        {right}
      </div>
      {children}
    </div>
  )
}

export function Kv({ k, v, mono = true }) {
  return (
    <div className="flex gap-2 text-xs">
      <span className="w-28 shrink-0 text-slate-500">{k}</span>
      <span className={`${mono ? 'font-mono' : ''} break-all text-slate-800`}>{v}</span>
    </div>
  )
}

export function ResultCard({ r, title, compact = false }) {
  if (!r) return null
  const u = r.usage
  return (
    <div className="rounded-lg border border-slate-200 bg-slate-50 p-3">
      <div className="mb-2 flex flex-wrap items-center gap-2">
        {title && <span className="text-sm font-semibold text-slate-800">{title}</span>}
        <Status s={r.status} />
        <span className="chip bg-white text-slate-700 ring-1 ring-slate-200">{r.ms} ms</span>
        {u && <span className="chip bg-white text-slate-700 ring-1 ring-slate-200">{u.prompt_tokens}+{u.completion_tokens}={u.total_tokens} tok</span>}
        {r.modelServed && <span className="chip bg-indigo-50 text-indigo-800">{r.modelServed}</span>}
        <span className="text-xs text-slate-500">{explainStatus(r)}</span>
      </div>
      {r.answer && <p className="whitespace-pre-wrap text-sm text-slate-800">{r.answer}</p>}
      {!r.answer && r.error && <p className="font-mono text-xs text-rose-700">{typeof r.error === 'string' ? r.error : JSON.stringify(r.error)}</p>}
      {!compact && (
        <details className="mt-2">
          <summary className="cursor-pointer text-xs text-slate-500">request / response headers</summary>
          <div className="mt-2 space-y-1">
            <Kv k="request" v={`${r.request.method} ${r.request.url}`} />
            {Object.entries(r.request.headers).map(([k, v]) => <Kv key={k} k={k} v={v} />)}
            <Kv k="body" v={JSON.stringify(r.request.body)} />
            <div className="my-1 border-t border-slate-200" />
            {Object.entries(r.responseHeaders || {}).map(([k, v]) => <Kv key={k} k={`← ${k}`} v={v} />)}
          </div>
        </details>
      )}
    </div>
  )
}

export function Story({ children }) {
  return <p className="max-w-3xl text-sm leading-relaxed text-slate-600">{children}</p>
}

export function Where({ items }) {
  return (
    <div className="flex flex-wrap gap-1.5">
      {items.map((i) => (
        <span key={i} className={`chip ${i.startsWith('Praxis') ? 'bg-violet-100 text-violet-800' : 'bg-sky-100 text-sky-800'}`}>{i}</span>
      ))}
    </div>
  )
}
