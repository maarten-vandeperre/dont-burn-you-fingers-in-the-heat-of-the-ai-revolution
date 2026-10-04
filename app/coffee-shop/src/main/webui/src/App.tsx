import { useEffect, useState } from "react";
import { api } from "./api";
import OrderTab from "./tabs/OrderTab";
import OrdersTab from "./tabs/OrdersTab";
import AuditTab from "./tabs/AuditTab";
import MenuTab from "./tabs/MenuTab";

const TABS = [
  { id: "order", label: "Order", hint: "LangChain4j via the model router" },
  { id: "orders", label: "Orders", hint: "PostgreSQL (system of record)" },
  { id: "audit", label: "Audit", hint: "MongoDB, built by Debezium" },
  { id: "menu", label: "Menu & resilience", hint: "mesh: versions, mirroring, chaos" },
] as const;
type TabId = (typeof TABS)[number]["id"];

export default function App() {
  const [tab, setTab] = useState<TabId>("order");
  const [model, setModel] = useState("");
  useEffect(() => { api.config().then((c) => setModel(c.model)).catch(() => setModel("?")); }, []);
  return (
    <div className="min-h-screen">
      <header className="border-b border-stone-200 bg-white">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
          <div className="flex items-center gap-3">
            <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-brand text-lg text-white">☕</div>
            <div>
              <h1 className="text-base font-semibold text-stone-900">Platform Coffee</h1>
              <p className="text-xs text-stone-500">Quarkus · LangChain4j · Service Mesh · Debezium · OpenShift AI</p>
            </div>
          </div>
          <span className="rounded-full bg-stone-100 px-3 py-1 text-xs text-stone-600">model alias: <b>{model || "..."}</b></span>
        </div>
        <nav className="mx-auto flex max-w-6xl gap-1 px-6">
          {TABS.map((t) => (
            <button key={t.id} onClick={() => setTab(t.id)}
              className={`border-b-2 px-4 py-3 text-left text-sm transition ${tab === t.id
                ? "border-brand font-semibold text-stone-900" : "border-transparent text-stone-500 hover:text-stone-800"}`}>
              {t.label}
              <span className="block text-xs font-normal text-stone-400">{t.hint}</span>
            </button>
          ))}
        </nav>
      </header>
      <main className="mx-auto max-w-6xl space-y-6 px-6 py-8">
        {tab === "order" && <OrderTab onPlaced={() => setTab("orders")} />}
        {tab === "orders" && <OrdersTab />}
        {tab === "audit" && <AuditTab />}
        {tab === "menu" && <MenuTab />}
      </main>
    </div>
  );
}
