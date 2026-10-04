import { useState } from "react";
import { api, type ProbeResult } from "../api";
import { Badge, Button, Card, ErrorBox } from "../ui";

const POLICIES = [
  ["ai-demo-gateway (ingress)", "frontend"],
  ["frontend", "rag-service, orders-service, projection-service"],
  ["rag-service", "model-router"],
  ["projection-service", "mongodb"],
  ["everyone else", "nothing (deny-all + STRICT mTLS)"],
];

export default function MeshTab() {
  const [results, setResults] = useState<ProbeResult[]>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  async function probe() {
    setBusy(true); setError(undefined);
    try { setResults(await api.probe()); } catch (e) { setError((e as Error).message); } finally { setBusy(false); }
  }

  return (
    <>
      <Card title="Who may call whom" subtitle="AuthorizationPolicies match the caller's mTLS identity (its service account), e.g. cluster.local/ns/ai-demo/sa/frontend">
        <table className="w-full text-left text-sm">
          <thead><tr className="text-slate-500"><th className="py-2">caller</th><th>allowed to call</th></tr></thead>
          <tbody>
            {POLICIES.map(([from, to]) => (
              <tr key={from} className="border-t border-slate-100"><td className="py-2 font-medium">{from}</td><td>{to}</td></tr>
            ))}
          </tbody>
        </table>
      </Card>
      <Card title="Probe from the frontend pod" subtitle="Calls every service with the frontend's identity and shows what the mesh did."
        actions={<Button onClick={probe} disabled={busy}>{busy ? "Probing..." : "Run probe"}</Button>}>
        {results && (
          <table className="w-full text-left text-sm">
            <thead><tr className="text-slate-500"><th className="py-2">target</th><th>call</th><th>expected</th><th>result</th></tr></thead>
            <tbody>
              {results.map((r) => {
                const ok = r.allowed === r.expectedAllowed;
                return (
                  <tr key={r.target} className="border-t border-slate-100 align-top">
                    <td className="py-2 font-medium">{r.target}</td>
                    <td className="font-mono text-xs text-slate-500">{r.call}</td>
                    <td><Badge tone={r.expectedAllowed ? "green" : "red"}>{r.expectedAllowed ? "allow" : "deny"}</Badge></td>
                    <td><Badge tone={ok ? "green" : "amber"}>{ok ? "as expected" : "unexpected"}</Badge><span className="ml-2 text-xs text-slate-500">{r.outcome}</span></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
        <ErrorBox error={error} />
        <p className="mt-4 text-xs text-slate-400">STRICT mTLS check from outside the mesh: app/demo.sh mtls</p>
      </Card>
    </>
  );
}
