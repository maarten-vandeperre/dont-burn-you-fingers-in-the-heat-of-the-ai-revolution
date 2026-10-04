# AI platform demo applications

Seven Quarkus services (Java 25, Gradle, Quarkus 3.40 LTS) and two React UIs (Vite + Tailwind) that
put the OpenShift 4.22 stack from `../stack` to work: RAG on the MaaS models and OpenAI, a Camel
model abstraction, Service Mesh security and deployment patterns, and change data capture from
PostgreSQL to MongoDB, all traced, logged and measured.

```
 browser
    |  https (Route, edge TLS)
    v
 ai-demo-gateway (Istio ingress) ......................... namespace ai-demo, STRICT mTLS, deny-all
    |
 frontend  (Quarkus BFF + React UI)
    |---------------------------|-------------------------------|
    v                           v                               v
 rag-service v1 | v2         orders-service                 projection-service
 (LangChain4j, BM25 RAG)     (Hibernate Panache)            (Kafka consumer)
    |                           |                               |   ^
    v                           v                               v   | Debezium events
 model-router (Apache Camel)  inventory-db (PostgreSQL) --> Kafka Connect + Debezium --> Kafka
    |  gemma | qwen | openai | auto                                                     |
    |-> MaaS gateway -> vLLM Gemma 3 270M / Qwen3 0.6B                          MongoDB <-'
    '-> api.openai.com  (fallback for "auto")                                  (read model)

 every hop -> OpenTelemetry collector -> Tempo        metrics -> user workload monitoring
```

Plus **Platform Coffee** (`coffee-shop`, `coffee-menu`), the coffee app from the "owning the
inference layer" talk, extended: LangChain4j ordering through the model-router, prices from a
menu service (v1/v2) behind the mesh with fault tolerance (timeout, retry, circuit breaker,
cached fallback), orders in PostgreSQL and an audit trail that Debezium builds in MongoDB.
Route: `https://coffee-ai-demo.<apps-domain>`. Walkthrough: `../docs/demos/07-coffee-shop.md`.

Plus **`camel-ai-demo`**: a local, single-instance Camel demo for the laptop (Camel JBang, no
cluster needed): one API for Qwen on Podman Desktop AI Lab, OpenAI and Anthropic with central key
configuration, local-first fallback, file system routes, routes enabled and added live, and route
design in Kaoto with Hawtio at runtime. See `camel-ai-demo/README.md`.

And **`coffee-guardrails`**: a standalone, laptop-sized demo of NeMo Guardrails (the TrustyAI
build that OpenShift AI runs) around a coffee order app (Quarkus + React), with Qwen on Podman
Desktop AI Lab or OpenAI behind it, orchestrated with podman compose: coffee-only topic, 200
character input and output limits, PII masking, prompt-injection regex and "no cappuccino after
noon". See `coffee-guardrails/README.md` and `coffee-guardrails/DEMO.md`.

And **`software-templates/llm-app`**: the Developer Hub template that starts a new LLM
application (Quarkus + LangChain4j + React) from a two-step form: metadata (name, description,
package name) and model selection (use case, t-shirt size). See `software-templates/README.md`.

## What each piece demonstrates

| Topic | Where | How to show it |
|---|---|---|
| RAG with local models and OpenAI | `rag-service` (LangChain4j `ChatModel` per alias, `PromptTemplate`, BM25 retrieval over `docs/`) | UI tab "Ask", or `./demo.sh ask "..." qwen` |
| AI model abstraction with Camel | `model-router`: content based router on the alias, circuit breaker with fallback to OpenAI, token metrics, `x-model-backend` header | ask with `auto`, scale the vLLM predictor to 0, ask again: OpenAI answers |
| mTLS | `mesh/peer-authentication.yaml` (STRICT) | `./demo.sh mtls`: a pod outside the mesh is rejected |
| Who can access who | `mesh/authorization-policies.yaml`: deny-all + per-identity ALLOW (HTTP and TCP) | UI tab "Mesh access" or `./demo.sh probe`: frontend -> model-router = 403, frontend -> MongoDB = closed |
| Canary | `patterns/canary.yaml` | `./demo.sh pattern canary 25`, then `./demo.sh traffic 200` |
| A/B | `patterns/ab.yaml` (header `x-variant: b`) | `./demo.sh pattern ab`, tick "x-variant: b" in the UI (v2 answers with bullets and citations) |
| Blue-green | `patterns/blue.yaml`, `patterns/green.yaml` | `./demo.sh pattern blue`, `pattern green`, back to `blue` |
| Mirroring | `patterns/mirror.yaml` | `./demo.sh pattern mirror`: all answers from v1, v2 logs and Kiali show the shadow copies |
| Automated canary | `overlays/rollouts`: model-router as Argo Rollout with Istio subset routing | `./demo.sh deploy --rollouts`, then `./demo.sh rollout` |
| CDC, PostgreSQL -> MongoDB | `orders-service` writes, Debezium captures, `projection-service` keeps one formatted document per customer (orders, totals, last change, history) | UI tab "CDC" or `./demo.sh cdc` |
| Tracing | `quarkus-opentelemetry` everywhere, Camel spans, LangChain4j spans, JDBC + MongoDB spans, Envoy sidecar spans, one collector (vLLM spans with `--vllm-tracing` and an image that has OpenTelemetry) | console > Observe > Traces, service `frontend` |
| Monitoring | Micrometer (`ai_router_*`, `rag_*`, `cdc_*`, `orders_*`) merged with Envoy metrics, PrometheusRule alerts, console dashboard | console > Observe > Dashboards > "AI demo" |
| Logging | `quarkus-logging-json`: JSON lines with `traceId` / `spanId` | `oc logs deploy/model-router -c app -n ai-demo` |
| Tekton | `deploy/pipelines`: git clone -> buildah -> internal registry -> rollout restart | `./demo.sh pipeline <git-url>` (e.g. the GitLab repo) |
| Coffee: AI + CDC audit | `coffee-shop` orders (PostgreSQL) > Debezium > `projection-service` > MongoDB `coffee_audit` | coffee shop Audit tab, `./demo.sh coffee` |
| Coffee: releases + chaos | `coffee-menu` v1/v2, `patterns/menu-*.yaml` (canary, blue, green, mirror, delay, abort) | `./demo.sh menu delay 50`, Menu & resilience tab |

