import { useState } from "react";
import { api, type AskResponse, type ModelAlias } from "../api";
import { Badge, Button, Card, ErrorBox, inputClass } from "../ui";

const MODELS: { id: ModelAlias; label: string; note: string }[] = [
  { id: "auto", label: "auto", note: "local Qwen, OpenAI fallback (Camel circuit breaker)" },
  { id: "qwen", label: "qwen", note: "Qwen3 0.6B via MaaS" },
  { id: "gemma", label: "gemma", note: "Gemma 3 270M via MaaS" },
  { id: "openai", label: "openai", note: "OpenAI API" },
];

const EXAMPLES = [
  "How does the mesh decide who can access who?",
  "What is the difference between canary and traffic mirroring?",
  "How do changes in PostgreSQL end up in MongoDB?",
  "Why does the model router use a circuit breaker?",
];

export default function AskTab() {
  const [question, setQuestion] = useState(EXAMPLES[0]);
  const [model, setModel] = useState<ModelAlias>("auto");
  const [variant, setVariant] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [result, setResult] = useState<AskResponse>();

  async function ask() {
    setBusy(true); setError(undefined);
    try { setResult(await api.ask(question, model, variant)); }
    catch (e) { setError((e as Error).message); }
    finally { setBusy(false); }
  }

  return (
    <>
      <Card title="Ask the platform" subtitle="Retrieval augmented generation over the platform docs. CPU models take 10-60 s per answer.">
        <textarea className={`${inputClass} h-24`} value={question} onChange={(e) => setQuestion(e.target.value)} />
        <div className="mt-2 flex flex-wrap gap-2">
          {EXAMPLES.map((q) => (
            <button key={q} onClick={() => setQuestion(q)} className="rounded-full bg-slate-100 px-3 py-1 text-xs text-slate-600 hover:bg-slate-200">{q}</button>
          ))}
        </div>
        <div className="mt-4 grid gap-3 md:grid-cols-4">
          {MODELS.map((m) => (
            <label key={m.id} className={`cursor-pointer rounded-lg border p-3 text-sm ${model === m.id ? "border-slate-900 bg-slate-50" : "border-slate-200"}`}>
              <input type="radio" name="model" className="mr-2" checked={model === m.id} onChange={() => setModel(m.id)} />
              <span className="font-medium">{m.label}</span>
              <span className="mt-1 block text-xs text-slate-500">{m.note}</span>
            </label>
          ))}
        </div>
        <div className="mt-4 flex items-center gap-4">
          <label className="flex items-center gap-2 text-sm text-slate-600">
            <input type="checkbox" checked={variant === "b"} onChange={(e) => setVariant(e.target.checked ? "b" : "")} />
            send <code className="rounded bg-slate-100 px-1">x-variant: b</code> (A/B pattern routes this to rag v2)
          </label>
          <div className="ml-auto"><Button onClick={ask} disabled={busy || !question.trim()}>{busy ? "Thinking..." : "Ask"}</Button></div>
        </div>
        <ErrorBox error={error} />
      </Card>

      {result && (
        <Card title="Answer" actions={
          <div className="flex flex-wrap gap-2">
            <Badge tone="blue">model: {result.model}</Badge>
            <Badge tone={result.version === "v2" ? "amber" : "green"}>rag {result.version}</Badge>
            <Badge>retrieval {result.retrievalMs} ms</Badge>
            <Badge>generation {result.generationMs} ms</Badge>
            {result.inputTokens != null && <Badge>tokens {result.inputTokens} in / {result.outputTokens} out</Badge>}
          </div>
        }>
          <p className="whitespace-pre-wrap text-slate-800">{result.answer || "(empty answer)"}</p>
          <h3 className="mt-6 text-sm font-semibold text-slate-700">Retrieved context</h3>
          <ol className="mt-2 space-y-2">
            {result.sources.map((s) => (
              <li key={s.index} className="rounded-lg bg-slate-50 p-3 text-sm">
                <span className="font-medium">[{s.index}] {s.title}</span>
                <span className="ml-2 text-xs text-slate-400">BM25 {s.score}</span>
                <p className="mt-1 text-slate-600">{s.snippet}</p>
              </li>
            ))}
            {result.sources.length === 0 && <li className="text-sm text-slate-500">No matching documents.</li>}
          </ol>
          <p className="mt-4 text-xs text-slate-400">served by pod {result.pod}. Full trace: OpenShift console, Observe, Traces (service frontend).</p>
        </Card>
      )}
    </>
  );
}
