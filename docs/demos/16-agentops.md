# Demo 16: AgentOps — trace, monitor, version and judge an AI agent

**The story:** an AI agent in production is more than a model call. It loads a prompt, calls a
model (maybe several times), calls tools, and the tools hit databases and APIs. When the answer
is wrong, slow or expensive, you need to answer: *what did it do, with which prompt, which model,
which tools, how long, how many tokens, and was the answer any good?* AgentOps is the discipline
that answers those questions, the way DevOps does for services. This demo runs one small agent on
OpenShift AI and shows all of it, with the platform's own components:

| Question | Answered by | Where you see it |
|---|---|---|
| What did the agent do for this question? | **Tracing**: one trace per question: agent → LLM calls (messages, tokens) → MCP tool calls → SQL query / HTTP API call | MLflow (OpenShift AI) **Traces**; the same trace in **Tempo** (console: Observe > Traces) |
| How is it doing overall? Latency, tokens, errors, tool calls per prompt version and model | **Metrics** | Prometheus (console: Observe > Metrics) |
| Who used which model and tool, within which quota? | **The AI gateways of demo 15**: the agent and the judge are consumers with their own keys | Limitador metrics per consumer, per tool |
| Which prompt is in production, what changed, can we roll back? | **Prompt registry**: versions, commit messages, aliases | MLflow **Prompts** |
| Is the new prompt better, or just different? | **Judge model**: an evaluation dataset, scored by LLM judges and code checks, v1 vs v2 | MLflow **Evaluations** (runs side by side) |
| Are the answers in production still good? | **Judges on live traces**: scores attached to each trace | MLflow **Traces**, assessment columns |

**The agent:** a *FinOps assistant* for the company's LLM platform. It answers questions like
"Which team spent the most on LLMs last week, and is it within budget?" with three tools on an MCP
server: two SQL queries on a PostgreSQL dataset of LLM usage (the *dataset*), and a call to a
budget REST service (the *API*). It reaches its model and its tools only through the gateways of
[demo 15](15-ai-gateways.md): the **LLM API** (Connectivity Link + Praxis AI: key, quotas, model
aliases, OpenAI egress) and the **MCP gateway** (Connectivity Link MCP Gateway: one endpoint, per
tool authorization and limits).

```
                     namespace agentops                                            demo 15
 ┌──────────────────────────────────────────────────────────────────┐
 │ finops-agent  (UI, /api/ask, /metrics)                            │  Bearer <agent key>   ┌──────────────────────────┐
 │   1. prompt  prompts:/finops-agent@production ─────────────────────────────────────────▶│ MLflow (OpenShift AI)     │
 │   2. LLM     chat.completions  (model "cloud" / "smart") ───────────────────────────────▶│ llm-gateway /v2           │
 │   3. tools   MCP tools/call  + traceparent ──────────────────────────────────────────┐  │  Connectivity Link: key,  │
 │                                                                   │  APIKEY <agent>  │  │  5 req/s, tokens/min      │
 │ mcp-finops  (MCP server)  ◀───────────────────────────────────────────────────────────┘  │  Praxis: cloud→gpt-4o-mini│
 │   usage_by_team / usage_by_model ──▶ postgres (llm_usage, 30 days)│   via mcp-gateway   │  smart→qwen3-0-6b         │
 │   team_budget ──────────────────────▶ budget-api (REST)           │   (finops_ prefix,  └──────────────────────────┘
 └──────────────────────────────────────────────────────────────────┘    30 tool calls/min)
   every service: MLflow SDK spans ──▶ MLflow  (workspace agentops, experiment finops-agent)
                                   └─▶ OTel collector (tracing-system) ──▶ Tempo
   evaluate.py / judge_traces.py (in the agent pod): judge = "cloud" through the LLM API, consumer "judge"
```

| Component | What it is | Support |
|---|---|---|
| MLflow 3.10 (OpenShift AI 3.4, `MLflow` CR, component `mlflowoperator`) | tracing, prompt registry, evaluation datasets, LLM judges; one **workspace per OpenShift project**, access by Kubernetes RBAC | see the OpenShift AI 3.4 release notes for its support level |
| Tempo + OpenTelemetry collector (`stack/tracing`) | platform-wide traces, also of non-AI services | GA |
| User-workload monitoring | Prometheus for the agent's metrics | GA |
| Demo 15 gateways | Connectivity Link (GA), MCP Gateway (Technology Preview), Praxis AI (alpha) | see demo 15 |
| The agent, MCP server, budget API, scripts | ~750 lines of Python on the OpenShift AI MLflow image, code in a ConfigMap | demo code |

