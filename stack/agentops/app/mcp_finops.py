"""
mcp-finops: an MCP server (Streamable HTTP, stateless JSON-RPC) with the FinOps agent's data tools.
Registered in the demo 15 MCP gateway (prefix finops_), so the agent reaches it like any MCP client:
through Connectivity Link (API key, per-tool rate limit, Limitador metrics).

  usage_by_team(days)            PostgreSQL: tokens and cost per team          (a dataset)
  usage_by_model(days, team?)    PostgreSQL: tokens and cost per model         (a dataset)
  team_budget(team)              budget-api: monthly budget, owner             (an internal API)

Tracing: each tools/call continues the caller's trace from the W3C `traceparent` header (or, if a
proxy dropped it, from params._meta.traceparent), and adds spans for the SQL query and the HTTP
call, so MLflow and Tempo show agent -> MCP tool -> database / API as one trace.
"""

import os
import time

import httpx
import psycopg2
import psycopg2.extras
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
import uvicorn

from common import log, refresh_token, setup_mlflow

mlflow, _ = setup_mlflow()
from mlflow.tracing.distributed import (  # noqa: E402
    get_tracing_context_headers_for_http_request, set_tracing_context_from_http_request_headers)

DB = dict(host=os.environ.get("PGHOST", "postgres"), dbname=os.environ.get("PGDATABASE", "finops"),
          user=os.environ.get("PGUSER", "agent_ro"), password=os.environ.get("PGPASSWORD", "agent-ro"))
BUDGET_API = os.environ.get("BUDGET_API_URL", "http://budget-api:8080")
PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"]


# ----------------------------------------------------------------------------- data access, traced
def sql(statement, params=()):
    with mlflow.start_span(name="postgres query", span_type="RETRIEVER") as span:
        span.set_inputs({"sql": " ".join(statement.split()), "params": list(params)})
        span.set_attributes({"db.system": "postgresql", "db.name": DB["dbname"], "db.user": DB["user"]})
        t0 = time.time()
        with psycopg2.connect(**DB, connect_timeout=5) as conn, \
                conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(statement, params)
            rows = [{k: (float(v) if hasattr(v, "as_integer_ratio") and not isinstance(v, int) else v)
                     for k, v in r.items()} for r in cur.fetchall()]
        span.set_attributes({"db.rows": len(rows), "db.duration_ms": round((time.time() - t0) * 1000)})
        span.set_outputs({"rows": rows[:20]})
        return rows


def http_get(path):
    with mlflow.start_span(name=f"GET budget-api{path}", span_type="TOOL") as span:
        span.set_attributes({"http.method": "GET", "http.url": f"{BUDGET_API}{path}"})
        # the child service continues this trace: same headers as any W3C-instrumented client
        r = httpx.get(f"{BUDGET_API}{path}", headers=get_tracing_context_headers_for_http_request(), timeout=10)
        span.set_attributes({"http.status_code": r.status_code})
        span.set_outputs(r.json())
        if r.status_code >= 400:
            raise ValueError(r.json().get("detail", r.text))
        return r.json()


# ----------------------------------------------------------------------------- tools
def _days(args):
    return max(1, min(int(args.get("days", 7)), 30))


def usage_by_team(args):
    d = _days(args)
    rows = sql("""SELECT team, sum(prompt_tokens + completion_tokens) AS tokens, sum(requests) AS requests,
                         sum(cost_eur) AS cost_eur
                  FROM llm_usage WHERE day > current_date - %s
                  GROUP BY team ORDER BY cost_eur DESC""", (d,))
    lines = [f"- {r['team']}: {r['tokens']:,} tokens, {r['requests']:,} requests, EUR {r['cost_eur']:.2f}" for r in rows]
    return f"LLM usage per team, last {d} days (most expensive first):\n" + "\n".join(lines)


def usage_by_model(args):
    d, team = _days(args), (args.get("team") or "").lower().strip()
    rows = sql("""SELECT u.model, p.provider, sum(prompt_tokens + completion_tokens) AS tokens,
                         sum(cost_eur) AS cost_eur
                  FROM llm_usage u JOIN model_prices p USING (model)
                  WHERE day > current_date - %s AND (%s = '' OR team = %s)
                  GROUP BY u.model, p.provider ORDER BY cost_eur DESC""", (d, team, team))
    who = f"team {team}" if team else "all teams"
    lines = [f"- {r['model']} ({r['provider']}): {r['tokens']:,} tokens, EUR {r['cost_eur']:.2f}" for r in rows]
    return f"LLM usage per model for {who}, last {d} days:\n" + ("\n".join(lines) or "(no usage)")


