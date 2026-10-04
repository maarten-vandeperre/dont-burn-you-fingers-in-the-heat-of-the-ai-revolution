# Demo 5: Observability

**The story:** one request, every hop. Traces show the browser call, the Java services, Camel, the
mesh and the model call in one picture; metrics show tokens, latency and traffic splits; alerts
fire on fallbacks; and AI engineers get the same data as GenAI traces in MLflow.

**Duration:** 15 minutes (10 UI, 5 IntelliJ).

Every step below has three parts: **Do**, **You see**, **Say**.

---

## Before you start

1. Ask one question in the demo UI (**Ask (RAG)**, model **qwen**) and place one coffee order, so
   there are fresh traces.
2. Browser tabs: **OpenShift console**, **OpenShift AI**, **Kiali**, **Demo UI**.
3. **IntelliJ** on the repository folder.

---

## Part A: follow one request (5 minutes)

**A1. Find the trace.**
* **Do:** OpenShift console > **Observe** > **Traces**. Service **frontend**, newest trace (its
  duration is the model's generation time, 10 seconds or more). Click it.
* **You see:** a waterfall of spans:
  * `POST /api/ask` on frontend
  * rag-service: `rag.retrieve` (milliseconds), then the LangChain4j chat call
  * model-router: Camel route `chat-completions`, `direct:maas`, the call to the MaaS gateway
  * Envoy sidecar spans between the services
* **Say:** "The long bar at the end is the model. Retrieval took milliseconds. Without guessing, we
  know where the time goes, across five services and the mesh."

**A2. Same trace from the service's point of view.**
* **Do:** Kiali > **Workloads** > namespace **ai-demo** > **rag-service-v1** > tab **Traces**.
* **You see:** the same requests as dots by duration; click one for its spans.

---

## Part B: metrics, dashboards, alerts (5 minutes)

**B1. The application dashboard.**
* **Do:** OpenShift console > **Observe** > **Dashboards** > dashboard
  **AI demo: models, RAG, CDC, mesh and coffee**.
* **You see:** panels for model-router requests per alias and backend, tokens per second, p95
  generation latency per model and version, requests per rag-service version, CDC events, denied
  requests, and the coffee menu.
* **Say:** "Token usage and latency per model are first-class metrics, next to the classic ones. The
  version panel shows a canary split live during demo 3."

**B2. The OpenShift AI view.**
* **Do:** OpenShift AI > **Observe & monitor** > **Dashboard**. Tabs **Cluster**, **Models**, **Usage**.
* **You see:** cluster health, request and token throughput of both vLLM servers, usage per subscription.
* **Say:** "The platform team's view of the models: how busy they are and who uses them."

**B3. Alerts.**
* **Do:** OpenShift console > **Observe** > **Alerting**, filter on **ai-demo**.
* **You see:** the rules `ModelRouterFallingBackToOpenAI`, `ModelRouterErrors`, `RagSlowAnswers`,
  `CdcProjectionLagging`. After the fallback in demo 1, the first one goes Pending, then Firing.

**B4. Logs that point to traces.**
* **Do:** **Workloads** > **Pods** > a `model-router-...` pod > **Logs**.
* **You see:** JSON lines with `traceId`, the alias, the backend and token counts.

---

## Part C: AI traces in MLflow (3 minutes)

* **Do:** OpenShift AI > **Applications** > **MLflow UI**. Workspace **ai-demo**, experiment
  **coffee-shop**, tab **Traces**. Open the newest trace.
* **You see:** root span `coffee order` with the order as input and the priced items as output; below
  it the LangChain4j span with the prompt and the model's answer, and the menu lookups.
* **Say:** "Same OpenTelemetry data, a view made for AI engineers: what went into the model, what
  came out, how long it took."

---

## Part D: the configuration in IntelliJ (5 minutes)

**D1. Tracing is one line per service.**
* **Do:** open `app/rag-service/src/main/resources/application.properties`.
* **Point at:** `quarkus.otel.exporter.otlp.endpoint`. Quarkus traces REST, REST clients, JDBC,
  Kafka and LangChain4j automatically.

**D2. One collector, two destinations.**
* **Do:** open `stack/tracing/otel-collector.yaml`.
* **Point at:** pipeline **`traces`** (everything to Tempo) and **`traces/mlflow`** with
  `filter/mlflow` (only the coffee shop's AI spans, to MLflow).
* **Say:** "Applications send to one endpoint; the platform decides where traces go."

**D3. Business metrics in code.**
* **Do:** open `UsageRecorder.java` (app/model-router).
* **Point at:** `Counter.builder("ai.router.tokens")` with tags alias, backend, type.

**D4. Alerts and dashboard as code.**
* **Do:** open `app/deploy/monitoring/prometheus-rules.yaml` and `console-dashboard.yaml`.
* **Point at:** `alert: ModelRouterFallingBackToOpenAI` and its expression; the panel titles you saw.

---

## Part E: prove it from the terminal (optional)

```bash
./deploy.sh app ask "What does Debezium do?" qwen >/dev/null
oc logs deploy/model-router -n ai-demo -c app --tail=3
./deploy.sh usage --window 1h
```
Expected: a JSON log line with `alias=qwen backend=maas/qwen3-0-6b prompt_tokens=... completion_tokens=...`
and `traceId`; token and request lines per model and subscription.

Metric names for your own queries (console > **Observe** > **Metrics**): `ai_router_tokens_total`,
`ai_router_requests_total`, `ai_router_fallbacks_total`, `rag_generation_seconds_bucket`,
`cdc_events_total`, `istio_requests_total`.

## If something goes wrong

* **No traces:** `oc get pods -n tracing-system` (collector and Tempo Running); ask a new question.
* **OpenShift AI dashboard says "No datasource found":** `./deploy.sh dashboards`.
* **No MLflow traces:** `./deploy.sh app mlflow`, then place a coffee order.

vLLM's own spans (queueing, prefill, decode) need a vLLM image with OpenTelemetry and `--vllm-tracing`;
the Red Hat CPU image has none, so traces end at the MaaS gateway call.
