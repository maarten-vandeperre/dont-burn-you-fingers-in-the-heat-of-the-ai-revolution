// Thin typed wrappers around the frontend (backend-for-frontend) API.

export type ModelAlias = "gemma" | "qwen" | "openai" | "auto";

export interface Source { index: number; title: string; snippet: string; score: number }
export interface AskResponse {
  answer: string; sources: Source[]; model: string; version: string; pod: string;
  retrievalMs: number; generationMs: number; inputTokens?: number; outputTokens?: number;
}
export interface TrafficResult { requests: number; versions: Record<string, number>; pods: Record<string, number>; errors: number }
export interface ProbeResult { target: string; call: string; expectedAllowed: boolean; outcome: string; status: number; allowed: boolean }
export interface Customer { id: number; firstName: string; lastName: string; email: string }
export interface OrderView { orderId: number; product: string; quantity: number; createdAt: string }
export interface CustomerView {
  _id: number; fullName?: string; email?: string; orders?: OrderView[];
  totals?: { orders: number; items: number };
  lastChange?: { table: string; operation: string; at: string };
  history?: { what: string; at: string }[];
}

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, { ...init, headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) } });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`${res.status} ${res.statusText}${text ? `: ${text.slice(0, 300)}` : ""}`);
  }
  return res.status === 204 ? (undefined as T) : ((await res.json()) as T);
}

export const api = {
  ask: (question: string, model: ModelAlias, variant: string) =>
    call<AskResponse>("/api/ask", {
      method: "POST",
      body: JSON.stringify({ question, model }),
      headers: variant ? { "x-variant": variant } : {},
    }),
  traffic: (n: number, variant: string) =>
    call<TrafficResult>(`/api/traffic?n=${n}${variant ? `&variant=${encodeURIComponent(variant)}` : ""}`),
  probe: () => call<ProbeResult[]>("/api/mesh/probe"),
  customers: () => call<Customer[]>("/api/customers"),
  views: () => call<CustomerView[]>("/api/customer-views"),
  createCustomer: (c: Omit<Customer, "id">) => call<Customer>("/api/customers", { method: "POST", body: JSON.stringify(c) }),
  updateCustomer: (id: number, c: Partial<Customer>) =>
    call<Customer>(`/api/customers/${id}`, { method: "PUT", body: JSON.stringify(c) }),
  createOrder: (customerId: number, product: string, quantity: number) =>
    call("/api/orders", { method: "POST", body: JSON.stringify({ customerId, product, quantity }) }),
  deleteOrder: (id: number) => call<void>(`/api/orders/${id}`, { method: "DELETE" }),
};