def team_budget(args):
    team = (args.get("team") or "").lower().strip()
    if not team:
        raise ValueError("team is required")
    b = http_get(f"/budgets/{team}")
    spent = sql("SELECT coalesce(sum(cost_eur), 0) AS spent FROM llm_usage WHERE team = %s AND day > current_date - 30",
                (team,))[0]["spent"]
    state = "OVER budget" if spent > b["monthly_budget_eur"] else "within budget"
    return (f"Team {team} ({b['owner']}, {b['cost_center']}): monthly LLM budget EUR {b['monthly_budget_eur']:.2f}, "
            f"spent EUR {spent:.2f} in the last 30 days: {state}.")


TOOLS = [
    {"name": "usage_by_team", "fn": usage_by_team,
     "description": "LLM token usage and cost in EUR per team over the last N days, most expensive first.",
     "inputSchema": {"type": "object", "properties": {
         "days": {"type": "integer", "minimum": 1, "maximum": 30, "default": 7}}}},
    {"name": "usage_by_model", "fn": usage_by_model,
     "description": "LLM token usage and cost in EUR per model (and its provider) over the last N days, "
                    "for one team or for all teams.",
     "inputSchema": {"type": "object", "properties": {
         "days": {"type": "integer", "minimum": 1, "maximum": 30, "default": 7},
         "team": {"type": "string", "description": "payments, search, support or marketing; empty = all"}}}},
    {"name": "team_budget", "fn": team_budget,
     "description": "A team's monthly LLM budget in EUR, its owner, and whether the last 30 days of spend "
                    "are within budget.",
     "inputSchema": {"type": "object", "properties": {
         "team": {"type": "string", "description": "payments, search, support or marketing"}},
         "required": ["team"]}},
]
BY_NAME = {t["name"]: t for t in TOOLS}


# ----------------------------------------------------------------------------- MCP over HTTP
app = FastAPI(title="mcp-finops")


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/mcp")
async def mcp(request: Request):
    msg = await request.json()
    mid, method, params = msg.get("id"), msg.get("method", ""), msg.get("params") or {}
    if mid is None:                     # notification (notifications/initialized)
        return Response(status_code=202)

    def ok(result):
        return JSONResponse({"jsonrpc": "2.0", "id": mid, "result": result})

    if method == "initialize":
        asked = params.get("protocolVersion", PROTOCOLS[0])
        return ok({"protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[0],
                   "capabilities": {"tools": {"listChanged": False}},
                   "serverInfo": {"name": "mcp-finops", "version": "1.0.0"}})
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": [{k: v for k, v in t.items() if k != "fn"} for t in TOOLS]})
    if method == "tools/call":
        name, args = params.get("name", ""), params.get("arguments") or {}
        tool = BY_NAME.get(name)
        if not tool:
            return JSONResponse({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": f"unknown tool {name}"}})
        headers = dict(request.headers)
        meta = params.get("_meta") or {}
        if "traceparent" not in headers and meta.get("traceparent"):
            headers["traceparent"] = meta["traceparent"]
        refresh_token()
        with set_tracing_context_from_http_request_headers(headers):
            with mlflow.start_span(name=f"mcp-finops {name}", span_type="TOOL") as span:
                span.set_inputs(args)
                span.set_attributes({"mcp.tool": name, "mcp.server": "mcp-finops",
                                     "mcp.via_gateway": bool(headers.get("x-mcp-toolname")),
                                     "traceparent.source": "header" if "traceparent" in request.headers else "_meta"})
                try:
                    text = tool["fn"](args)
                    span.set_outputs(text)
                    log.info("tool %s %s ok", name, args)
                    return ok({"content": [{"type": "text", "text": text}], "isError": False})
                except Exception as ex:      # a tool error is an answer for the model, not a crash
                    span.set_status("ERROR")
                    span.set_outputs(f"error: {ex}")
                    log.warning("tool %s failed: %r", name, ex)
                    return ok({"content": [{"type": "text", "text": f"Tool {name} failed: {ex}"}], "isError": True})
    if method in ("resources/list", "prompts/list"):
        return ok({method.split("/")[0]: []})
    return JSONResponse({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method not found: {method}"}})


if __name__ == "__main__":
    log.info("mcp-finops on :8080/mcp, database %s@%s, budget API %s", DB["dbname"], DB["host"], BUDGET_API)
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="warning")
