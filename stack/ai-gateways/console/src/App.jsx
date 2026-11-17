import React, { useCallback, useEffect, useState } from 'react'
import { api } from './api.js'
import { Guardrails, Identity, LedgerTable, LocalVsOpenAI, Metrics, ModelRouting, Overview, Throttle, Tokens, Versioning } from './pages.jsx'

const PAGES = [
  { id: 'overview', label: 'Overview', group: 'Start', C: Overview },
  { id: 'routing', label: 'Model routing', group: 'Praxis AI', C: ModelRouting },
  { id: 'openai', label: 'Local model vs OpenAI', group: 'Praxis AI', C: LocalVsOpenAI },
  { id: 'guardrails', label: 'Block OpenAI: coffee, lemons, email', group: 'Praxis AI', C: Guardrails },
  { id: 'throttle', label: 'Throttle 5 req/s', group: 'Connectivity Link', C: Throttle },
  { id: 'tokens', label: 'Token limits', group: 'Connectivity Link', C: Tokens },
  { id: 'versioning', label: 'API versioning', group: 'Connectivity Link', C: Versioning },
  { id: 'identity', label: 'Who may use OpenAI', group: 'Better together', C: Identity },
  { id: 'metrics', label: 'Metrics', group: 'Better together', C: Metrics },
]

export default function App() {
  const [page, setPage] = useState(() => (location.hash || '#overview').slice(1))
  const [consumer, setConsumer] = useState('bob')
  const [cfg, setCfg] = useState(null)
  const [err, setErr] = useState('')
  const [ledger, setLedger] = useState([])
  const [showLedger, setShowLedger] = useState(false)

  const reload = useCallback(() => {
    api.config().then((c) => { setCfg(c); setErr('') }).catch((e) => setErr(e.message))
  }, [])
  useEffect(() => { reload() }, [reload])
  useEffect(() => { location.hash = page }, [page])
  useEffect(() => {
    if (!showLedger) return
    const load = () => api.ledger().then(setLedger).catch(() => {})
    load(); const t = setInterval(load, 3000); return () => clearInterval(t)
  }, [showLedger])

  const P = PAGES.find((p) => p.id === page) || PAGES[0]
  const groups = [...new Set(PAGES.map((p) => p.group))]
  return (
    <div className="flex min-h-screen flex-col">
      <header className="sticky top-0 z-10 flex flex-wrap items-center justify-between gap-3 border-b border-slate-800 bg-slate-950 px-5 py-3 text-white">
        <div className="flex items-center gap-3">
          <div className="h-7 w-7 rounded-md bg-brand-500" />
          <div>
            <div className="font-display text-base font-bold leading-tight">AI Gateway Console</div>
            <div className="text-[11px] text-slate-400">Red Hat Connectivity Link × Praxis AI · demo 15, Part F</div>
          </div>
        </div>
        <div className="flex flex-wrap items-center gap-3 text-xs">
          {cfg && (
            <span className={`chip ${cfg.openai === 'set' ? 'bg-emerald-900 text-emerald-200' : 'bg-amber-900 text-amber-200'}`}>
              OpenAI key {cfg.openai === 'set' ? 'set' : 'not set'}
            </span>
          )}
          <span className="text-slate-400">calling as</span>
          <div className="flex overflow-hidden rounded-lg border border-slate-700">
            {(cfg?.consumers || [{ name: 'alice', tier: 'free' }, { name: 'bob', tier: 'gold' }]).map((c) => (
              <button key={c.name} onClick={() => setConsumer(c.name)}
                className={`px-3 py-1.5 ${consumer === c.name ? 'bg-white text-slate-900' : 'text-slate-300 hover:bg-slate-800'}`}>
                {c.name} <span className={`ml-1 ${c.tier === 'gold' ? 'text-amber-500' : 'text-slate-400'}`}>{c.tier}</span>
              </button>
            ))}
          </div>
          <button className="btn border border-slate-700 text-slate-200 hover:bg-slate-800" title="RateLimitPolicy 5/s, Praxis 5/s burst 5, tokens 500 / 20000"
            onClick={() => api.reset().then(reload)}>Reset limits</button>
        </div>
      </header>
      {err && <div className="bg-rose-100 px-5 py-2 text-sm text-rose-800">Backend: {err}</div>}
      <div className="flex flex-1">
        <nav className="hidden w-60 shrink-0 border-r border-slate-200 bg-white p-3 md:block">
          {groups.map((g) => (
            <div key={g} className="mb-4">
              <div className="label mb-1 px-2">{g}</div>
              {PAGES.filter((p) => p.group === g).map((p) => (
                <button key={p.id} onClick={() => setPage(p.id)}
                  className={`block w-full rounded-lg px-2 py-1.5 text-left text-sm ${page === p.id ? 'bg-slate-900 font-medium text-white' : 'text-slate-700 hover:bg-slate-100'}`}>
                  {p.label}
                </button>
              ))}
            </div>
          ))}
          {cfg && (
            <div className="mt-6 space-y-1 border-t border-slate-200 px-2 pt-3 text-[11px] text-slate-500">
              <div>gateway</div><div className="break-all font-mono text-slate-700">{cfg.gateway}</div>
              <div className="pt-1">namespace</div><div className="font-mono text-slate-700">{cfg.namespace}</div>
            </div>
          )}
        </nav>
        <main className="min-w-0 flex-1 p-5 pb-24">
          <select className="input mb-4 w-full md:hidden" value={page} onChange={(e) => setPage(e.target.value)}>
            {PAGES.map((p) => <option key={p.id} value={p.id}>{p.group} · {p.label}</option>)}
          </select>
          <P.C consumer={consumer} cfg={cfg} reload={reload} />
        </main>
      </div>
      <div className="fixed bottom-0 left-0 right-0 z-10 border-t border-slate-300 bg-white/95 backdrop-blur">
        <button onClick={() => setShowLedger((s) => !s)} className="w-full px-5 py-2 text-left text-xs font-medium text-slate-600 hover:bg-slate-50">
          {showLedger ? '▾' : '▸'} Request ledger (who · API · model · status · latency · tokens)
        </button>
        {showLedger && <div className="px-5 pb-3"><LedgerTable rows={ledger} max={25} /></div>}
      </div>
    </div>
  )
}
