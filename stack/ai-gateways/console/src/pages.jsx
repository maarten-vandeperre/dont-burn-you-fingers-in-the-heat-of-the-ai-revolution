import React, { useEffect, useState } from 'react'
import { api } from './api.js'
import { S } from './snippets.js'
import YamlPanel from './components/YamlPanel.jsx'
import { ResultCard, Section, Status, Story, Where, explainStatus, statusTone } from './components/ui.jsx'

function Layout({ title, where, story, children, snippets, refreshKey }) {
  return (
    <div className="space-y-4">
      <div className="space-y-2">
        <h2 className="font-display text-2xl font-bold text-slate-900">{title}</h2>
        <Where items={where} />
        <Story>{story}</Story>
      </div>
      <div className="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <div className="space-y-4">{children}</div>
        <YamlPanel snippets={snippets} refreshKey={refreshKey} />
      </div>
    </div>
  )
}

const MODELS = ['qwen3-0-6b', 'gemma-3-270m-it', 'fast', 'smart', 'cloud', 'gpt-4o-mini', 'gpt-5']

// ===================================================================================== overview
export function Overview({ cfg }) {
  const rows = [
    ['Model routing', 'Praxis', 'model_to_provider: model or alias → cluster + model name', 'praxis-ai.yaml · model-routing'],
    ['Local model vs OpenAI', 'Praxis', 'same API, upstream qwen / gemma (KServe) or api.openai.com; key injected', 'praxis-ai.yaml · openai'],
    ['Block OpenAI on coffee, lemons, email', 'Praxis', 'guardrails filter on the egress listener → 403', 'praxis-ai.yaml · openai-guardrails'],
    ['Throttle 5 req/s (and change it)', 'Connectivity Link + Praxis', 'RateLimitPolicy per consumer · rate_limit per listener', 'api-policies.yaml · praxis-ai.yaml'],
    ['Token limits', 'Connectivity Link', 'TokenRateLimitPolicy: usage.total_tokens per consumer, per tier', 'api-policies.yaml'],
    ['API versioning', 'Connectivity Link', 'HTTPRoutes /v1, /v2, x-api-version header, Deprecation/Sunset', 'api-routes.yaml'],
    ['Who may use OpenAI', 'both', 'AuthPolicy injects x-consumer-tier, Praxis gates on it', 'api-policies.yaml · tier-gate'],
    ['Confidential data stays local', 'Praxis', 'x-data-classification: confidential → in-house model', 'praxis-ai.yaml · data-classification'],
    ['Metrics: who, which API/model, latency, tokens', 'both', 'TelemetryPolicy (user, tier) · Praxis token_count', 'api-policies.yaml · deployment.yaml'],
  ]
  return (
    <div className="space-y-5">
      <div className="space-y-2">
        <h2 className="font-display text-2xl font-bold">Connectivity Link × Praxis AI: one LLM API, two gateways, each doing what it is good at</h2>
        <Story>
          Connectivity Link knows <b>who</b> is calling (API keys, tiers) and counts <b>requests and tokens</b> per consumer.
          It cannot read the request body. Praxis AI reads the body: it knows <b>which model</b> is asked and <b>what is in the prompt</b>,
          but not who is calling. Put Connectivity Link in front and let it pass the identity on as headers, and each scenario below
          is a few lines of YAML in the right place.
        </Story>
      </div>
      <Diagram cfg={cfg} />
      <div className="card overflow-hidden">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
            <tr><th className="px-3 py-2">Scenario</th><th className="px-3 py-2">Where</th><th className="px-3 py-2">How</th><th className="px-3 py-2">YAML</th></tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r[0]} className="border-t border-slate-100">
                <td className="px-3 py-2 font-medium">{r[0]}</td>
                <td className="px-3 py-2"><span className={`chip ${r[1] === 'Praxis' ? 'bg-violet-100 text-violet-800' : r[1] === 'both' ? 'bg-slate-200 text-slate-800' : 'bg-sky-100 text-sky-800'}`}>{r[1]}</span></td>
                <td className="px-3 py-2 text-slate-600">{r[2]}</td>
                <td className="px-3 py-2 font-mono text-xs text-slate-500">{r[3]}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

function Box({ title, sub, tone, children }) {
  const tones = { sky: 'border-sky-300 bg-sky-50', violet: 'border-violet-300 bg-violet-50', slate: 'border-slate-300 bg-white', emerald: 'border-emerald-300 bg-emerald-50', rose: 'border-rose-300 bg-rose-50' }
  return (
    <div className={`rounded-xl border-2 p-3 ${tones[tone]}`}>
      <div className="font-display text-sm font-bold">{title}</div>
      {sub && <div className="font-mono text-[11px] text-slate-500">{sub}</div>}
      {children && <div className="mt-2 space-y-1 text-xs text-slate-700">{children}</div>}
    </div>
  )
}
const Arrow = ({ label }) => (
  <div className="flex flex-col items-center justify-center px-1 text-[10px] text-slate-500">
    <span className="hidden lg:block">{label}</span>
    <span className="text-xl leading-none text-slate-400 lg:rotate-0">→</span>
  </div>
)
function Diagram({ cfg }) {
  return (
    <div className="card p-4">
      <div className="grid items-stretch gap-2 lg:grid-cols-[1fr_auto_1.4fr_auto_1.4fr_auto_1fr]">
        <Box title="Client" sub="this console, as alice / bob" tone="slate">
          <div>Authorization: APIKEY sk-llm-…</div>
          <div>POST /v1 or /v2/chat/completions</div>
          <div>{'{"model": "smart", …}'}</div>
        </Box>
        <Arrow label="HTTPS" />
        <Box title="Connectivity Link · llm-gateway" sub={cfg?.gateway?.replace('https://', '') || 'llm-gateway.<apps>'} tone="sky">
          <div>HTTPRoute llm-api-v1 → :8084, llm-api-v2 → :8085</div>
          <div>AuthPolicy: API key → <b>x-consumer, x-consumer-tier</b></div>
          <div>RateLimitPolicy: <b>{cfg?.knobs?.cl?.limit ?? 5} req/s</b> per consumer</div>
          <div>TokenRateLimitPolicy: free {cfg?.knobs?.tokens?.free ?? 500} / gold {cfg?.knobs?.tokens?.gold ?? 20000} tok/min</div>
          <div>TelemetryPolicy: metrics per user, tier</div>
        </Box>
        <Arrow label="+ identity headers" />
        <Box title="Praxis AI" sub="api-v1 :8084 · api-v2 :8085" tone="violet">
          <div>model_to_header · aliases fast / smart / cloud</div>
          <div>tier gate (gold → OpenAI) · confidential → local</div>
          <div>model_to_provider → cluster</div>
          <div>token_count, time_to_first_token</div>
          <div className="mt-1 rounded-md border border-violet-300 bg-white p-1.5">openai-egress 127.0.0.1:8086: <b>guardrails</b> (coffee, lemons, email) + key injection</div>
        </Box>
        <Arrow label="TLS" />
        <div className="grid gap-2">
          <Box title="Local models" sub="KServe, maas-models" tone="emerald"><div>qwen3-0-6b</div><div>gemma-3-270m-it</div></Box>
          <Box title="OpenAI" sub="api.openai.com" tone="rose"><div>gpt-4o-mini</div><div>key: {cfg?.openai === 'set' ? 'set ✓' : 'not set'}</div></Box>
        </div>
      </div>
    </div>
  )
}

// ===================================================================================== model routing
export function ModelRouting({ consumer }) {
  const [prompt, setPrompt] = useState('In one short sentence: what is OpenShift?')
  const [rows, setRows] = useState({})
  const [busy, setBusy] = useState(false)
  const run = async (models) => {
    setBusy(true)
    for (const m of models) {
      setRows((r) => ({ ...r, [m]: { pending: true } }))
      const res = await api.chat({ consumer, api: 'v2', model: m, prompt, maxTokens: 40 }).catch((e) => ({ status: 0, error: e.message }))
      setRows((r) => ({ ...r, [m]: res }))
    }
    setBusy(false)
  }
  return (
    <Layout title="Model routing" where={['Praxis · api-v2', 'Connectivity Link · front door']}
      story="One URL for every model. The client names a model — or an alias like fast, smart or cloud — in the JSON body, and Praxis decides which backend answers and which model name that backend needs. Gateway API can't do this: it never reads the body."
      snippets={[S.modelRouting, S.classify, S.unknownModel, S.praxisListeners]}>
      <Section title={`Same prompt, every model name (as ${consumer}, POST /v2/chat/completions)`}
        right={<button className="btn-primary" disabled={busy} onClick={() => run(MODELS)}>{busy ? 'Sending…' : 'Send to all'}</button>}>
        <input className="input mb-3 w-full" value={prompt} onChange={(e) => setPrompt(e.target.value)} />
        <table className="w-full text-left text-sm">
          <thead className="text-xs text-slate-500"><tr><th className="py-1">model in body</th><th>→ served by</th><th>status</th><th>ms</th><th>tokens</th><th /></tr></thead>
          <tbody>
            {MODELS.map((m) => {
              const r = rows[m]
              return (
                <tr key={m} className="border-t border-slate-100 align-top">
                  <td className="py-1.5 font-mono text-xs">{m}</td>
                  <td className="font-mono text-xs text-indigo-700">{r?.modelServed || ''}</td>
                  <td>{r && !r.pending ? <Status s={r.status} /> : r?.pending ? '…' : ''}</td>
                  <td className="text-xs">{r?.ms ?? ''}</td>
                  <td className="text-xs">{r?.usage?.total_tokens ?? ''}</td>
                  <td className="text-right"><button className="btn-ghost !px-2 !py-0.5 text-xs" disabled={busy} onClick={() => run([m])}>send</button></td>
                </tr>
              )
            })}
          </tbody>
        </table>
        <div className="mt-3 space-y-1 text-xs text-slate-500">
          {MODELS.filter((m) => rows[m] && !rows[m].pending && rows[m].status !== 200).map((m) => <div key={m}><span className="font-mono">{m}</span>: {explainStatus(rows[m])}</div>)}
        </div>
      </Section>
      <p className="text-xs text-slate-500">Tip: <span className="font-mono">cloud</span> and <span className="font-mono">gpt-4o-mini</span> need the gold tier (bob) — see “Who may use OpenAI”.</p>
    </Layout>
  )
}

// ===================================================================================== local vs openai
export function LocalVsOpenAI({ consumer, cfg }) {
  const [prompt, setPrompt] = useState('Explain in two sentences why a company would run an LLM on its own platform.')
  const [confidential, setConfidential] = useState(false)
  const [res, setRes] = useState({})
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true); setRes({})
    const cls = confidential ? 'confidential' : undefined
    const [a, b] = await Promise.all([
      api.chat({ consumer, api: 'v2', model: 'smart', prompt, maxTokens: 120, classification: cls }).catch((e) => ({ status: 0, error: e.message })),
      api.chat({ consumer, api: 'v2', model: 'gpt-4o-mini', prompt, maxTokens: 120, classification: cls }).catch((e) => ({ status: 0, error: e.message })),
    ])
    setRes({ a, b }); setBusy(false)
  }
  return (
    <Layout title="Routing to a local model versus OpenAI" where={['Praxis · model-routing', 'Praxis · openai-egress']}
      story="Same API, same client code: “smart” is the in-house Qwen on OpenShift AI, “gpt-4o-mini” goes out to OpenAI with a key only Praxis knows. Mark the request confidential and it never leaves the cluster, whatever model was asked."
      snippets={[S.modelRouting, S.openai, S.confidential, S.openaiKey]}>
      {cfg?.openai !== 'set' && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
          No OpenAI key configured yet: OpenAI calls end in <b>401</b> from api.openai.com (the path through Praxis still works). Set it with
          <code className="mx-1 rounded bg-white px-1">export OPENAI_API_KEY=sk-… && ./deploy.sh ai-gateways openai-key</code>
        </div>
      )}
      <Section title={`Side by side, as ${consumer}`} right={<button className="btn-primary" disabled={busy} onClick={run}>{busy ? 'Asking both…' : 'Ask both'}</button>}>
        <textarea className="input mb-2 h-20 w-full" value={prompt} onChange={(e) => setPrompt(e.target.value)} />
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={confidential} onChange={(e) => setConfidential(e.target.checked)} />
          send <code className="rounded bg-slate-100 px-1 text-xs">x-data-classification: confidential</code>
        </label>
        {consumer !== 'bob' && <p className="mt-2 text-xs text-amber-700">{consumer} is not gold: the OpenAI side will get the tier gate's 403. Switch to bob (top right) for OpenAI.</p>}
      </Section>
      <div className="grid gap-3 md:grid-cols-2">
        <ResultCard r={res.a} title="model: smart (local)" />
        <ResultCard r={res.b} title="model: gpt-4o-mini (OpenAI)" />
      </div>
    </Layout>
  )
}

