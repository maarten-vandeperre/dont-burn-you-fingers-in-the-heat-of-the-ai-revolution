import { useEffect, useState } from "react";

interface Config { name: string; description: string; useCase: string; size: string; maxChars: number }
interface Answer { answer: string; useCase: string; maxChars: number; elapsedMs: number }

export default function App() {
  const [config, setConfig] = useState<Config>();
  const [question, setQuestion] = useState("");
  const [answer, setAnswer] = useState<Answer>();
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    fetch("/api/config").then((r) => r.json()).then(setConfig).catch(() => setError("Backend not reachable"));
  }, []);

  const max = config?.maxChars ?? 200;

  async function ask() {
    setBusy(true); setError(undefined); setAnswer(undefined);
    try {
      const res = await fetch("/api/ask", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ question }),
      });
      const body = await res.json();
      if (!res.ok) throw new Error(body.error ?? res.statusText);
      setAnswer(body);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="mx-auto max-w-3xl space-y-6 px-6 py-10">
      <header>
        <h1 className="text-2xl font-semibold text-slate-900">{config?.name ?? "LLM application"}</h1>
        <p className="text-slate-600">{config?.description}</p>
        {config && (
          <div className="mt-3 flex gap-2 text-xs">
            <span className="rounded-full bg-indigo-100 px-3 py-1 text-indigo-800">{config.useCase}</span>
            <span className="rounded-full bg-slate-200 px-3 py-1 text-slate-700">{config.size} · max {config.maxChars} characters</span>
          </div>
        )}
      </header>

      <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
        <textarea
          className="h-36 w-full rounded-lg border border-slate-300 p-3 text-sm focus:border-indigo-500 focus:outline-none"
          placeholder="Ask your question..."
          maxLength={max}
          value={question}
          onChange={(e) => setQuestion(e.target.value)}
        />
        <div className="mt-2 flex items-center justify-between">
          <span className={`text-xs ${question.length >= max ? "text-red-600" : "text-slate-500"}`}>
            {question.length} / {max}
          </span>
          <button
            onClick={ask}
            disabled={busy || !question.trim()}
            className="rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700 disabled:opacity-50"
          >
            {busy ? "Thinking..." : "Ask"}
          </button>
        </div>
        {error && <p className="mt-3 rounded-lg bg-red-50 p-3 text-sm text-red-700">{error}</p>}
      </section>

      {answer && (
        <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
          <p className="whitespace-pre-wrap text-slate-800">{answer.answer}</p>
          <p className="mt-3 text-xs text-slate-400">{answer.useCase} · {answer.elapsedMs} ms</p>
        </section>
      )}
    </main>
  );
}
