"""
budget-api: a plain internal REST API (no AI in it) that the agent reaches through an MCP tool.
It owns the monthly LLM budget per team. It continues the caller's trace (W3C traceparent from
the MCP server), so the HTTP call shows up as its own span in the agent's trace, in MLflow and Tempo.

  GET /budgets            all teams
  GET /budgets/{team}     one team: monthly budget, owner, cost center
"""

import os
import time

from fastapi import FastAPI, HTTPException, Request
import uvicorn

from common import log, refresh_token, setup_mlflow

mlflow, _ = setup_mlflow()
from mlflow.tracing.distributed import set_tracing_context_from_http_request_headers  # noqa: E402

BUDGETS = {
    "payments":  {"monthly_budget_eur": 8.0, "owner": "Payments platform team", "cost_center": "CC-1100"},
    "search":    {"monthly_budget_eur": 4.0,  "owner": "Search team",            "cost_center": "CC-1200"},
    "support":   {"monthly_budget_eur": 2.0,  "owner": "Customer support tools", "cost_center": "CC-1300"},
    "marketing": {"monthly_budget_eur": 2.0,  "owner": "Marketing automation",   "cost_center": "CC-1400"},
}
DELAY = float(os.environ.get("BUDGET_API_DELAY_SECONDS", "0.15"))   # a "real" backend isn't instant

app = FastAPI(title="budget-api")


def traced(request: Request, name: str, fn):
    refresh_token()
    with set_tracing_context_from_http_request_headers(dict(request.headers)):
        with mlflow.start_span(name=name, span_type="TOOL") as span:
            span.set_attributes({"http.method": request.method, "http.route": request.url.path,
                                 "service.name": "budget-api"})
            time.sleep(DELAY)
            out = fn()
            span.set_outputs(out)
            return out


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.get("/budgets")
def all_budgets(request: Request):
    return traced(request, "budget-api GET /budgets", lambda: {"currency": "EUR", "budgets": BUDGETS})


@app.get("/budgets/{team}")
def one_budget(team: str, request: Request):
    def get():
        b = BUDGETS.get(team.lower())
        if not b:
            raise HTTPException(404, f"unknown team {team}; known: {', '.join(BUDGETS)}")
        return {"team": team.lower(), "currency": "EUR", **b}
    return traced(request, f"budget-api GET /budgets/{team}", get)


if __name__ == "__main__":
    log.info("budget-api on :8080")
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="warning")
