import { useCallback, useEffect, useState } from "react";
import { api, type Customer, type CustomerView } from "../api";
import { Badge, Button, Card, ErrorBox, inputClass } from "../ui";

export default function CdcTab() {
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [views, setViews] = useState<CustomerView[]>([]);
  const [error, setError] = useState<string>();
  const [form, setForm] = useState({ firstName: "Margaret", lastName: "Hamilton", email: "margaret@example.com" });
  const [order, setOrder] = useState({ customerId: 1, product: "OpenShift subscription", quantity: 1 });

  const refresh = useCallback(async () => {
    try {
      const [c, v] = await Promise.all([api.customers(), api.views()]);
      setCustomers(c); setViews(v); setError(undefined);
    } catch (e) { setError((e as Error).message); }
  }, []);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 2000);
    return () => clearInterval(t);
  }, [refresh]);

  async function run(action: () => Promise<unknown>) {
    try { await action(); await refresh(); } catch (e) { setError((e as Error).message); }
  }

  return (
    <>
      <div className="grid gap-6 md:grid-cols-2">
        <Card title="1. Write to PostgreSQL" subtitle="orders-service writes to inventory-db (the system of record)">
          <div className="grid gap-2">
            <div className="grid grid-cols-2 gap-2">
              <input className={inputClass} value={form.firstName} onChange={(e) => setForm({ ...form, firstName: e.target.value })} placeholder="first name" />
              <input className={inputClass} value={form.lastName} onChange={(e) => setForm({ ...form, lastName: e.target.value })} placeholder="last name" />
            </div>
            <input className={inputClass} value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} placeholder="email" />
            <Button onClick={() => run(() => api.createCustomer(form))}>Create customer</Button>
          </div>
          <div className="mt-6 grid gap-2">
            <div className="grid grid-cols-3 gap-2">
              <select className={inputClass} value={order.customerId} onChange={(e) => setOrder({ ...order, customerId: Number(e.target.value) })}>
                {customers.map((c) => <option key={c.id} value={c.id}>{c.id} {c.firstName} {c.lastName}</option>)}
              </select>
              <input className={inputClass} value={order.product} onChange={(e) => setOrder({ ...order, product: e.target.value })} />
              <input type="number" min={1} className={inputClass} value={order.quantity} onChange={(e) => setOrder({ ...order, quantity: Number(e.target.value) })} />
            </div>
            <Button onClick={() => run(() => api.createOrder(order.customerId, order.product, order.quantity))}>Place order</Button>
          </div>
        </Card>
        <Card title="2. Debezium + Kafka" subtitle="every row change becomes an event on inventory.inventory.customers / .orders">
          <ol className="list-decimal space-y-2 pl-5 text-sm text-slate-600">
            <li>PostgreSQL writes the change to its write-ahead log (wal_level=logical).</li>
            <li>The Debezium connector in Kafka Connect reads it through the pgoutput plugin.</li>
            <li>The event (op c/u/d, before, after, source) lands on the Kafka topic.</li>
            <li>projection-service consumes it and upserts a formatted document in MongoDB.</li>
          </ol>
          <p className="mt-4 text-xs text-slate-400">Try it from a terminal: ./deploy.sh cdc-demo. Each step shows up as a span in the trace view.</p>
        </Card>
      </div>
      <Card title="3. MongoDB read model" subtitle="customer_views, refreshed every 2 s from projection-service" actions={<Badge tone="blue">{views.length} documents</Badge>}>
        <div className="grid gap-4 md:grid-cols-2">
          {views.map((v) => (
            <div key={v._id} className="rounded-lg border border-slate-200 p-4">
              <div className="flex items-start justify-between">
                <div>
                  <p className="font-semibold text-slate-900">{v.fullName || `(customer ${v._id}, details pending)`}</p>
                  <p className="text-sm text-slate-500">{v.email}</p>
                </div>
                {v.totals && <Badge tone="green">{v.totals.orders} orders · {v.totals.items} items</Badge>}
              </div>
              <ul className="mt-3 space-y-1 text-sm">
                {(v.orders ?? []).map((o) => (
                  <li key={o.orderId} className="flex items-center justify-between">
                    <span>#{o.orderId} {o.product} × {o.quantity}</span>
                    <button className="text-xs text-red-600 hover:underline" onClick={() => run(() => api.deleteOrder(o.orderId))}>delete</button>
                  </li>
                ))}
              </ul>
              {v.lastChange && (
                <p className="mt-3 text-xs text-slate-400">last change: {v.lastChange.table} {v.lastChange.operation} at {v.lastChange.at}</p>
              )}
            </div>
          ))}
        </div>
        <ErrorBox error={error} />
      </Card>
    </>
  );
}
