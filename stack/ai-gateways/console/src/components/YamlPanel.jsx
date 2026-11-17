import React, { useEffect, useState } from 'react'
import { api } from '../api.js'

// Minimal YAML colouring: comments, keys, strings. Enough to read a policy on a projector.
function colour(line) {
  const out = []
  let rest = line
  const hash = rest.search(/(^|\s)#/)
  let comment = ''
  if (hash >= 0 && !/["'][^"']*#/.test(rest.slice(0, hash + 1))) {
    comment = rest.slice(hash)
    rest = rest.slice(0, hash)
  }
  const m = rest.match(/^(\s*-?\s*)([\w.\-/"]+)(:)(.*)$/)
  if (m) {
    out.push(<span key="i">{m[1]}</span>, <span key="k" className="text-sky-300">{m[2]}</span>, <span key="c">{m[3]}</span>)
    out.push(<span key="v" className={/^\s*["']/.test(m[4]) ? 'text-emerald-300' : 'text-amber-100'}>{m[4]}</span>)
  } else {
    out.push(<span key="r" className="text-amber-100">{rest}</span>)
  }
  if (comment) out.push(<span key="cm" className="text-slate-400 italic">{comment}</span>)
  return out
}

export function Yaml({ code, focus = [] }) {
  const lines = code.split('\n')
  return (
    <pre className="overflow-x-auto rounded-lg bg-slate-900 py-3 text-[12px] leading-[1.55] text-slate-100">
      {lines.map((l, i) => {
        const hit = focus.some((f) => l.includes(f))
        return (
          <div key={i} className={`px-3 ${hit ? 'border-l-4 border-brand-500 bg-brand-500/15 pl-2' : 'border-l-4 border-transparent pl-2'}`}>
            <span className="mr-3 inline-block w-5 select-none text-right text-slate-500">{i + 1}</span>
            {colour(l)}
          </div>
        )
      })}
    </pre>
  )
}

export default function YamlPanel({ snippets, refreshKey = 0 }) {
  const [tab, setTab] = useState(0)
  const [live, setLive] = useState(false)
  const [liveCode, setLiveCode] = useState('')
  const [err, setErr] = useState('')
  const s = snippets[Math.min(tab, snippets.length - 1)]

  useEffect(() => {
    if (!live || !s.live) return
    setErr('')
    setLiveCode('loading…')
    api.yaml(s.live).then((r) => setLiveCode(r.yaml)).catch((e) => setErr(e.message))
  }, [live, s, refreshKey])

  return (
    <div className="card flex flex-col overflow-hidden">
      <div className="flex items-center justify-between gap-2 border-b border-slate-200 bg-slate-50 px-3 py-2">
        <span className="font-display text-sm font-bold text-slate-800">The YAML that does this</span>
        {s.live && (
          <label className="flex cursor-pointer items-center gap-2 text-xs text-slate-600">
            <input type="checkbox" checked={live} onChange={(e) => setLive(e.target.checked)} />
            live from the cluster
          </label>
        )}
      </div>
      <div className="flex flex-wrap gap-1 border-b border-slate-200 px-2 py-1.5">
        {snippets.map((x, i) => (
          <button key={x.title} onClick={() => setTab(i)}
            className={`rounded-md px-2 py-1 text-xs ${i === tab ? 'bg-slate-900 text-white' : 'text-slate-600 hover:bg-slate-100'}`}>
            {x.title}
          </button>
        ))}
      </div>
      <div className="space-y-2 p-3">
        <div className="flex flex-wrap items-center gap-2 text-xs">
          <span className={`chip ${s.owner.startsWith('Praxis') ? 'bg-violet-100 text-violet-800' : 'bg-sky-100 text-sky-800'}`}>{s.owner}</span>
          <span className="font-mono text-slate-500">{s.file}</span>
        </div>
        <p className="text-xs leading-relaxed text-slate-600">{s.why}</p>
        {err && <p className="font-mono text-xs text-rose-700">{err}</p>}
        {live && s.live ? <Yaml code={liveCode} focus={s.focus} /> : <Yaml code={s.code} focus={s.focus} />}
      </div>
    </div>
  )
}
