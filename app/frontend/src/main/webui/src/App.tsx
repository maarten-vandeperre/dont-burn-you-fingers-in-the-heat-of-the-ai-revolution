import { useState } from "react";
import AskTab from "./tabs/AskTab";
import TrafficTab from "./tabs/TrafficTab";
import CdcTab from "./tabs/CdcTab";
import MeshTab from "./tabs/MeshTab";

const TABS = [
  { id: "ask", label: "Ask (RAG)", hint: "LangChain4j + Camel model router" },
  { id: "traffic", label: "Traffic patterns", hint: "canary, A/B, blue-green, mirroring" },
  { id: "cdc", label: "CDC", hint: "PostgreSQL -> Debezium -> Kafka -> MongoDB" },
  { id: "mesh", label: "Mesh access", hint: "mTLS identities + AuthorizationPolicies" },
] as const;

type TabId = (typeof TABS)[number]["id"];

export default function App() {
  const [tab, setTab] = useState<TabId>("ask");
  return (
    <div className="min-h-screen">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
          <div className="flex items-center gap-3">
            <div className="h-8 w-8 rounded-lg bg-brand" />
            <div>
              <h1 className="text-base font-semibold text-slate-900">AI platform demo</h1>
              <p className="text-xs text-slate-500">OpenShift 4.22 · OpenShift AI 3.4 · Service Mesh 3 · Kafka + Debezium</p>
            </div>
          </div>
        </div>
        <nav className="mx-auto flex max-w-6xl gap-1 px-6">
          {TABS.map((t) => (
            <button key={t.id} onClick={() => setTab(t.id)}
              className={`border-b-2 px-4 py-3 text-left text-sm transition ${tab === t.id
                ? "border-brand font-semibold text-slate-900"
                : "border-transparent text-slate-500 hover:text-slate-800"}`}>
              {t.label}
              <span className="block text-xs font-normal text-slate-400">{t.hint}</span>
            </button>
          ))}
        </nav>
      </header>
      <main className="mx-auto max-w-6xl space-y-6 px-6 py-8">
        {tab === "ask" && <AskTab />}
        {tab === "traffic" && <TrafficTab />}
        {tab === "cdc" && <CdcTab />}
        {tab === "mesh" && <MeshTab />}
      </main>
    </div>
  );
}