**Duration:** 30 minutes (A 4, B 7, C 4, D 6, E 9). Parts B, D and E also work on their own.

---

## Before you start

1. Installed: `./deploy.sh stack` (OpenShift AI with MLflow, tracing), demo 15's
   `./deploy.sh ai-gateways deploy` and `./deploy.sh ai-gateways mcp` (the LLM API and the MCP
   gateway). An OpenAI key for demo 15 (`./deploy.sh ai-gateways openai-key`) makes model `cloud`
   work; without it, use model `smart` (local Qwen) and a local judge (see "Variations").
2. Deploy this demo (about 5 minutes, the first time includes an image build):
   ```bash
   ./deploy.sh agentops deploy
   ./deploy.sh agentops test        # pods, prompt registry, one question end to end, the trace in MLflow and Tempo
   ```
3. Browser tabs:
   * the agent UI: `./deploy.sh agentops urls` (Route `finops-agent` in namespace `agentops`)
   * **MLflow**: OpenShift AI dashboard > **Applications** > **MLflow UI** (or the URL from
     `urls`), workspace **agentops**, experiment **finops-agent**
   * OpenShift console: **Observe > Traces** and **Observe > Metrics**
   * IntelliJ on `stack/agentops/`
4. Start from a known state: `./deploy.sh agentops prompts promote 1` (production = v1).

---

## Part A: the agent (4 minutes)

**A1. Ask it something.**
* **Do:** in the agent UI, model **cloud**, prompt **@production (v1)**, click the first preset:
  *"Which team spent the most on LLMs in the last 7 days, and is it within its budget?"* → **Ask**.
  (Terminal: `./deploy.sh agentops ask "Which team spent the most on LLMs in the last 7 days, and is it within its budget?"`)
* **What happens:**
  1. `run_agent` ([`agent.py`](../../stack/agentops/app/agent.py)) loads the system prompt
     `prompts:/finops-agent@production` from the MLflow prompt registry (Part D).
  2. It asks the MCP gateway for its tools once (`tools/list`) and keeps the four it's allowed to
     use (`AGENT_TOOLS`): `finops_usage_by_team`, `finops_usage_by_model`, `finops_team_budget`,
     `ops_get_limits`. The gateway offers more (`models_ask_model`, `ops_set_throttle`, …): an
     agent should only see the tools it needs.
  3. Loop, at most `AGENT_MAX_STEPS` = 5 times: send the conversation and the tool definitions to
     the LLM API (`/v2/chat/completions`, model `cloud`); if the model asks for tools, call each one
     through the MCP gateway and append the result; if it answers, stop.
  4. Here: the model asks for `finops_usage_by_team(days=7)` → the MCP server runs a SQL query on
     PostgreSQL; then for `finops_team_budget(team=support)` → the MCP server calls `budget-api`
     and one more SQL query; then it answers.
* **You see:** the answer (support, EUR 2.75 in 7 days, over its EUR 2.00 budget with EUR 3.41
  in 30 days), and on the left what the agent did:
  ```
  LLM  gpt-4o-mini  9426 ms  304 tokens  asks for: finops_usage_by_team
  MCP tool  finops_usage_by_team  755 ms   {"days": 7} → LLM usage per team, last 7 days …
  LLM  gpt-4o-mini  1138 ms  433 tokens  asks for: finops_team_budget
  MCP tool  finops_team_budget    790 ms   {"team": "support"} → … OVER budget.
  LLM  gpt-4o-mini  1583 ms  556 tokens  final answer
  ```
  plus the prompt version, total tokens, time and a trace id.
* **Say:** "Three LLM calls, two tool calls, a database and an API, for one question. That's
  normal for an agent, and it's exactly why you need more than request logs."

