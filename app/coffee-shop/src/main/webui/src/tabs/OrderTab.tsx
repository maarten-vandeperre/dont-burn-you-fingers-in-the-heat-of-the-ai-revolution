import { useEffect, useState } from "react";
import { api, euro, type Interpretation, type LiveMenu } from "../api";
import { Badge, Button, Card, ErrorBox, inputClass } from "../ui";

const EXAMPLES = [
  "Two large oat lattes and a cappuccino, please.",
  "One latte and one decaf soy latte.",
  "A mocha and a pumpkin spice latte.",
  "Coffee, please.",
];

export default function OrderTab({ onPlaced }: { onPlaced: () => void }) {
  const [text, setText] = useState(EXAMPLES[0]);
  const [menu, setMenu] = useState<LiveMenu>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [result, setResult] = useState<Interpretation>();
  const [mlflowUrl, setMlflowUrl] = useState<string>();

  useEffect(() => {
    api.menu().then(setMenu).catch((e) => setError((e as Error).message));
    api.config().then((c) => setMlflowUrl(c.mlflowUrl || undefined)).catch(() => undefined);
  }, []);

  const trace = result?.traceId && (
    <p className="mt-3 text-xs text-stone-500">
      MLflow trace <code>tr-{result.traceId}</code>
      {mlflowUrl && <> · <a className="text-brand underline" href={mlflowUrl} target="_blank" rel="noreferrer">open in MLflow</a> (workspace ai-demo)</>}
    </p>
  );

  async function interpret() {
    setBusy(true); setError(undefined); setResult(undefined);
    try { setResult(await api.interpret(text)); setMenu(await api.menu()); }
    catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  }

  async function confirm(quoteId: string) {
    setBusy(true); setError(undefined);
    try { await api.confirm(quoteId); onPlaced(); }
    catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  }

  return (
    <div className="grid gap-6 md:grid-cols-3">
      <div className="space-y-6 md:col-span-2">
        <Card title="What would you like?" subtitle="Natural language. The model interprets, the server prices with the live menu.">
          <textarea className={`${inputClass} h-24`} value={text} onChange={(e) => setText(e.target.value)} />
          <div className="mt-2 flex flex-wrap gap-2">
            {EXAMPLES.map((q) => (
              <button key={q} onClick={() => setText(q)} className="rounded-full bg-stone-100 px-3 py-1 text-xs text-stone-600 hover:bg-stone-200">{q}</button>
            ))}
          </div>
          <div className="mt-4 flex justify-end"><Button onClick={interpret} disabled={busy || !text.trim()}>{busy ? "Thinking..." : "Interpret order"}</Button></div>
          <ErrorBox error={error} />
        </Card>

        {result?.clarification && (
          <Card title="The barista asks" subtitle={`model ${result.model}, ${result.elapsedMs} ms`}>
            <p className="text-stone-800">{result.clarification}</p>
            {trace}
          </Card>
        )}

        {result?.quote && (
          <Card title="Your order" subtitle={`model ${result.model}, ${result.elapsedMs} ms`}
            actions={<div className="flex gap-2"><Badge tone="blue">menu {result.quote.menuVersion}</Badge>
              <Badge tone={result.quote.menuSource === "live" ? "green" : "amber"}>menu {result.quote.menuSource}</Badge></div>}>
            <table className="w-full text-left text-sm">
              <thead><tr className="text-stone-500"><th className="py-1">drink</th><th>qty</th><th>unit</th><th className="text-right">total</th></tr></thead>
              <tbody>
                {result.quote.items.map((i, n) => (
                  <tr key={n} className="border-t border-stone-100">
                    <td className="py-2">{i.size} {i.milk !== "none" ? i.milk : ""} {i.drink}{i.decaf ? " (decaf)" : ""}</td>
                    <td>{i.quantity}</td><td>{euro(i.unitCents)}</td><td className="text-right">{euro(i.totalCents)}</td>
                  </tr>
                ))}
                <tr className="border-t border-stone-300 font-semibold"><td className="py-2">Total</td><td /><td /><td className="text-right">{euro(result.quote.totalCents)}</td></tr>
              </tbody>
            </table>
            <div className="mt-4 flex items-end justify-between">{trace ?? <span />}<Button onClick={() => confirm(result.quote!.id)} disabled={busy}>Place order</Button></div>
          </Card>
        )}
      </div>

      <Card title="Menu" subtitle="from coffee-menu, through the mesh"
        actions={menu && <Badge tone={menu.source === "live" ? "green" : "amber"}>{menu.source} · {menu.version}</Badge>}>
        <ul className="space-y-1 text-sm">
          {menu?.items.map((i) => (
            <li key={i.drink} className="flex justify-between">
              <span>{i.drink}{i.seasonal && <span className="ml-1 text-xs text-amber-700">seasonal</span>}</span>
              <span className="text-stone-500">{euro(i.priceCents)}</span>
            </li>
          ))}
        </ul>
        <p className="mt-3 text-xs text-stone-400">large +€0.70 · oat/soy +€0.40 · max 6 cups</p>
      </Card>
    </div>
  );
}
