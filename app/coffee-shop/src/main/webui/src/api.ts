// Typed wrappers around the coffee-shop API.

export interface MenuItem { drink: string; priceCents: number; milk: boolean; seasonal: boolean }
export interface LiveMenu { source: string; version: string; pod: string; items: MenuItem[]; elapsedMs: number }
export interface PricedItem { drink: string; size: string; milk: string; quantity: number; decaf: boolean; unitCents: number; totalCents: number }
export interface Quote { id: string; text: string; items: PricedItem[]; totalCents: number; menuVersion: string; menuSource: string }
export interface Interpretation { clarification: string; quote?: Quote; model: string; elapsedMs: number; traceId?: string }
export interface Order {
  id: number; status: string; totalCents: number; cups: number; modelAlias: string; menuVersion: string;
  orderText: string; createdAt: string; updatedAt: string; lines: PricedItem[];
}
export interface AuditEvent {
  table: string; op: string; operation: string; orderId: number; summary: string; at: string; lagMs: number;
  kafka?: { topic: string; partition: number; offset: number };
  before?: Record<string, unknown> | null; after?: Record<string, unknown> | null;
}
export interface ProbeResult { requests: number; versions: Record<string, number>; errors: Record<string, number>; p50Ms: number; p95Ms: number; maxMs: number }

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, { ...init, headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) } });
  if (!res.ok) {
    let message = `${res.status} ${res.statusText}`;
    try { const body = await res.json(); if (body?.error) message = body.error; } catch { /* not json */ }
    throw new Error(message);
  }
  return res.status === 204 ? (undefined as T) : ((await res.json()) as T);
}

export const euro = (cents: number) => `€${(cents / 100).toFixed(2)}`;

export const api = {
  config: () => call<{ model: string; maxCups: number; mlflowUrl?: string }>("/api/config"),
  menu: () => call<LiveMenu>("/api/menu"),
  probe: (n: number) => call<ProbeResult>(`/api/menu/probe?n=${n}`),
  interpret: (text: string) => call<Interpretation>("/api/interpret", { method: "POST", body: JSON.stringify({ text }) }),
  confirm: (quoteId: string) => call<Order>("/api/orders", { method: "POST", body: JSON.stringify({ quoteId }) }),
  orders: () => call<Order[]>("/api/orders"),
  advance: (id: number) => call<Order>(`/api/orders/${id}/advance`, { method: "POST" }),
  cancel: (id: number) => call<void>(`/api/orders/${id}`, { method: "DELETE" }),
  audit: (orderId?: number) => call<AuditEvent[]>(`/api/audit?limit=100${orderId ? `&orderId=${orderId}` : ""}`),
};
