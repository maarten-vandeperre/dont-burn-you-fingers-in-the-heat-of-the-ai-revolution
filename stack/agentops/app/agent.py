"""
finops-agent: a small tool-calling agent, built to show AgentOps on OpenShift AI.

  question -> system prompt from the MLflow prompt registry (prompts:/finops-agent@<alias|version>)
           -> LLM through the demo 15 LLM API (Connectivity Link + Praxis: key, quotas, routing)
           -> MCP tools through the demo 15 MCP gateway (finops_* = PostgreSQL + budget-api,
              ops_get_limits, models_list_models)
           -> answer

Observability, with no extra code per step:
  * MLflow tracing: one trace per question (AGENT span, CHAT_MODEL spans from mlflow.openai.autolog
    with messages, tokens and latency, TOOL spans per MCP call; the MCP server and budget-api add
    their spans to the same trace), tagged with the prompt version, model and caller
  * the same spans to Tempo (OTLP dual export)
  * Prometheus metrics on /metrics: requests, latency, tokens, tool calls per prompt version / model / tool

  GET  /               the demo UI
  GET  /api/config     models, prompt versions and aliases, links
  POST /api/ask        {"question", "model", "prompt"}  -> answer, steps, trace id
"""

import json
import os
import re
import threading
import time
from datetime import date

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from openai import OpenAI
from prometheus_client import Counter, Histogram, make_asgi_app
from pydantic import BaseModel
import uvicorn

from common import log, mlflow_ui_base, prompt_versions, refresh_token, setup_mlflow

mlflow, EXPERIMENT_ID = setup_mlflow()
mlflow.openai.autolog()        # every chat.completions call becomes a CHAT_MODEL span (messages, tokens)
from mlflow.tracing.distributed import get_tracing_context_headers_for_http_request  # noqa: E402

PROMPT_NAME = os.environ.get("PROMPT_NAME", "finops-agent")
LLM_BASE_URL = os.environ["LLM_BASE_URL"]                  # https://llm-gateway.<apps>/v2
MCP_URL = os.environ["MCP_URL"]                            # https://mcp.<apps>/mcp
API_KEY = os.environ["AGENT_API_KEY"]                      # Connectivity Link consumer "agent"
MODELS = [m.strip() for m in os.environ.get("AGENT_MODELS", "cloud,smart").split(",")]
LOCAL_MODELS = {"smart", "fast", "qwen3-0-6b", "gemma-3-270m-it"}
TOOL_ALLOWLIST = [t.strip() for t in os.environ.get(
    "AGENT_TOOLS", "finops_usage_by_team,finops_usage_by_model,finops_team_budget,ops_get_limits").split(",")]
MAX_STEPS = int(os.environ.get("AGENT_MAX_STEPS", "5"))
# How long an alias lookup (prompts:/finops-agent@production) is cached. MLflow's default is about a
# minute; shorter makes "move the alias, ask again" snappy on stage. Versions never change: cached.
PROMPT_CACHE_TTL = float(os.environ.get("PROMPT_CACHE_TTL", "15"))
HERE = os.path.dirname(os.path.abspath(__file__))

# The LLM API expects the consumer key; "Authorization: Bearer <key>" is what every OpenAI client
# sends, and the gateway's AuthPolicy accepts it (as well as "APIKEY <key>").
llm = OpenAI(base_url=LLM_BASE_URL, api_key=API_KEY, timeout=180, max_retries=0)

# ----------------------------------------------------------------------------- metrics
REQUESTS = Counter("agent_requests_total", "Agent questions", ["prompt_version", "model", "status"])
LATENCY = Histogram("agent_request_seconds", "End-to-end time per question", ["prompt_version", "model"],
                    buckets=(0.5, 1, 2, 5, 10, 20, 40, 80, 160))
TOKENS = Counter("agent_llm_tokens_total", "LLM tokens used by the agent", ["prompt_version", "model", "kind"])
LLM_CALLS = Counter("agent_llm_calls_total", "LLM calls", ["model", "status"])
TOOL_CALLS = Counter("agent_tool_calls_total", "MCP tool calls", ["tool", "status"])
TOOL_LATENCY = Histogram("agent_tool_seconds", "MCP tool call time", ["tool"],
                         buckets=(0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10))


