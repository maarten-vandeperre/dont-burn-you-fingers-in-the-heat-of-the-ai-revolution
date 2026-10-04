import { useCallback, useEffect, useState } from "react";
import { api, euro, type Order } from "../api";
import { Badge, Button, Card, ErrorBox } from "../ui";

const NEXT: Record<string, string> = { PLACED: "Start brewing", BREWING: "Mark ready", READY: "Collected" };

export default function OrdersTab() {
  const [orders, setOrders] = useState<Order[]>([]);
  const [error, setError] = useState<string>();
  const refresh = useCallback(async () => {
    try { setOrders(await api.orders()); setError(undefined); } catch (e) { setError((e as Error).message); }
  }, []);
  useEffect(() => { refresh(); }, [refresh]);

  async function run(action: () => Promise<unknown>) {
    try { await action(); await refresh(); } catch (e) { setError((e as Error).message); }
  }

  return (
    <Card title="Orders" subtitle="Read from PostgreSQL. Every button below is a database change that Debezium turns into an event (see the Audit tab)."
      actions={<Button variant="secondary" onClick={refresh}>Refresh</Button>}>
      <ErrorBox error={error} />
      <div className="space-y-3">
        {orders.map((o) => (
          <div key={o.id} className="rounded-lg border border-stone-200 p-4">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="flex items-center gap-2">
                <span className="font-semibold">#{o.id}</span>
                <Badge tone={o.status === "COLLECTED" ? "slate" : o.status === "READY" ? "green" : "blue"}>{o.status}</Badge>
                <span className="text-sm text-stone-500">{o.cups} cups · {euro(o.totalCents)} · menu {o.menuVersion} · model {o.modelAlias}</span>
              </div>
              <div className="flex gap-2">
                {NEXT[o.status] && <Button onClick={() => run(() => api.advance(o.id))}>{NEXT[o.status]}</Button>}
                <Button variant="secondary" onClick={() => run(() => api.cancel(o.id))}>Cancel</Button>
              </div>
            </div>
            <p className="mt-2 text-sm italic text-stone-500">“{o.orderText}”</p>
            <ul className="mt-2 text-sm text-stone-700">
              {o.lines.map((l, n) => <li key={n}>{l.quantity} × {l.size} {l.milk !== "none" ? l.milk : ""} {l.drink}{l.decaf ? " (decaf)" : ""} · {euro(l.totalCents)}</li>)}
            </ul>
          </div>
        ))}
        {orders.length === 0 && <p className="text-sm text-stone-500">No orders yet. Place one in the Order tab.</p>}
      </div>
    </Card>
  );
}