// ===================================================================================== guardrails
const GUARD_PROMPTS = [
  ['clean', 'Give me one tip for writing good API documentation.'],
  ['coffee', 'What is the best way to brew coffee for a team of ten?'],
  ['lemons', 'I have three lemons, what can I bake?'],
  ['email', 'Write a short reply to jane.doe@acme.com thanking her for the meeting.'],
]
export function Guardrails({ consumer }) {
  const [rows, setRows] = useState({})
  const [custom, setCustom] = useState('Lemonade or coffee? Ask maarten@example.com')
  const [busy, setBusy] = useState(false)
  const runOne = async (label, prompt) => {
    setRows((r) => ({ ...r, [label]: { prompt, pending: true } }))
    const [o, l] = await Promise.all([
      api.chat({ consumer, api: 'v2', model: 'gpt-4o-mini', prompt, maxTokens: 30 }).catch((e) => ({ status: 0, error: e.message })),
      api.chat({ consumer, api: 'v2', model: 'fast', prompt, maxTokens: 30 }).catch((e) => ({ status: 0, error: e.message })),
    ])
    setRows((r) => ({ ...r, [label]: { prompt, o, l } }))
  }
  const runAll = async () => { setBusy(true); for (const [l, p] of GUARD_PROMPTS) await runOne(l, p); setBusy(false) }
  return (
    <Layout title="Block OpenAI calls about coffee, lemons or with email addresses" where={['Praxis · openai-egress (guardrails)']}
      story="Company policy: prompts about coffee or lemons, and anything containing an email address, must not go to OpenAI. The rule sits on the only path out to OpenAI, so it applies to every client and every alias that ends there — and to nothing that stays local."
      snippets={[S.guardrails, S.praxisListeners, S.openai]}>
      <Section title={`Each prompt to OpenAI (gpt-4o-mini) and to a local model (fast), as ${consumer}`}
        right={<button className="btn-primary" disabled={busy} onClick={runAll}>{busy ? 'Sending…' : 'Run all'}</button>}>
        {consumer !== 'bob' && <p className="mb-2 text-xs text-amber-700">Use bob (gold): for {consumer} the tier gate answers 403 before the guardrails are reached.</p>}
        <table className="w-full text-left text-sm">
          <thead className="text-xs text-slate-500"><tr><th className="py-1">prompt</th><th>OpenAI</th><th>local</th></tr></thead>
          <tbody>
            {[...GUARD_PROMPTS, ['custom', custom]].map(([label, p]) => {
              const r = rows[label]
              return (
                <tr key={label} className="border-t border-slate-100 align-top">
                  <td className="py-2 pr-2">
                    <span className="chip mr-1 bg-slate-100 text-slate-700">{label}</span>
                    <span className="text-xs text-slate-600">{p}</span>
                    <button className="btn-ghost ml-2 !px-2 !py-0.5 text-xs" disabled={busy} onClick={() => runOne(label, p)}>send</button>
                  </td>
                  <td className="w-44 py-2">{r?.o ? <><Status s={r.o.status} /> <div className="text-[11px] text-slate-500">{explainStatus(r.o)}</div></> : r?.pending ? '…' : ''}</td>
                  <td className="w-36 py-2">{r?.l ? <><Status s={r.l.status} /> <div className="text-[11px] text-slate-500">{explainStatus(r.l)}</div></> : r?.pending ? '…' : ''}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
        <input className="input mt-3 w-full" value={custom} onChange={(e) => setCustom(e.target.value)} placeholder="your own prompt (row: custom)" />
      </Section>
      <p className="text-xs text-slate-500">403 = Praxis refused before OpenAI saw a byte. 401 on the clean prompt = the request reached OpenAI but no key is configured yet.</p>
    </Layout>
  )
}

// ===================================================================================== throttle
export function Throttle({ consumer, cfg, reload }) {
  const [target, setTarget] = useState('cl')
  const [count, setCount] = useState(10)
  const [res, setRes] = useState(null)
  const [busy, setBusy] = useState(false)
  const [limit, setLimit] = useState(5)
  const [msg, setMsg] = useState('')
  const [rk, setRk] = useState(0)
  const cur = target === 'cl' ? cfg?.knobs?.cl?.limit : cfg?.knobs?.praxis?.rate
  useEffect(() => { if (cur) setLimit(cur) }, [cur, target])
  const fire = async () => { setBusy(true); setRes(await api.burst({ consumer, target, count }).catch((e) => ({ error: e.message }))); setBusy(false) }
  const apply = async () => {
    setMsg('applying…')
    try {
      await api.throttle({ target, limit, burst: limit })
      setMsg(target === 'cl' ? 'Patched. Kuadrant updates Limitador in a few seconds.' : 'ConfigMap patched and pod nudged: Praxis hot-reloads in ~5–30 s (watch: oc logs deploy/praxis-ai | grep "reload complete").')
      reload(); setRk((k) => k + 1)
    } catch (e) { setMsg(e.message) }
  }
  const ok = res?.results?.filter((r) => r.status === 200).length ?? 0
  const lim = res?.results?.filter((r) => r.status === 429).length ?? 0
  return (
    <Layout title="Throttle the API: max 5 requests per second, then change it" where={['Connectivity Link · RateLimitPolicy', 'Praxis · rate_limit']}
      story="Fire a burst of parallel requests at the model catalog (cheap, no model involved) and watch the limiter. Connectivity Link counts per consumer — alice and bob each get their own 5 per second. Praxis has one bucket for the whole listener. Change the number, fire again."
      snippets={target === 'cl' ? [S.rlp, S.auth] : [S.praxisThrottle]} refreshKey={rk}>
      <Section title="Burst">
        <div className="flex flex-wrap items-end gap-3">
          <div>
            <div className="label mb-1">limiter</div>
            <div className="flex overflow-hidden rounded-lg border border-slate-300">
              {[['cl', 'Connectivity Link (per consumer)'], ['praxis', 'Praxis (per listener)']].map(([k, l]) => (
                <button key={k} onClick={() => { setTarget(k); setRes(null) }} className={`px-3 py-1.5 text-sm ${target === k ? 'bg-slate-900 text-white' : 'bg-white text-slate-700'}`}>{l}</button>
              ))}
            </div>
          </div>
          <div>
            <div className="label mb-1">parallel requests: {count}</div>
            <input type="range" min="1" max="30" value={count} onChange={(e) => setCount(Number(e.target.value))} />
          </div>
          <button className="btn-primary" disabled={busy} onClick={fire}>{busy ? 'Firing…' : `Fire ${count}`}</button>
        </div>
        <p className="mt-2 font-mono text-[11px] text-slate-500">{target === 'cl' ? `GET ${cfg?.gateway || ''}/v2/models  (APIKEY of ${consumer})` : `GET ${cfg?.praxisLimited || ''}/v1/models  (no key)`}</p>
        {res?.results && (
          <div className="mt-3">
            <div className="mb-2 flex gap-3 text-sm"><span className="chip bg-emerald-100 text-emerald-800">{ok} × 200</span><span className="chip bg-amber-100 text-amber-800">{lim} × 429</span></div>
            <div className="flex flex-wrap gap-1.5">
              {res.results.map((r) => (
                <div key={r.i} title={`#${r.i} ${r.status} in ${r.ms} ms`} className={`flex h-10 w-12 flex-col items-center justify-center rounded-md text-[11px] font-semibold ${statusTone(r.status)}`}>
                  {r.status}<span className="text-[9px] font-normal">{r.ms}ms</span>
                </div>
              ))}
            </div>
          </div>
        )}
        {res?.error && <p className="mt-2 text-sm text-rose-700">{res.error}</p>}
      </Section>
      <Section title={target === 'cl' ? 'Change the RateLimitPolicy' : 'Change the Praxis rate_limit'}>
        <div className="flex flex-wrap items-center gap-3">
          <span className="text-sm">current: <b>{target === 'cl' ? `${cfg?.knobs?.cl?.limit} / ${cfg?.knobs?.cl?.window}` : `rate ${cfg?.knobs?.praxis?.rate}/s, burst ${cfg?.knobs?.praxis?.burst}`}</b></span>
          <input type="number" min="1" max="100" className="input w-20" value={limit} onChange={(e) => setLimit(Number(e.target.value))} />
          <span className="text-sm text-slate-500">requests / second</span>
          <button className="btn-dark" onClick={apply}>Apply</button>
        </div>
        {msg && <p className="mt-2 text-xs text-slate-600">{msg}</p>}
      </Section>
    </Layout>
  )
}

// ===================================================================================== tokens
export function Tokens({ consumer, cfg, reload }) {
  const [log, setLog] = useState([])
  const [busy, setBusy] = useState(false)
  const [free, setFree] = useState(500)
  const [gold, setGold] = useState(20000)
  const [msg, setMsg] = useState('')
  const [rk, setRk] = useState(0)
  useEffect(() => { if (cfg?.knobs?.tokens) { setFree(cfg.knobs.tokens.free); setGold(cfg.knobs.tokens.gold) } }, [cfg])
  const tier = cfg?.consumers?.find((c) => c.name === consumer)?.tier
  const max = tier === 'gold' ? cfg?.knobs?.tokens?.gold : cfg?.knobs?.tokens?.free
  const recent = log.filter((l) => l.consumer === consumer && Date.now() - l.at < 60_000)
  const used = recent.reduce((a, l) => a + (l.tokens || 0), 0)
  const one = async () => {
    const r = await api.chat({ consumer, api: 'v2', model: 'fast', prompt: 'Tell me about OpenShift in a few sentences.', maxTokens: 80 }).catch((e) => ({ status: 0, error: e.message }))
    setLog((l) => [{ at: Date.now(), consumer, status: r.status, tokens: r.usage?.total_tokens || 0, ms: r.ms }, ...l].slice(0, 40))
    return r
  }
  const untilLimited = async () => { setBusy(true); for (let i = 0; i < 15; i++) { const r = await one(); if (r.status === 429) break } setBusy(false) }
  const apply = async (t, v) => {
    setMsg('applying…')
    try { await api.tokens({ tier: t, limit: v }); setMsg(`api-${t} set to ${v} tokens/min. The counter itself keeps running for the current minute.`); reload(); setRk((k) => k + 1) } catch (e) { setMsg(e.message) }
  }
  const pct = max ? Math.min(100, (used / max) * 100) : 0
  return (
    <Layout title="Token limitation" where={['Connectivity Link · TokenRateLimitPolicy']}
      story="Requests are a bad proxy for cost: one request can be 10 tokens or 10 000. Connectivity Link reads usage.total_tokens from every answer and charges it to the caller. alice (free) gets 500 tokens per minute, bob (gold) 20 000. The request that crosses the line still succeeds; the next one gets 429."
      snippets={[S.trlp, S.auth, S.consumerKey]} refreshKey={rk}>
      <Section title={`${consumer} (${tier}) — ~90-token requests to model "fast"`}
        right={<div className="flex gap-2"><button className="btn-ghost" disabled={busy} onClick={() => { setBusy(true); one().finally(() => setBusy(false)) }}>Send one</button><button className="btn-primary" disabled={busy} onClick={untilLimited}>{busy ? 'Sending…' : 'Send until limited'}</button></div>}>
        <div className="mb-1 flex justify-between text-xs text-slate-600"><span>tokens in the last 60 s (from the answers' usage)</span><span><b>{used}</b> / {max ?? '?'}</span></div>
        <div className="h-3 overflow-hidden rounded-full bg-slate-200"><div className={`h-full ${pct >= 100 ? 'bg-amber-500' : 'bg-emerald-500'}`} style={{ width: `${pct}%` }} /></div>
        <div className="mt-3 flex flex-wrap gap-1.5">
          {log.filter((l) => l.consumer === consumer).map((l, i) => (
            <div key={i} className={`rounded-md px-2 py-1 text-[11px] font-semibold ${statusTone(l.status)}`}>{l.status}{l.tokens ? ` · ${l.tokens} tok` : ''}</div>
          ))}
        </div>
        <p className="mt-2 text-[11px] text-slate-500">Limitador's window is fixed (1 minute from the first hit), so the bar is an approximation; the 429 is the truth.</p>
      </Section>
      <Section title="Change the limits (TokenRateLimitPolicy llm-api-tokens)">
        <div className="flex flex-wrap items-center gap-3 text-sm">
          <span className="w-14">free</span><input type="number" className="input w-28" value={free} onChange={(e) => setFree(Number(e.target.value))} />
          <button className="btn-dark" onClick={() => apply('free', free)}>Apply</button>
        </div>
        <div className="mt-2 flex flex-wrap items-center gap-3 text-sm">
          <span className="w-14">gold</span><input type="number" className="input w-28" value={gold} onChange={(e) => setGold(Number(e.target.value))} />
          <button className="btn-dark" onClick={() => apply('gold', gold)}>Apply</button>
        </div>
        {msg && <p className="mt-2 text-xs text-slate-600">{msg}</p>}
      </Section>
    </Layout>
  )
}

// ===================================================================================== versioning
const VERSIONS = [
  ['v1', 'POST /v1/chat/completions'],
  ['v1-header', 'POST /v1/chat/completions + x-api-version: 2'],
  ['v2', 'POST /v2/chat/completions'],
]
export function Versioning({ consumer }) {
  const [model, setModel] = useState('gemma-3-270m-it')
  const [res, setRes] = useState({})
  const [busy, setBusy] = useState(false)
  const run = async () => {
    setBusy(true); setRes({})
    for (const [v] of VERSIONS) {
      const r = await api.chat({ consumer, api: v, model, prompt: 'Say hi in five words.', maxTokens: 20 }).catch((e) => ({ status: 0, error: e.message }))
      setRes((x) => ({ ...x, [v]: r }))
    }
    setBusy(false)
  }
  return (
    <Layout title="API versioning" where={['Connectivity Link · HTTPRoutes', 'Praxis · listeners api-v1 / api-v2']}
      story="v1 is the API teams already use: local models, exact names. v2 adds aliases and OpenAI. Both live side by side on the same host: v1 clients keep working and are told, in every response, that v1 is deprecated and when it will be switched off. Clients that cannot change their URL opt in with a header."
      snippets={[S.routes, S.praxisListeners]}>
      <Section title={`Same request, three ways in (as ${consumer})`} right={<button className="btn-primary" disabled={busy} onClick={run}>{busy ? 'Sending…' : 'Send'}</button>}>
        <div className="mb-3 flex flex-wrap items-center gap-2 text-sm">
          model in body:
          {['gemma-3-270m-it', 'fast', 'cloud'].map((m) => (
            <button key={m} onClick={() => setModel(m)} className={`chip !text-xs ${model === m ? 'bg-slate-900 text-white' : 'bg-slate-100 text-slate-700'}`}>{m}</button>
          ))}
        </div>
        <div className="space-y-3">
          {VERSIONS.map(([v, label]) => {
            const r = res[v]
            return (
              <div key={v} className="rounded-lg border border-slate-200 p-3">
                <div className="mb-1 flex flex-wrap items-center gap-2">
                  <span className="font-mono text-xs font-semibold">{label}</span>
                  {r && <Status s={r.status} />}
                  {r?.responseHeaders?.['x-api-version'] && <span className="chip bg-sky-100 text-sky-800">served by v{r.responseHeaders['x-api-version']}</span>}
                  {r && <span className="text-xs text-slate-500">{explainStatus(r)}</span>}
                </div>
                {r && (
                  <div className="space-y-0.5 font-mono text-[11px] text-slate-600">
                    {['deprecation', 'sunset', 'link'].filter((h) => r.responseHeaders?.[h]).map((h) => (
                      <div key={h}><span className="text-rose-700">{h}:</span> {r.responseHeaders[h]}</div>
                    ))}
                    {r.answer && <div className="font-sans text-xs text-slate-800">{r.answer}</div>}
                    {!r.answer && r.error && <div className="text-rose-700">{String(r.error).slice(0, 160)}</div>}
                  </div>
                )}
              </div>
            )
          })}
        </div>
      </Section>
      <p className="text-xs text-slate-500">Try “fast”: v1 answers 404 (no aliases in v1), v2 and the header variant route it to Gemma.</p>
    </Layout>
  )
}

// ===================================================================================== identity
export function Identity() {
  const [res, setRes] = useState({})
  const [busy, setBusy] = useState(false)
  const cases = [
    ['alice', 'alice (free) asks cloud', {}],
    ['bob', 'bob (gold) asks cloud', {}],
    ['alice', 'alice + x-consumer-tier: gold (spoof)', { spoof: true }],
  ]
  const run = async () => {
    setBusy(true); setRes({})
    for (const [who, label, o] of cases) {
      // the spoof case: the client sends x-consumer-tier: gold itself; the AuthPolicy overwrites it
      const r = await api.chat({ consumer: who, api: 'v2', model: 'cloud', prompt: 'Say hi in five words.', maxTokens: 20, ...(o.spoof ? { spoofTier: 'gold' } : {}) })
        .catch((e) => ({ status: 0, error: e.message }))
      setRes((x) => ({ ...x, [label]: r }))
    }
    setBusy(false)
  }
  return (
    <Layout title="Who may use OpenAI: identity-aware routing" where={['Connectivity Link · AuthPolicy (who)', 'Praxis · tier-gate (what)']}
      story="OpenAI costs money, so only gold consumers may use it. That decision needs WHO is calling (only Connectivity Link knows: the API key) and WHAT is asked (only Praxis knows: the model in the body). The AuthPolicy passes the tier on as a header it writes itself; Praxis decides on it."
      snippets={[S.tierGate, S.auth, S.consumerKey]}>
      <Section title="Three callers, model: cloud" right={<button className="btn-primary" disabled={busy} onClick={run}>{busy ? 'Sending…' : 'Run'}</button>}>
        <div className="space-y-2">
          {cases.map(([, label]) => (
            <div key={label} className="flex flex-wrap items-center gap-2 rounded-lg border border-slate-200 p-2 text-sm">
              <span className="w-72 font-medium">{label}</span>
              {res[label] && <><Status s={res[label].status} /><span className="text-xs text-slate-500">{explainStatus(res[label])}</span></>}
            </div>
          ))}
        </div>
        <p className="mt-3 text-xs text-slate-500">
          The spoof row: a client-sent <code>x-consumer-tier: gold</code> is overwritten by the AuthPolicy's <code>response.success.headers</code> with alice's real tier, so she still gets 403.
          Try it by hand: <code className="break-all">curl $G/v2/chat/completions -H "Authorization: APIKEY $KEY_ALICE" -H "x-consumer-tier: gold" …</code>
        </p>
      </Section>
    </Layout>
  )
}

// ===================================================================================== metrics
function shortUser(u) { return (u || '').replace(/^llm-key-/, '') }
function shortRoute(r) { return (r || '').replace(/^ai-gateways\//, '') }
export function Metrics({ cfg }) {
  const [m, setM] = useState(null)
  const [ledger, setLedger] = useState([])
  const [gen, setGen] = useState('')
  const load = () => { api.metrics().then(setM).catch(() => {}); api.ledger().then(setLedger).catch(() => {}) }
  useEffect(() => { load(); const t = setInterval(load, 5000); return () => clearInterval(t) }, [])
  const traffic = async () => {
    const plan = [
      ['alice', 'v1', 'gemma-3-270m-it'], ['bob', 'v2', 'smart'], ['alice', 'v2', 'fast'], ['bob', 'v2', 'cloud'],
      ['bob', 'v1', 'qwen3-0-6b'], ['alice', 'v2', 'cloud'], ['bob', 'v2', 'fast'], ['alice', 'v1-header', 'fast'],
    ]
    for (let i = 0; i < plan.length; i++) {
      setGen(`${i + 1}/${plan.length}`)
      const [c, a, mo] = plan[i]
      await api.chat({ consumer: c, api: a, model: mo, prompt: 'One sentence about Kubernetes.', maxTokens: 40 }).catch(() => {})
      load()
    }
    setGen('done — Prometheus scrapes every 15–30 s')
  }
  const r = m?.results || {}
  const byUser = {}
  for (const x of r.consumerCalls || []) { const k = `${x.labels.user}|${x.labels.limitador_namespace}`; byUser[k] = { ...(byUser[k] || {}), user: x.labels.user, tier: x.labels.tier, route: x.labels.limitador_namespace, calls: x.value } }
  for (const x of r.consumerLimited || []) { const k = `${x.labels.user}|${x.labels.limitador_namespace}`; byUser[k] = { ...(byUser[k] || {}), user: x.labels.user, tier: x.labels.tier, route: x.labels.limitador_namespace, limited: x.value } }
  for (const x of r.consumerHits || []) { const k = `${x.labels.user}|${x.labels.limitador_namespace}`; byUser[k] = { ...(byUser[k] || {}), user: x.labels.user, tier: x.labels.tier, route: x.labels.limitador_namespace, hits: x.value } }
  const models = {}
  for (const x of r.modelPromptTokens || []) models[x.labels.model] = { ...(models[x.labels.model] || {}), prompt: x.value }
  for (const x of r.modelOutputTokens || []) models[x.labels.model] = { ...(models[x.labels.model] || {}), output: x.value }
  const lat = Object.fromEntries((r.clusterLatency || []).map((x) => [x.labels.cluster, x.value]))
  const reqs = {}
  for (const x of r.clusterRequests || []) reqs[x.labels.cluster] = { ...(reqs[x.labels.cluster] || {}), [x.labels.status_class]: x.value }
  const fmt = (v, d = 0) => (v == null || Number.isNaN(v) ? '–' : Number(v).toFixed(d))
  return (
    <Layout title="Metrics: who calls which API and model, how fast, how many tokens" where={['Connectivity Link · TelemetryPolicy + Limitador', 'Praxis · token_count, latency', 'Envoy · gateway latency']}
      story="Connectivity Link knows the consumer and the API version (route), Praxis knows the model and the upstream latency. Both land in OpenShift's Prometheus; the ledger at the bottom joins them per request, as the console saw it."
      snippets={[S.telemetry, S.praxisMetrics]}>
      <Section title="Generate some traffic" right={<button className="btn-primary" onClick={traffic}>Mixed traffic (8 calls)</button>}>
        <p className="text-xs text-slate-500">alice and bob, v1 / v2 / header, local and OpenAI. {gen}</p>
      </Section>
      <Section title="Per consumer and API version — Limitador (Connectivity Link)">
        <table className="w-full text-left text-sm">
          <thead className="text-xs text-slate-500"><tr><th className="py-1">consumer</th><th>tier</th><th>API (route)</th><th>allowed calls</th><th>429</th><th>hits charged</th></tr></thead>
          <tbody>
            {Object.values(byUser).sort((a, b) => (a.user + a.route).localeCompare(b.user + b.route)).map((x) => (
              <tr key={x.user + x.route} className="border-t border-slate-100">
                <td className="py-1 font-medium">{shortUser(x.user)}</td><td className="text-xs">{x.tier}</td>
                <td className="font-mono text-xs">{shortRoute(x.route)}</td><td>{fmt(x.calls)}</td><td>{fmt(x.limited)}</td><td>{fmt(x.hits)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="mt-2 text-[11px] text-slate-500">Counters since Limitador started. “hits charged” = tokens (TokenRateLimitPolicy) + 1 per request (RateLimitPolicy) + 1 per check.</p>
      </Section>
      <div className="grid gap-4 md:grid-cols-2">
        <Section title="Per model — Praxis tokens">
          <table className="w-full text-left text-sm">
            <thead className="text-xs text-slate-500"><tr><th className="py-1">model (as asked)</th><th>prompt</th><th>output</th></tr></thead>
            <tbody>{Object.entries(models).map(([k, v]) => <tr key={k} className="border-t border-slate-100"><td className="py-1 font-mono text-xs">{k}</td><td>{fmt(v.prompt)}</td><td>{fmt(v.output)}</td></tr>)}</tbody>
          </table>
          <p className="mt-2 text-[11px] text-slate-500">Labelled with the name the client used, so aliases (fast, smart, cloud) show up as their own rows: who uses the alias vs the exact model.</p>
        </Section>
        <Section title="Per upstream cluster — Praxis latency">
          <table className="w-full text-left text-sm">
            <thead className="text-xs text-slate-500"><tr><th className="py-1">cluster</th><th>avg</th><th>2xx</th><th>4xx</th><th>5xx</th></tr></thead>
            <tbody>{Object.entries(reqs).filter(([k]) => k && k !== '-' && k !== 'none').map(([k, v]) => <tr key={k} className="border-t border-slate-100"><td className="py-1 font-mono text-xs">{k}</td><td>{fmt((lat[k] || 0) * 1000)} ms</td><td>{fmt(v['2xx'])}</td><td>{fmt(v['4xx'])}</td><td>{fmt(v['5xx'])}</td></tr>)}</tbody>
          </table>
          <p className="mt-2 text-[11px] text-slate-500">openai-egress = the hop into the guardrails listener (403s are fast), openai = api.openai.com itself.</p>
        </Section>
      </div>
      <Section title="Gateway (Envoy in llm-gateway) — p95 latency per backend, last 10 min; response codes, last 30 min">
        <div className="flex flex-wrap gap-6 text-sm">
          <div>{(r.gatewayP95 || []).filter((x) => !Number.isNaN(x.value)).map((x) => <div key={x.labels.destination_service_name}><span className="font-mono text-xs">{x.labels.destination_service_name}</span>: <b>{fmt(x.value)} ms</b></div>)}</div>
          <div className="flex flex-wrap gap-1.5">{(r.gatewayCodes || []).sort((a, b) => a.labels.response_code.localeCompare(b.labels.response_code)).map((x) => <span key={x.labels.response_code} className={`chip ${statusTone(Number(x.labels.response_code))}`}>{x.labels.response_code} × {fmt(x.value)}</span>)}</div>
        </div>
        <p className="mt-2 text-[11px] text-slate-500">Istio telemetry of the gateway's Envoy: end-to-end latency as the client sees it, including Praxis and the model (praxis-ai) or the model directly (llm-models routes).</p>
      </Section>
      <Section title="Ledger — every call the console made (consumer × API × model × latency × tokens)" right={<button className="btn-ghost text-xs" onClick={() => api.clearLedger().then(load)}>clear</button>}>
        <LedgerTable rows={ledger} />
      </Section>
      <details className="card p-3 text-xs">
        <summary className="cursor-pointer font-medium text-slate-700">PromQL used (paste into Observe → Metrics)</summary>
        <div className="mt-2 space-y-1 font-mono text-[11px] text-slate-600">
          {Object.entries(m?.queries || {}).map(([k, q]) => <div key={k}><span className="text-slate-400">{k}:</span> {q}</div>)}
        </div>
        {Object.keys(m?.errors || {}).length > 0 && <pre className="mt-2 text-rose-700">{JSON.stringify(m.errors, null, 1)}</pre>}
      </details>
    </Layout>
  )
}

export function LedgerTable({ rows, max = 60 }) {
  return (
    <div className="max-h-96 overflow-auto">
      <table className="w-full text-left text-xs">
        <thead className="sticky top-0 bg-white text-slate-500"><tr><th className="py-1">time</th><th>consumer</th><th>API</th><th>model asked → served</th><th>status</th><th>ms</th><th>tokens</th><th>note</th></tr></thead>
        <tbody>
          {rows.slice(0, max).map((l, i) => (
            <tr key={i} className="border-t border-slate-100">
              <td className="py-1 text-slate-500">{new Date(l.ts).toLocaleTimeString()}</td>
              <td>{l.consumer} <span className="text-slate-400">{l.tier}</span></td>
              <td className="font-mono">{l.api}</td>
              <td className="font-mono">{l.model}{l.served && l.served !== l.model ? <span className="text-indigo-700"> → {l.served}</span> : ''}</td>
              <td><Status s={l.status} /></td><td>{l.ms}</td><td>{l.tokens ?? ''}</td>
              <td className="text-slate-500">{l.note}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