## In Developer Hub

Everything here is also in Developer Hub (system `ai-demo`): components with Topology and
Kubernetes views, APIs, dependencies on the models, Kafka, Debezium and the databases, Tekton runs
and Argo CD status (after `./demo.sh gitops <git-url>`). Under Create, the platform templates
switch traffic patterns, drive the model-router rollout and scale services and models, so the
whole demo can be run from the portal instead of `demo.sh`.

## Run it

Requires the platform stack (`./deploy.sh stack` in the repository root) and a logged in `oc`.

```bash
cd app
export OPENAI_API_KEY=sk-...        # optional: enables alias "openai" and the fallback of "auto"
./demo.sh all                       # setup + in-cluster builds + deploy (~15 min the first time)
./demo.sh urls
```

Step by step: `./demo.sh setup` creates the namespace, a long-lived MaaS API key for the router
(premium subscription if your user is in `maas-premium-users`, otherwise free), copies the
inventory-db credentials and writes `deploy/base/cluster-params.env`. `./demo.sh build` uploads
this folder and builds all five images in the cluster (OpenShift binary Docker builds); no local
JDK, Node or registry needed. `./demo.sh deploy` applies `deploy/` (base + mesh + monitoring).

A suggested demo flow:

1. **Ask** tab with `qwen`, then `gemma`, then `openai`: same retrieval, different models. Open the
   trace: frontend -> rag-service (`rag.retrieve` span) -> model-router (Camel route) -> MaaS -> vLLM.
2. **Mesh access** tab: allowed calls succeed, frontend -> model-router gets `403 RBAC: access denied`,
   MongoDB is closed for everyone but the projection-service. `./demo.sh mtls` shows that plaintext
   callers outside the mesh are rejected.
3. **Traffic patterns**: `pattern canary 10` -> `traffic 200` (about 20 v2), `pattern ab` and
   the header, `pattern blue` / `green`, `pattern mirror`. Keep Kiali's versioned app graph open.
4. **CDC** tab: create a customer, place orders, delete one; the MongoDB document follows within
   a second or two, including totals and history.
5. **Dashboard**: tokens per backend, p95 latency per model, request split per version, CDC events,
   denied calls.

## Local development

```bash
./gradlew :model-router:quarkusDev -Dquarkus.http.port=8081      # MAAS_URL, MAAS_API_KEY in env
./gradlew :rag-service:quarkusDev -Dquarkus.http.port=8082       # ROUTER_URL=http://localhost:8081/v1
cd frontend/src/main/webui && npm install && npm run dev         # UI on :5173, /api -> :8080
./gradlew :frontend:quarkusDev                                   # RAG_URL=http://localhost:8082
```

The Gradle wrapper pins Gradle 9.1; the build uses a Java 25 toolchain (downloaded through the
foojay resolver if your JDK is older). Images: `podman build -f Dockerfile --build-arg SERVICE=rag-service .`
and `podman build -f frontend/Dockerfile .`, both from this folder.

## Notes

* **Retrieval is lexical (BM25)** so the demo needs no embedding model or vector database. Swap
  `KnowledgeBase` for a LangChain4j `EmbeddingStoreContentRetriever` (pgvector + an embedding model
  on MaaS) for semantic search; the RAG flow stays the same.
* **v1 and v2 of the rag-service** are the same image with different settings (top-k 3 vs 5,
  short answer vs cited bullets), which keeps the deployment patterns easy to observe.
* **MaaS quota:** the free subscription allows 5000 tokens per minute per model; RAG prompts are
  about 600 to 1500 tokens. Add your user to `maas-premium-users` before `./demo.sh setup` for
  heavier demos. The traffic view uses a cheap endpoint and does not call the models.
* **TLS to MaaS:** `MAAS_TRUST_ALL=true` in `deploy/base/cluster-params.env` accepts the
  self-signed ingress certificate of lab clusters. Set it to `false` with a trusted certificate.
* **MongoDB** uses the community image `mongo:8.0` without database authentication; access is
  enforced by the mesh (only the projection-service identity may connect).
* **Argo CD:** `deploy/` is plain Kustomize, so an Argo CD Application can sync it. Build the
  images first, and add an `ignoreDifferences` on `VirtualService/rag-service` if you want to keep
  switching patterns with `demo.sh` while Argo CD self-heals the rest.