**A2. What it's wired to.** (IntelliJ, or just the slide)
* **Configured by:** [`openshift/cluster-params.env`](../../stack/agentops/openshift/) (written by
  `deploy`, becomes ConfigMap `agentops-params`) and the Deployment in
  [`apps.yaml`](../../stack/agentops/openshift/apps.yaml):
  ```bash
  MLFLOW_TRACKING_URI=https://rh-ai.<apps>/mlflow       # the OpenShift AI MLflow server
  MLFLOW_WORKSPACE=agentops                             # = this namespace
  MLFLOW_EXPERIMENT_NAME=finops-agent
  MLFLOW_TRACE_ENABLE_OTLP_DUAL_EXPORT=true             # every span also to ...
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://otel-collector.tracing-system.svc.cluster.local:4318/v1/traces
  LLM_BASE_URL=https://llm-gateway.<apps>/v2            # demo 15 LLM API (Connectivity Link + Praxis)
  MCP_URL=https://mcp-gateway.<apps>/mcp                # demo 15 MCP gateway
  JUDGE_MODEL=openai:/cloud                             # the judge (Part E), through the same LLM API
  ```
  ```yaml
  # apps.yaml, container "agent"
  - name: AGENT_API_KEY              # Connectivity Link consumer "agent" (gold): Secret agentops-keys
  - name: OPENAI_API_KEY             # consumer "judge" (gold): used by MLflow's judges
  ```
  ```python
  # agent.py: an ordinary OpenAI client, pointed at the gateway
  llm = OpenAI(base_url=LLM_BASE_URL, api_key=API_KEY)
  ```
  The agent never sees an OpenAI key, a model server URL or a database password: it has a
  gateway key for the LLM API and the MCP gateway, and a Kubernetes service account for MLflow.
  The database credentials (a read-only role, `agent_ro`) are only in the MCP server.

  One change to demo 15 made this simple: the LLM API's `AuthPolicy` (`llm-api-auth` in
  [`api-policies.yaml`](../../stack/ai-gateways/connectivity-link/api-policies.yaml)) accepts the
  consumer key as `Authorization: APIKEY <key>` **and** as `Authorization: Bearer <key>`, the way
  every OpenAI SDK, LangChain and LiteLLM (MLflow's judges) send it:
  ```yaml
  authentication:
    api-key-consumers: {apiKey: {selector: …}, credentials: {authorizationHeader: {prefix: APIKEY}}}
    api-key-bearer:    {apiKey: {selector: …}, credentials: {authorizationHeader: {prefix: Bearer}}}
  ```
  Authorino accepts a request when *any* identity source matches.
* **Say:** "The agent is a client of the platform, like any other: it gets a key, a quota and a
  workspace, not credentials to everything."

---

## Part B: tracing — one trace across agent, model, tools, database and API (7 minutes)

**B1. The trace in MLflow.**
* **Do:** in the agent UI, click the trace id (or MLflow > workspace **agentops** > experiment
  **finops-agent** > **Traces**, newest row). Open the span tree.
* **What happens:** every step left a span while the agent ran; MLflow assembled them into one
  trace with the id the UI shows. The spans and where they come from:
  ```
  finops-agent              AGENT       @mlflow.trace on run_agent: question in, answer out,
  │                                     tags prompt.version, llm.model, source; user and session
  ├─ Completions            CHAT_MODEL  mlflow.openai.autolog(): messages, tool definitions, the
  │                                     model's tool call, tokens (input/output), latency
  ├─ call_tool              TOOL        @mlflow.trace on call_tool: tool name and arguments
  │  └─ mcp-finops usage_by_team  TOOL  the MCP server (another pod), continuing the same trace
  │     └─ postgres query   RETRIEVER   the SQL statement, row count, duration
  ├─ Completions            CHAT_MODEL
  ├─ call_tool              TOOL
  │  └─ mcp-finops team_budget    TOOL
  │     ├─ GET budget-api/budgets/support  TOOL   HTTP call from the MCP server
  │     │  └─ budget-api GET /budgets/support      the budget API (a third pod)
  │     └─ postgres query   RETRIEVER
  └─ Completions            CHAT_MODEL  final answer
  ```
* **You see:** in each `Completions` span the exact messages the model got (system prompt v1,
  the question, the tool results) and what it returned; the token counts; the SQL the tool ran;
  what the budget API answered. The trace's **Prompts** section links to `finops-agent` v1.
* **Say:** "When someone says 'the agent said support is over budget, is that true?', this is
  the answer: the query, the numbers it got, and how the model turned them into a sentence."

**B2. One trace across three pods, through a gateway.**
* **What happens:** the `mcp-finops` and `budget-api` spans are created in other pods, yet they
  sit in the same trace. That's W3C trace context propagation:
  1. In `call_tool`, the agent adds the current span's context to the MCP request:
     `get_tracing_context_headers_for_http_request()` → a `traceparent` header (and the same value
     in `params._meta.traceparent`, in case a proxy drops headers).
  2. The request goes through the MCP gateway (Envoy + the MCP router, which also re-routes it
     to `finops.mcp.local`); the header survives.
  3. The MCP server continues the trace:
     `with set_tracing_context_from_http_request_headers(request.headers): with mlflow.start_span(...)`,
     and does the same towards `budget-api`.
  4. Each pod sends its own spans to MLflow with the same trace id; MLflow merges them.
  The span attribute `traceparent.source` on the MCP server's span says whether the header or
  the `_meta` fallback was used: on this cluster it's `header`.
* **Configured by:** [`agent.py`](../../stack/agentops/app/agent.py) (`Mcp._post`, `call_tool`),
  [`mcp_finops.py`](../../stack/agentops/app/mcp_finops.py) (`mcp()`, `sql()`, `http_get()`),
  [`budget_api.py`](../../stack/agentops/app/budget_api.py) (`traced()`).
* **Say:** "Distributed tracing for agents: the tool call isn't a black box, even when the tool
  lives in another team's service behind a gateway."

**B3. The same trace in Tempo.**
* **Do:** console > **Observe > Traces**, Tempo instance `tracing-system/platform`, service
  **finops-agent** (or search the trace id without the `tr-` prefix).
* **What happens:** with `MLFLOW_TRACE_ENABLE_OTLP_DUAL_EXPORT=true` and
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, the MLflow SDK exports every span twice: to MLflow and,
  as plain OpenTelemetry, to the platform collector ([`otel-collector.yaml`](../../stack/tracing/otel-collector.yaml),
  pipeline `traces` → Tempo). The image adds the OTLP exporter package for that
  ([`build.yaml`](../../stack/agentops/openshift/build.yaml)). Tempo shows three services:
  `finops-agent`, `mcp-finops`, `budget-api`.
* **You see:** the same span tree as a Gantt chart, next to every other service on the platform.
* **Say:** "Two audiences, one instrumentation: the AI engineer reads prompts and tokens in
  MLflow, the SRE sees latency per service in Tempo, and nobody instrumented twice."

**B4. What it took in code.**
* **Do:** in IntelliJ, `agent.py`: `mlflow.openai.autolog()`, `@mlflow.trace(name="finops-agent", span_type="AGENT")`,
  `@mlflow.trace(span_type="TOOL")`, `mlflow.update_current_trace(tags=…, metadata=…)`.
* **What happens:** autolog wraps the OpenAI client (no change to the LLM call itself); the two
  decorators make the agent and tool spans; `update_current_trace` adds the searchable tags
  (`prompt.version`, `llm.model`, `source`) and MLflow's standard `mlflow.trace.user` /
  `mlflow.trace.session` metadata. Everything else (MLflow endpoint, workspace, token, Tempo) is
  environment, not code. [`common.py`](../../stack/agentops/app/common.py) re-reads the
  service account token before use, because it rotates.
* **Say:** "Two decorators and one autolog line. Tracing that costs that little gets switched on."

---

## Part C: monitoring — the agent, the gateways, the bill (4 minutes)

**C1. Agent metrics.**
* **Do:** console > **Observe > Metrics** (namespace `agentops`):
  ```promql
  # questions per prompt version, model and outcome
  sum by (prompt_version, model, status) (increase(agent_requests_total{namespace="agentops"}[1h]))
  # tokens per question, per prompt version: what a prompt change costs
  sum by (prompt_version) (increase(agent_llm_tokens_total{namespace="agentops"}[1h]))
    / sum by (prompt_version) (increase(agent_requests_total{namespace="agentops"}[1h]))
  # p90 latency per prompt version
  histogram_quantile(0.9, sum by (le, prompt_version) (rate(agent_request_seconds_bucket{namespace="agentops"}[30m])))
  # tool calls and their errors
  sum by (tool, status) (increase(agent_tool_calls_total{namespace="agentops"}[1h]))
  ```
  Generate some traffic first: `./deploy.sh agentops load 8`.
* **What happens:** the agent exposes Prometheus metrics on `/metrics/` (`prometheus_client`,
  labelled by prompt version, model, tool); `ServiceMonitor finops-agent`
  ([`apps.yaml`](../../stack/agentops/openshift/apps.yaml)) makes user-workload monitoring scrape
  them every 15 s. Evaluations (Part E) run in a separate process and don't count here: these
  are production numbers.
* **You see:** e.g. p90 latency 9 s with prompt v1 and 14 s with v2, and v2 using more tokens per
  question (it calls more tools and writes a "Sources" line).
* **Say:** "Traces explain one request; metrics tell you the trend, and when it changes, which
  prompt version was live."

**C2. The gateway's view: the agent as a consumer.**
* **Do:** `./deploy.sh agentops metrics`, or in Observe > Metrics:
  ```promql
  sum by (user, limitador_namespace, tool) (authorized_hits{user=~"llm-key-(agent|judge)"})
  ```
* **What happens:** the agent calls the LLM API as consumer `llm-key-agent` and the MCP gateway
  with the same key; the judge calls the LLM API as `llm-key-judge`. Demo 15's
  `TelemetryPolicy` objects label Limitador's counters with `user`, `tier` and (MCP) `tool`.
* **You see:** e.g.
  ```
  {limitador_namespace="ai-gateways/llm-api-v2",   user="llm-key-agent"}  116   LLM calls (tokens counted on the TokenRateLimitPolicy)
  {limitador_namespace="ai-gateways/llm-api-v2",   user="llm-key-judge"}   87   the judge's LLM calls
  {limitador_namespace="mcp-gateway/mcp-finops",   user="llm-key-agent", tool="usage_by_team"}  …
  {limitador_namespace="mcp-gateway/mcp-ops",      user="llm-key-agent", tool="get_limits"}     …
  ```
* **Say:** "The platform team doesn't need the agent's cooperation to know what it costs: every
  model call and every tool call went through a gateway that counted it, per consumer and per
  tool. And evaluation isn't free: the judge has its own line."

**C3. Who knows what.**

| Layer | Knows | Doesn't know |
|---|---|---|
| Agent traces (MLflow) | prompt version, messages, tool arguments and results, tokens per call | other consumers |
| Tempo | latency per service, across the whole platform | prompts, tokens |
| Agent metrics | trends per prompt version / model / tool | individual requests |
| Gateways (Limitador) | every consumer's calls, tokens, tools; enforcement (429) | why the agent made the call |

---

## Part D: prompt management (6 minutes)

**D1. The registry.**
* **Do:** MLflow > **Prompts** > **finops-agent** (or `./deploy.sh agentops prompts show`).
* **What happens:** `deploy` registered two versions with
  [`prompts.py`](../../stack/agentops/app/prompts.py):
  ```python
  mlflow.genai.register_prompt("finops-agent", V1, commit_message="v1: minimal system prompt", tags={...})
  mlflow.genai.register_prompt("finops-agent", V2, commit_message="v2: tool-grounded numbers, budget check, sources line", tags={...})
  mlflow.genai.set_prompt_alias("finops-agent", "production", 1)
  mlflow.genai.set_prompt_alias("finops-agent", "staging", 2)
  ```
  Versions are immutable; aliases (`production`, `staging`) are movable pointers. The template
  uses `{{today}}`, filled in by the agent (`p.format(today=…)`). In OpenShift AI, a prompt is a
  registered model in the workspace (RBAC resource `registeredmodels` in `mlflow.kubeflow.org`),
  so who may change prompts is a Kubernetes `RoleBinding`
  ([`namespace.yaml`](../../stack/agentops/openshift/namespace.yaml)).
* **You see:** v1 (two lines) and v2 (five rules: numbers only from tools, "last week" = 7 days,
  check the budget of a team you name, max 4 sentences in EUR, end with "Sources:"), the commit
  messages, the aliases, and v1 ⇄ v2 as a diff.
* **Say:** "Prompts are code that changes faster than code. Here they get versions, commit
  messages, a diff, and a production pointer, outside the container image."

**D2. Promote v2, live.**
* **Do:** in MLflow, on version 2, **move the `production` alias** (or
  `./deploy.sh agentops prompts promote 2`). Ask the same question again in the UI with prompt
  **@production**.
* **What happens:** the agent loads `prompts:/finops-agent@production` on every question, with
  `cache_ttl_seconds=PROMPT_CACHE_TTL` (15 s, [`agent.py`](../../stack/agentops/app/agent.py)
  `load_prompt`). Within 15 s it resolves the alias to version 2. No restart, no redeploy, no
  image. Rollback is moving the alias back.
* **You see:** the answer now ends with `Sources: usage_by_team, team_budget`; the meta line
  says **prompt v2**; the new trace is tagged `prompt.version = 2` and linked to v2. Tested: the
  switch shows up after 13 s.
* **Say:** "Release a prompt like a feature flag: move a pointer, watch the traces and the
  metrics, move it back if needed."

**D3. Pin a version, compare.**
* **Do:** in the UI, pick prompt **version 1** and **version 2** explicitly and ask the same
  question twice.
* **What happens:** a number means `prompts:/finops-agent/<n>` (immutable, cached forever); an
  alias means "whatever production is now". Evaluations (Part E) always pin versions.
* **Say:** "Every trace records the exact version, so 'which prompt produced this answer?' is
  never a guess."

---

## Part E: the judge model (9 minutes)

**E1. Offline evaluation: v1 versus v2, scored by a judge.**
* **Do:** `./deploy.sh agentops eval 1 2` (about 3 minutes), then MLflow > experiment
  **finops-agent** > **Evaluations** (or **Runs**): `prompt v1 (cloud, judge openai:/cloud)` and
  `prompt v2 (…)`, side by side.
* **What happens:** [`evaluate.py`](../../stack/agentops/app/evaluate.py), run inside the agent pod:
  1. **The dataset:** `finops-agent-eval`, an MLflow evaluation dataset (created once,
     `datasets.create_dataset` + `merge_records`) with 5 questions and, per question, the
     **expected facts** ("support is over its monthly budget", …).
  2. **The agent under test:** `predict_fn` calls the same `run_agent` as production, with the
     prompt version pinned, model `cloud`. Each answer is a trace, linked to the run.
  3. **The judges** (`JUDGE_MODEL = openai:/cloud`, i.e. gpt-4o-mini through the LLM API as
     consumer `judge`):
     * `Correctness`: are the expected facts supported by the answer? (built in, uses the
       expectations)
     * `RelevanceToQuery`: does it answer the question? (built in)
     * `Guidelines(name="cites_sources")`: "ends with a line starting with 'Sources:'"
       (built in, your rule in plain language)
     * `budget_aware`: a custom judge (`make_judge`, E2)
  4. **Code scorers** on the trace: `used_tools` (number of tool calls: 0 = it made the numbers
     up) and `total_tokens` (from the `CHAT_MODEL` spans).
  5. One MLflow run per prompt version, tags `prompt.version`, `llm.model`, `judge`.
* **You see:** two runs on this cluster, same code, same dataset:

  | | v1, run 1 | v2, run 1 | v1, run 2 | v2, run 2 |
  |---|---|---|---|---|
  | correctness | 0.80 | 1.00 | 1.00 | 1.00 |
  | relevance_to_query | 1.00 | 1.00 | 1.00 | 1.00 |
  | cites_sources | **0.00** | **1.00** | **0.00** | **1.00** |
  | budget_aware | – | – | 1.00 | 0.80 |
  | used_tools (per question) | 1.4 | 1.6 | 1.4 | 1.6 |
  | total_tokens (per question) | **961** | **1371** | **956** | **1368** |

  (run 1 was before `budget_aware` had an aggregation, see E2.) Per question, each judge's
  **rationale** and the trace of the answer.

  Read it honestly: two things are stable, `cites_sources` (v2 follows its rule, v1 has no such
  rule) and the cost (+43% tokens per question). The rest moves between runs by one question out
  of five: the judges are LLMs too, and five questions is a small sample. That's the second
  lesson of this part.
* **Say:** "'v2 is better' is now a measurement: it always cites its sources, and it costs 43%
  more tokens. Whether it's *more correct* this dataset can't tell yet: v1 scored 0.80 once and
  1.00 once. Grow the dataset, repeat runs, and look at the rationales before you trust a 0.2
  difference."

**E2. Your own judge, and checks that need no judge.**
* **Configured by:** `evaluate.py`:
  ```python
  budget_aware = make_judge(
      name="budget_aware", model=JUDGE, feedback_value_type=float,
      instructions=("The user asked: {{ inputs }}\nThe assistant answered: {{ outputs }}\n"
                    "Score 1.0 if the answer is about a specific team's cost or budget AND says whether that "
                    "team is within or over its budget, or if no specific team is involved at all. ..."))
  budget_aware.aggregations = ["mean"]      # custom judges aren't averaged per run by default

  @scorer
  def used_tools(trace) -> int:             # code, on the trace: no LLM, no cost, deterministic
      return len([s for s in trace.data.spans if s.span_type == "TOOL" and s.name == "call_tool"])
  ```
* **What happens:** `make_judge` turns a business rule into an LLM judge with a template over
  `{{ inputs }}` / `{{ outputs }}` (it can also take `{{ expectations }}` or the whole
  `{{ trace }}`). Code scorers get the trace object: anything you can compute from spans
  (tool calls, tokens, latency, a forbidden tool) is a free, exact check.
* **Say:** "Use an LLM judge where you need judgement, and code where you can count."

**E3. Judge production: scores on live traces.**
* **Do:** `./deploy.sh agentops load 6` (live traffic, prompt @production), then
  `./deploy.sh agentops judge 12`. In MLflow > **Traces**, the assessment columns
  (`relevance_to_query`, `cites_sources`, `budget_aware`, `used_tools`, `total_tokens`) are filled
  in; filter or sort on them, open one to read the rationale.
* **What happens:** [`judge_traces.py`](../../stack/agentops/app/judge_traces.py) searches the
  newest traces tagged `source = ui` / `load` (`mlflow.search_traces`) and passes them to
  `mlflow.genai.evaluate(data=traces, scorers=…)`: no `predict_fn`, nothing is re-run; the judges
  read the recorded question and answer, and every result is written back to its trace as an
  assessment (feedback with value, rationale and source). `Correctness` isn't used here: live
  questions have no known right answer.
* **You see:** e.g. over 12 traces, `relevance_to_query` 1.00, `cites_sources` 0.67 (the v1
  traces in the mix don't cite sources), `budget_aware` 0.83. Filter the traces on
  `cites_sources = no` and every one of them is tagged `prompt.version = 1`.
* **Say:** "The same judges, on real traffic: quality monitoring for answers, not only for
  latency. Schedule this, alert on the score, and you know a model or prompt change hurt quality
  before the users tell you."

**E4. The judge is a consumer too.**
* **What happens:** MLflow's judges call the model with LiteLLM: a plain OpenAI request to
  `OPENAI_API_BASE` (the LLM API) with `Authorization: Bearer $OPENAI_API_KEY` (consumer
  `judge`). So the judge is authenticated, throttled (5 req/s), token-limited (20 000/min) and
  metered like any consumer. `evaluate.py` keeps the evaluation's parallelism at 3 workers
  (`MLFLOW_GENAI_EVAL_MAX_WORKERS`, `…_MAX_SCORER_WORKERS`) so a run stays inside those limits;
  when it still hits a 429, LiteLLM retries.
* **Say:** "Evaluation costs tokens and hits the same quotas: give the judge its own key, so you
  can see and cap what quality assurance costs."

---

## Variations

* **A local model as the agent:** pick model **smart** (Qwen3 0.6B on CPU, via Praxis) in the
  UI. vLLM serves it with tool calling (`--enable-auto-tool-choice --tool-call-parser hermes`), so
  the loop works: *"Is the payments team within its LLM budget?"* with prompt v2 → Qwen calls
  `finops_team_budget`, answers correctly and adds the Sources line (2 LLM calls, 1 426 tokens,
  10 s on CPU). But a 0.6B model picks tools and reads results far less reliably on harder
  questions: run
  `EVAL_AGENT_MODEL=smart` (`oc set env deploy/finops-agent EVAL_AGENT_MODEL=smart`, then
  `./deploy.sh agentops eval 2`) and compare the runs. That's the judge's job: telling you how
  much worse.
* **A local judge:** `oc set env deploy/finops-agent JUDGE_MODEL=openai:/smart`. Works without
  OpenAI, but a 0.6B judge is a weak judge; in a real setup, use the strongest model you can
  afford as the judge, not the one under test.
* **Guardrails apply to the agent too:** model `cloud` goes out through demo 15's `openai-egress`
  listener, so a question about *coffee* or *lemons*, or containing an email address, is
  refused (403) before it reaches OpenAI, and the trace shows the 403 in the `Completions` span.
* **Prompt optimization:** MLflow 3.10 also has `mlflow.genai.optimize_prompts` (automatic
  prompt rewriting against a dataset and judges): the next step after E1, not shown here.

---

## Part in IntelliJ

| File (`stack/agentops/`) | Point at |
|---|---|
| `app/agent.py` | `mlflow.openai.autolog()`, the two `@mlflow.trace` decorators, `update_current_trace` tags, `load_prompt(... cache_ttl_seconds)`, `Mcp._post` adding `traceparent`, the Prometheus `Counter`s |
| `app/mcp_finops.py` | `set_tracing_context_from_http_request_headers`, the `RETRIEVER` span around SQL, `get_tracing_context_headers_for_http_request` towards the API |
| `app/prompts.py` | `register_prompt`, `set_prompt_alias`, the two templates |
| `app/evaluate.py` | the dataset with `expected_facts`, `Correctness` / `RelevanceToQuery` / `Guidelines`, `make_judge`, the `@scorer` functions |
| `app/judge_traces.py` | `search_traces` → `evaluate(data=traces)`: judges without re-running anything |
| `openshift/namespace.yaml` | the two MLflow ClusterRoles bound to the service account: MLflow access is Kubernetes RBAC |
| `openshift/apps.yaml` | env from `agentops-params`, the two consumer keys, `ServiceMonitor` |
| `openshift/mcp-registration.yaml` | `ReferenceGrant` + `HTTPRoute` + `MCPServerRegistration`: a team's MCP server on the shared gateway |
| `openshift/build.yaml` | `FROM` the OpenShift AI MLflow image + OTLP exporter + tenacity |
| `ai-gateways/connectivity-link/api-policies.yaml` | `api-key-bearer`: OpenAI-style clients on the LLM API |

---

## Prove it from the terminal

```bash
./deploy.sh agentops test           # pods, prompts, one question (finops_team_budget), the trace with all four hops in MLflow, the trace in Tempo
./deploy.sh agentops ask "Why did the support team's LLM cost go up?"
./deploy.sh agentops prompts show
./deploy.sh agentops prompts promote 2
./deploy.sh agentops load 6
./deploy.sh agentops eval 1 2       # v1: correctness 0.80, cites_sources 0.00 · v2: 1.00, 1.00, more tokens
./deploy.sh agentops judge 12       # assessments on the newest live traces
./deploy.sh agentops metrics        # agent metrics + Limitador counters for llm-key-agent / llm-key-judge
```

## Reset

```bash
./deploy.sh agentops prompts promote 1     # production back to v1
oc rollout restart deploy/postgres -n agentops   # reseed the dataset relative to today (emptyDir)
./deploy.sh agentops destroy               # namespace agentops, the MCP registration, the two consumer keys
```
MLflow keeps traces, runs, datasets and prompts in its database; a redeploy into the same
namespace finds them again (`prompts register` leaves an existing prompt alone).

---

## If something goes wrong

* **`deploy`: PostgreSQL `CrashLoopBackOff`, `role "finops" does not exist`:** the seed must run
  from `postgresql-start/` (every start, after the image created the user and database), not
  `postgresql-init/` (before that). After a failed first start the emptyDir keeps the broken
  data across container restarts: delete the pod.
* **The agent's answer is `HTTP 401 from the LLM gateway`:** the `api-key-bearer` identity is
  missing in `llm-api-auth` (`oc apply -f stack/ai-gateways/connectivity-link/api-policies.yaml`),
  or Secret `agentops-keys` holds an old key (`./deploy.sh agentops deploy` recreates both keys).
* **`HTTP 403` from the LLM gateway with model `cloud`:** the consumer isn't gold (Praxis
  `tier-gate`), or the question tripped the OpenAI guardrails (coffee, lemons, an email address).
* **No `mcp-finops` / `budget-api` spans in the trace:** check `oc logs deploy/mcp-finops -n agentops`
  for the tool call, and the `traceparent.source` attribute on its span; if the MCP server got
  neither the header nor `_meta`, the trace starts fresh there (a separate trace in MLflow).
* **`eval` hangs, no requests from `llm-key-judge`:** several judge threads importing LiteLLM for
  the first time at once deadlock on Python's import lock; `evaluate.py` imports it up front. If
  you write your own evaluation script, do the same.
* **Judge scores are empty, rationale `tenacity import failed`:** the judge got a 429 from the LLM
  API and LiteLLM's retry needs `tenacity` (in the image since build 2: `oc start-build
  agentops-runtime -n agentops`). Lower `MLFLOW_GENAI_EVAL_MAX_WORKERS` if it keeps happening.
* **A custom judge has scores per row but no `/mean` metric:** custom `make_judge` judges have no
  aggregation by default: set `judge.aggregations = ["mean"]`.
* **`search_prompt_versions() is not supported in this registry`:** that call is for Databricks
  Unity Catalog; in the OpenShift AI registry, iterate `get_prompt_version(name, n)`
  (`common.prompt_versions`).
* **`Invalid clause(s) in filter string: 'OR'`:** trace search filters support `AND` only; run one
  search per value.
* **The UI's trace link opens MLflow without the trace:** pick workspace **agentops** in MLflow
  first (the dashboard remembers the last one), then click the link again.
* **The alias moved but the agent still uses the old version:** wait `PROMPT_CACHE_TTL` (15 s).
