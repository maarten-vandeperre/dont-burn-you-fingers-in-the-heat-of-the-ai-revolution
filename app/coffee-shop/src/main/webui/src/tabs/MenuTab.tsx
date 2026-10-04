import { useState } from "react";
import { api, euro, type LiveMenu, type ProbeResult } from "../api";
import { Badge, Button, Card, ErrorBox, inputClass } from "../ui";

const SCENARIOS = [
  ["reset", "100% menu v1"],
  ["canary 20", "80% v1 / 20% v2"],
  ["blue / green", "all traffic to one version"],
  ["mirror", "v1 answers, v2 gets a shadow copy"],
  ["delay 50", "50% of calls +3 s"],
  ["abort 30", "30% of calls HTTP 503"],
];

export default function MenuTab() {
  const [n, setN] = useState(50);
  const [probe, setProbe] = useState<ProbeResult>();
  const [menu, setMenu] = useState<LiveMenu>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  async function run() {
    setBusy(true); setError(undefined);
    try { setProbe(await api.probe(n)); setMenu(await api.menu()); } catch (e) { setError((e as Error).message); } finally { setBusy(false); }
  }

  const ok = probe ? Object.values(probe.versions).reduce((a, b) => a + b, 0) : 0;

  return (
    <>
      <Card title="Menu service through the mesh"
        subtitle="Switch the scenario with ./deploy.sh app menu <name>, or in Developer Hub > Create > Coffee menu: traffic & chaos. Then probe.">
        <div className="grid gap-2 md:grid-cols-6">
          {SCENARIOS.map(([name, text]) => (
            <div key={name} className="rounded-lg border border-stone-200 p-2 text-xs"><code className="font-semibold">{name}</code><p className="mt-1 text-stone-500">{text}</p></div>
          ))}
        </div>
        <div className="mt-4 flex items-end gap-4">
          <label className="text-sm text-stone-600">calls
            <input type="number" min={1} max={300} className={`${inputClass} mt-1 w-28`} value={n} onChange={(e) => setN(Number(e.target.value))} />
          </label>
          <Button onClick={run} disabled={busy}>{busy ? "Probing..." : "Probe coffee-menu"}</Button>
        </div>
        <ErrorBox error={error} />
      </Card>

      {probe && (
        <div className="grid gap-6 md:grid-cols-2">
          <Card title="Raw calls (no fault tolerance)" subtitle={`${probe.requests} calls: what the mesh delivers`}>
            {Object.entries(probe.versions).map(([v, c]) => (
              <div key={v} className="mb-2">
                <div className="mb-1 flex justify-between text-sm"><span>menu {v}</span><span>{c} ({Math.round((c / probe.requests) * 100)}%)</span></div>
                <div className="h-3 rounded-full bg-stone-100"><div className={`h-3 rounded-full ${v === "v2" ? "bg-amber-500" : "bg-emerald-500"}`} style={{ width: `${(c / probe.requests) * 100}%` }} /></div>
              </div>
            ))}
            {Object.entries(probe.errors).map(([err, c]) => (
              <div key={err} className="mb-2">
                <div className="mb-1 flex justify-between text-sm text-red-700"><span>{err}</span><span>{c} ({Math.round((c / probe.requests) * 100)}%)</span></div>
                <div className="h-3 rounded-full bg-stone-100"><div className="h-3 rounded-full bg-red-500" style={{ width: `${(c / probe.requests) * 100}%` }} /></div>
              </div>
            ))}
            <p className="mt-3 text-sm text-stone-600">latency p50 {probe.p50Ms} ms · p95 {probe.p95Ms} ms · max {probe.maxMs} ms · {ok} ok</p>
          </Card>
          <Card title="What the shop uses" subtitle="timeout 1.5 s, 2 retries, circuit breaker, fallback to the last known menu"
            actions={menu && <Badge tone={menu.source === "live" ? "green" : "amber"}>{menu.source}</Badge>}>
            {menu && <>
              <p className="text-sm text-stone-600">menu {menu.version} from pod <code>{menu.pod}</code>{menu.source === "live" ? `, ${menu.elapsedMs} ms` : ""}</p>
              <ul className="mt-2 grid grid-cols-2 gap-1 text-sm">{menu.items.map((i) => <li key={i.drink}>{i.drink} · {euro(i.priceCents)}</li>)}</ul>
              <p className="mt-3 text-xs text-stone-400">With faults injected the raw calls fail, yet ordering keeps working: the shop answers from its cache.</p>
            </>}
          </Card>
        </div>
      )}
    </>
  );
}