# ----------------------------------------------------------------------------- MCP client
class Mcp:
    """Minimal MCP Streamable-HTTP client (JSON responses), one session per process."""

    def __init__(self):
        self.session, self.lock, self.next_id, self._tools = None, threading.Lock(), 1, None
        self.http = httpx.Client(timeout=60)

    def _post(self, body, session=True):
        h = {"Authorization": f"APIKEY {API_KEY}", "Content-Type": "application/json",
             "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-06-18",
             **get_tracing_context_headers_for_http_request()}        # W3C traceparent of the current span
        if session and self.session:
            h["Mcp-Session-Id"] = self.session
        r = self.http.post(MCP_URL, headers=h, json=body)
        text = r.text
        if r.headers.get("content-type", "").startswith("text/event-stream"):
            text = next((line[5:].strip() for line in text.splitlines() if line.startswith("data:")), "{}")
        return r, (json.loads(text) if text.strip() else {})

    def _init(self):
        r, body = self._post({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "finops-agent", "version": "1.0.0"}}}, session=False)
        if r.status_code != 200:
            raise RuntimeError(f"MCP initialize: HTTP {r.status_code} {r.text[:200]}")
        self.session = r.headers.get("mcp-session-id")
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def rpc(self, method, params):
        with self.lock:
            if not self.session:
                self._init()
            self.next_id += 1
            mid = self.next_id
        r, body = self._post({"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
        if r.status_code in (400, 404) and "session" in r.text.lower():     # gateway restarted: new session
            with self.lock:
                self._init()
            r, body = self._post({"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
        if r.status_code != 200:
            raise RuntimeError(f"HTTP {r.status_code} from the MCP gateway: {r.text[:200]}")
        if "error" in body:
            raise RuntimeError(body["error"].get("message", str(body["error"])))
        return body["result"]

    def tools(self):
        if self._tools is None:
            all_tools = self.rpc("tools/list", {})["tools"]
            self._tools = [t for t in all_tools if t["name"] in TOOL_ALLOWLIST]
            log.info("MCP tools: %s (of %d offered by the gateway)", [t["name"] for t in self._tools], len(all_tools))
        return self._tools


mcp = Mcp()


@mlflow.trace(span_type="TOOL")
def call_tool(name: str, arguments: dict) -> str:
    """One MCP tools/call through the gateway. The span carries the trace context to the server."""
    span = mlflow.get_current_active_span()
    if span:
        span.set_attributes({"mcp.tool": name, "mcp.gateway": MCP_URL})
    t0 = time.time()
    status = "ok"
    try:
        params = {"name": name, "arguments": arguments,
                  "_meta": get_tracing_context_headers_for_http_request()}   # also in the body, in case a proxy drops headers
        res = mcp.rpc("tools/call", params)
        text = "\n".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
        if res.get("isError"):
            status = "tool_error"
        return text
    except Exception as ex:
        status = "error"
        return f"Tool {name} could not be called: {ex}"
    finally:
        TOOL_CALLS.labels(name, status).inc()
        TOOL_LATENCY.labels(name).observe(time.time() - t0)
        if span:
            span.set_attributes({"mcp.status": status})


# ----------------------------------------------------------------------------- prompt registry
def load_prompt(ref: str):
    """ref: an alias (production, staging) or a version number. Loaded inside the trace, so MLflow
    links the trace to this prompt version (Prompts tab of the trace, and the prompt's traces)."""
    uri = f"prompts:/{PROMPT_NAME}/{ref}" if str(ref).isdigit() else f"prompts:/{PROMPT_NAME}@{ref}"
    return mlflow.genai.load_prompt(uri, cache_ttl_seconds=PROMPT_CACHE_TTL if not str(ref).isdigit() else None)


def _openai_tools():
    return [{"type": "function", "function": {"name": t["name"], "description": t.get("description", ""),
                                              "parameters": t.get("inputSchema") or {"type": "object", "properties": {}}}}
            for t in mcp.tools()]


def _strip_think(text):
    return re.sub(r"<think>.*?</think>", "", text or "", flags=re.S).strip()


# ----------------------------------------------------------------------------- the agent
@mlflow.trace(name="finops-agent", span_type="AGENT")
def run_agent(question: str, model: str = "cloud", prompt: str = "production", source: str = "ui",
              user: str = "demo-user", session: str | None = None) -> dict:
    refresh_token()
    t0 = time.time()
    p = load_prompt(prompt)
    version = str(p.version)
    mlflow.update_current_trace(
        tags={"prompt.name": PROMPT_NAME, "prompt.version": version, "prompt.ref": str(prompt),
              "llm.model": model, "source": source, "gateway.consumer": "agent"},
        metadata={"mlflow.trace.user": user, "mlflow.trace.session": session or f"{source}-{date.today()}"})
    system = p.format(today=date.today().isoformat())
    messages = [{"role": "system", "content": system}, {"role": "user", "content": question}]
    steps, tokens, status, answer = [], {"prompt": 0, "completion": 0}, "ok", ""
    extra = {"extra_body": {"chat_template_kwargs": {"enable_thinking": False}}} if model in LOCAL_MODELS else {}
    try:
        tools = _openai_tools()
        for _ in range(MAX_STEPS):
            t1 = time.time()
            try:
                resp = llm.chat.completions.create(model=model, messages=messages, tools=tools,
                                                   temperature=0, max_tokens=600, **extra)
                LLM_CALLS.labels(model, "ok").inc()
            except Exception as ex:
                LLM_CALLS.labels(model, getattr(ex, "status_code", "error")).inc()
                raise
            u = resp.usage
            if u:
                tokens["prompt"] += u.prompt_tokens or 0
                tokens["completion"] += u.completion_tokens or 0
            msg = resp.choices[0].message
            steps.append({"type": "llm", "model": resp.model or model, "ms": round((time.time() - t1) * 1000),
                          "tokens": (u.total_tokens if u else None),
                          "tool_calls": [tc.function.name for tc in (msg.tool_calls or [])]})
            if not msg.tool_calls:
                answer = _strip_think(msg.content)
                break
            messages.append(msg.model_dump(exclude_none=True))
            for tc in msg.tool_calls:
                try:
                    args = json.loads(tc.function.arguments or "{}")
                except json.JSONDecodeError:
                    args = {}
                t2 = time.time()
                out = call_tool(tc.function.name, args)
                steps.append({"type": "tool", "tool": tc.function.name, "args": args,
                              "ms": round((time.time() - t2) * 1000), "result": out[:400]})
                messages.append({"role": "tool", "tool_call_id": tc.id, "content": out})
        else:
            answer = "I could not finish within the step limit."
            status = "step_limit"
    except Exception as ex:
        status = "error"
        code = getattr(ex, "status_code", None)
        answer = f"The agent failed: {'HTTP ' + str(code) + ' from the LLM gateway: ' if code else ''}{ex}"
        log.warning("agent error: %r", ex)
    finally:
        dt = time.time() - t0
        REQUESTS.labels(version, model, status).inc()
        LATENCY.labels(version, model).observe(dt)
        TOKENS.labels(version, model, "prompt").inc(tokens["prompt"])
        TOKENS.labels(version, model, "completion").inc(tokens["completion"])
    trace_id = mlflow.get_active_trace_id()       # None when tracing is off (MLflow's predict_fn validation call)
    mlflow.update_current_trace(tags={"agent.status": status, "agent.steps": str(len(steps))})
    return {"answer": answer, "status": status, "prompt_version": version, "model": model,
            "steps": steps, "tokens": tokens, "seconds": round(time.time() - t0, 2), "trace_id": trace_id}


# ----------------------------------------------------------------------------- HTTP API
app = FastAPI(title="finops-agent")
app.mount("/metrics", make_asgi_app())


class Ask(BaseModel):
    question: str
    model: str = "cloud"
    prompt: str = "production"
    user: str = "demo-user"
    source: str = "ui"            # "load" for ./deploy.sh agentops load: judge_traces.py scores both


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/")
def index():
    return FileResponse(os.path.join(HERE, "ui.html"))


@app.get("/api/config")
def config():
    refresh_token()
    versions, aliases = [], {}
    try:
        for v in prompt_versions(mlflow, PROMPT_NAME):
            names = [str(a) for a in (v.aliases or [])]
            versions.append({"version": int(v.version), "commit": str(v.commit_message or ""), "aliases": names})
            for a in names:
                aliases[a] = int(v.version)
    except Exception as ex:
        log.warning("prompt registry: %r", ex)
    base = mlflow_ui_base()
    return {"models": MODELS, "prompt": PROMPT_NAME, "versions": sorted(versions, key=lambda v: int(v["version"])),
            "aliases": aliases, "tools": TOOL_ALLOWLIST, "experiment_id": EXPERIMENT_ID,
            "mlflow": base, "workspace": os.environ.get("MLFLOW_WORKSPACE", ""),
            "traces_url": f"{base}/#/experiments/{EXPERIMENT_ID}/traces",
            "console": os.environ.get("CONSOLE_URL", "")}


@app.post("/api/ask")
def ask(req: Ask):
    if not req.question.strip():
        raise HTTPException(400, "question is empty")
    return run_agent(req.question, req.model, req.prompt, source=req.source if req.source in ("ui", "load") else "ui",
                     user=req.user)


if __name__ == "__main__":
    log.info("finops-agent on :8080 (LLM %s, MCP %s, experiment %s)", LLM_BASE_URL, MCP_URL, EXPERIMENT_ID)
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="warning")
