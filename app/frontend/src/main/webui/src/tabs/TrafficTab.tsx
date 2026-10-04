import { useState } from "react";
import { api, type TrafficResult } from "../api";
import { Button, Card, ErrorBox, inputClass } from "../ui";

const PATTERNS = [
  { name: "reset", text: "100% v1 (baseline)" },
  { name: "canary", text: "90% v1 / 10% v2" },
  { name: "ab", text: "x-variant: b -> v2, rest v1" },
  { name: "blue-green", text: "all traffic to one color, switch atomically" },
  { name: "mirror", text: "serve v1, shadow copy to v2" },
];

export default function TrafficTab() {
  const [n, setN] = useState(100);
  const [variant, setVariant] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [result, setResult] = useState<TrafficResult>();

  async function run() {
    setBusy(true); setError(undefined);
    try { setResult(await api.traffic(n, variant)); }
    catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  }

  const total = result ? Object.values(result.versions).reduce((a, b) => a + b, 0) : 0;

  return (
    <>
      <Card title="Which version answers?" subtitle="Sends N cheap requests from the frontend to the rag-service and counts the versions. Switch patterns with app/demo.sh pattern <name>.">
        <div className="grid gap-3 md:grid-cols-5">
          {PATTERNS.map((p) => (
            <div key={p.name} className="rounded-lg border border-slate-200 p-3 text-sm">
              <code className="font-semibold">{p.name}</code>
              <p className="mt-1 text-xs text-slate-500">{p.text}</p>
            </div>
          ))}
        </div>
        <div className="mt-4 flex flex-wrap items-end gap-4">
          <label className="text-sm text-slate-600">requests
            <input type="number" min={1} max={500} className={`${inputClass} mt-1 w-28`} value={n} onChange={(e) => setN(Number(e.target.value))} />
          </label>
          <label className="text-sm text-slate-600">x-variant header
            <select className={`${inputClass} mt-1 w-40`} value={variant} onChange={(e) => setVariant(e.target.value)}>
              <option value="">(none)</option>
              <option value="a">a</option>
              <option value="b">b</option>
            </select>
          </label>
          <Button onClick={run} disabled={busy}>{busy ? "Sending..." : "Send traffic"}</Button>
        </div>
        <ErrorBox error={error} />
      </Card>

      {result && (
        <Card title="Result" subtitle={`${result.requests} requests, ${result.errors} errors. With "mirror" all answers come from v1; check the v2 pods' logs or Kiali for the shadow copies.`}>
          <div className="space-y-3">
            {Object.entries(result.versions).map(([version, count]) => (
              <div key={version}>
                <div className="mb-1 flex justify-between text-sm"><span className="font-medium">rag {version}</span><span>{count} ({Math.round((count / total) * 100)}%)</span></div>
                <div className="h-3 rounded-full bg-slate-100">
                  <div className={`h-3 rounded-full ${version === "v2" ? "bg-amber-500" : "bg-emerald-500"}`} style={{ width: `${(count / total) * 100}%` }} />
                </div>
              </div>
            ))}
          </div>
          <h3 className="mt-6 text-sm font-semibold text-slate-700">Pods</h3>
          <ul className="mt-2 grid gap-1 text-sm text-slate-600 md:grid-cols-2">
            {Object.entries(result.pods).map(([pod, count]) => <li key={pod}><code>{pod}</code>: {count}</li>)}
          </ul>
        </Card>
      )}
    </>
  );
}
