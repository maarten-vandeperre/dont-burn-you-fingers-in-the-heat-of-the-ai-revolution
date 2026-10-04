import { useCallback, useEffect, useState } from "react";
import { api, type AuditEvent } from "../api";
import { Badge, Button, Card, ErrorBox } from "../ui";

const TONE: Record<string, "green" | "blue" | "red" | "slate"> = { created: "green", updated: "blue", deleted: "red", snapshot: "slate" };

export default function AuditTab() {
  const [events, setEvents] = useState<AuditEvent[]>([]);
  const [open, setOpen] = useState<number>();
  const [error, setError] = useState<string>();
  const refresh = useCallback(async () => {
    try { setEvents(await api.audit()); setError(undefined); } catch (e) { setError((e as Error).message); }
  }, []);
  useEffect(() => { refresh(); const t = setInterval(refresh, 2000); return () => clearInterval(t); }, [refresh]);

  return (
    <Card title="Audit trail" subtitle="Read from MongoDB only. PostgreSQL -> Debezium -> Kafka -> projection-service -> MongoDB, refreshed every 2 s."
      actions={<Badge tone="blue">{events.length} events</Badge>}>
      <ErrorBox error={error} />
      <ol className="space-y-2">
        {events.map((e, n) => (
          <li key={n} className="rounded-lg border border-stone-200 p-3 text-sm">
            <button className="flex w-full items-center justify-between gap-3 text-left" onClick={() => setOpen(open === n ? undefined : n)}>
              <span className="flex items-center gap-2">
                <Badge tone={TONE[e.operation] ?? "slate"}>{e.operation}</Badge>
                <code className="text-xs text-stone-500">coffee.{e.table}</code>
                <span>{e.summary}</span>
              </span>
              <span className="whitespace-nowrap text-xs text-stone-400">{new Date(e.at).toLocaleTimeString()} · lag {e.lagMs} ms</span>
            </button>
            {open === n && (
              <div className="mt-3 grid gap-3 md:grid-cols-2">
                <pre className="overflow-x-auto rounded bg-stone-50 p-2 text-xs"><b>before</b>{"\n"}{JSON.stringify(e.before, null, 2)}</pre>
                <pre className="overflow-x-auto rounded bg-stone-50 p-2 text-xs"><b>after</b>{"\n"}{JSON.stringify(e.after, null, 2)}</pre>
                {e.kafka && <p className="text-xs text-stone-400 md:col-span-2">Kafka {e.kafka.topic} · partition {e.kafka.partition} · offset {e.kafka.offset}</p>}
              </div>
            )}
          </li>
        ))}
        {events.length === 0 && <li className="text-sm text-stone-500">No events yet. Place, advance or cancel an order.</li>}
      </ol>
      <div className="mt-4"><Button variant="secondary" onClick={refresh}>Refresh now</Button></div>
    </Card>
  );
}
