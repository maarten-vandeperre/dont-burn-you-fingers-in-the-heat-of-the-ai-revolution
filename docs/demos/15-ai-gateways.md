# Demo 15: AI gateways compared — Praxis AI, Connectivity Link, OpenShift AI MaaS

**The story:** "AI gateway" means three different things at Red Hat today. All three sit in front of
the **same two models** on this cluster (`qwen3-0-6b`, `gemma-3-270m-it` in `maas-models`), so the
only thing that changes between them is the gateway:

* **Praxis AI** (Red Hat Emerging Technologies, open source, alpha): an AI-aware **proxy**. One
  Deployment and one YAML file. It understands the request body: routes on the `model` field,
  translates Anthropic ⇄ OpenAI (including streaming), counts tokens and time to first token per
  model. It does not handle identity, quotas per consumer, or a self-service portal.
* **Red Hat Connectivity Link** (Kuadrant, GA): **API management policies** for Gateway API.
  `AuthPolicy`, `RateLimitPolicy`, `TokenRateLimitPolicy` attach to any Gateway or HTTPRoute.
  It understands who the caller is and how many tokens they used. It does not read the body
  (no model routing, no protocol translation).
* **OpenShift AI Models-as-a-Service** (MaaS, part of OpenShift AI 3.x): the **product** built on
  Connectivity Link. You declare `MaaSModelRef`, `MaaSAuthPolicy` and `MaaSSubscription`; the MaaS
  controller generates the Connectivity Link policies, and you also get API keys, the dashboard,
  a `/v1/models` listing per key, and usage metrics. On this cluster (OpenShift AI 3.4) MaaS
  routes per model on the path (`/maas-models/<model>/v1/...`), like Connectivity Link.

The point to land: **these are layers, not competitors.** MaaS *is* Connectivity Link plus an
opinionated model catalog. Praxis is an AI data plane that can sit next to it or in front of it
(Part D: Praxis gives Anthropic clients like Claude Code access to MaaS-governed models, on one
URL with the model in the body), or behind it (Part F: Connectivity Link as the front door of an
LLM API product, Praxis doing everything that needs the request body, driven from a web console).

**What this demo does *not* show: context-based routing.** Praxis routes on the model the
client *names* in the body (`model_to_header`); it does not read the prompt to *choose* a model
(no "easy question → Gemma, hard question → Qwen"). Praxis 0.9.0 has no prompt classifier for
model selection: `intelligent_route` still selects a backend for the requested model (freshness,
site), and its classifier routing is for MCP and A2A agent traffic. For prompt-based routing in
this repository, see the Camel model router (`auto` alias) in
[demo 1](01-models-and-rag.md).

**Duration:** 25 minutes for Parts A to E (5 Part A, 6 Part B, 5 Part C, 4 Part D, 5 Part E), plus
20 minutes for Part F (Connectivity Link + Praxis, with the AI Gateway Console). Each part also
works on its own; Part F is the one to pick for a "what does an AI gateway do for me" audience.

```
                                   namespace ai-gateways                                namespace maas-models
                    ┌──────────────────────────────────────────────────────┐        ┌─────────────────────────┐
 praxis-ai ────────▶│ Praxis AI :8080  model_to_header ─▶ router ─────────┼──TLS──▶│ qwen3-0-6b              │
 praxis-ai-limited ▶│           :8081  + rate_limit (2/s, burst 4)         │        │  (LLMInferenceService,  │
                    │                                                      │        │   vLLM CPU, :8000 HTTPS)│
 llm-gateway ──────▶│ Gateway llm-gateway (openshift-default)              │        │                         │
                    │   HTTPRoute /qwen3-0-6b/v1/*, /gemma-3-270m-it/v1/* ─┼──TLS──▶│ gemma-3-270m-it         │
                    │   AuthPolicy (API key + tier), TokenRateLimitPolicy  │        │                         │
                    │                                                      │        │ ReferenceGrants allow   │
 port-forward ────▶│ Praxis AI :8082  Anthropic ⇄ OpenAI ──┐ (own key)    │        │ ai-gateways routes in   │
                    └───────────────────────────────────────┼──────────────┘        └───────────▲─────────────┘
                                                            ▼                                    │
 maas.<domain> ───────────────────────────▶ maas-default-gateway (openshift-ingress) ────────────┘
                                             generated AuthPolicy + TokenRateLimitPolicy per model,
                                             MaaS API keys, subscriptions (namespace models-as-a-service)
```

| | Praxis AI | Connectivity Link | OpenShift AI MaaS |
|---|---|---|---|
| What it is | AI proxy (Rust, Pingora) | Gateway API policy layer (Kuadrant: Authorino + Limitador + wasm in Envoy) | Product on top of Connectivity Link + KServe |
| Install | 1 Deployment + 1 ConfigMap, no CRDs | Operator, CRDs, policies on any Gateway | OpenShift AI operator, `modelsAsService` |
| Config | one YAML file, hot-reloaded | Kubernetes CRDs per Gateway / route | 3 CRDs (`MaaSModelRef`, `MaaSAuthPolicy`, `MaaSSubscription`) |
| Routing on the model in the body | ✅ native (`model_to_header`) | ❌ path / header / query only | ❌ on this cluster (3.4): `/maas-models/<model>/v1/...` |
| One URL for all models | ✅ | ❌ one path prefix per model | ❌ one path per model, but `/v1/models` lists them per key |
| Context-based routing (prompt picks the model) | ❌ (not in 0.9.0) | ❌ | ❌ |
| Anthropic Messages ⇄ OpenAI Chat | ✅ incl. streaming | ❌ | OpenAI-compatible API (Anthropic clients: Praxis in front, Part D) |
| Authentication | ❌ (not in this config; mTLS / basic auth only). Strips client credentials on Anthropic translation, injects its own (`credential_injection`) | ✅ API key, JWT/OIDC, K8s tokens, OPA | ✅ MaaS API keys, OpenShift tokens |
| Authorization per model / tier | ❌ | ✅ CEL / OPA | ✅ groups in `MaaSAuthPolicy` |
| Rate limit | requests per listener (token bucket, global or per IP) | requests **and tokens**, per consumer, per tier | tokens per user per subscription |
| Token metrics | ✅ per model, TTFT histogram | ✅ Limitador counters per consumer | ✅ + dashboards, usage reports |
| API keys / self-service | ❌ | Dev Portal CRDs (demo 10) | ✅ dashboard + `/maas-api/v1/api-keys` |
| Content guardrails (block secrets, mask personal data) | ✅ native `guardrails` filter: regex / keywords / built-in PII detectors, block only (Part F); masking and richer policies by calling NeMo Guardrails with `ai_guardrails` (Part E) | ❌ not built in (policies see headers and identity, not prompts) | ❌ not in the MaaS gateway; OpenShift AI ships guardrails as TrustyAI services (NeMo Guardrails, Guardrails Orchestrator) |
| MCP / A2A, Responses API state | ✅ (some experimental) | ❌ | ❌ |
| Support | alpha, community | GA, Red Hat supported | GA in OpenShift AI 3.x |

---

## Before you start

1. Needs the platform stack (OpenShift AI with MaaS, Connectivity Link and both models):
   ```bash
   ./deploy.sh stack            # if not done yet
   ./deploy.sh test             # both models answer through MaaS
   ```
2. Deploy the two extra gateways (2 minutes, idempotent):
   ```bash
   ./deploy.sh ai-gateways deploy
   ./deploy.sh ai-gateways test     # every line OK (MaaS: see "If something goes wrong")
   ./deploy.sh ai-gateways urls
   ```
   `deploy` creates namespace `ai-gateways`, Praxis AI, the Connectivity Link `llm-gateway` and
   two consumer keys: **alice** (`free`: Gemma only, 300 tokens/min) and **bob** (`gold`: both
   models, 20 000 tokens/min). The keys are written to `stack/ai-gateways/.keys.env` (git-ignored).
   It also builds and deploys the **AI Gateway Console** for Part F (a few minutes, in the cluster).
   For the OpenAI scenarios of Part F, `export OPENAI_API_KEY=sk-...` before `deploy`, or run
   `./deploy.sh ai-gateways openai-key` afterwards.
3. Load the endpoints and keys in your terminal:
   ```bash
   source stack/ai-gateways/.keys.env
   P=https://$(oc get route praxis-ai -n ai-gateways -o jsonpath='{.spec.host}')
   PL=https://$(oc get route praxis-ai-limited -n ai-gateways -o jsonpath='{.spec.host}')
   oc port-forward -n ai-gateways svc/praxis-ai 18082:8082 >/dev/null 2>&1 &   # Part D, no public Route
   PM=http://127.0.0.1:18082
   PG=https://$(oc get route praxis-ai-guarded -n ai-gateways -o jsonpath='{.spec.host}')   # Part E
   G=https://$(oc get route llm-gateway -n ai-gateways -o jsonpath='{.spec.host}')
   M=https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
   MAAS_KEY=$(./deploy.sh ai-gateways maas-key)
   ```
4. Browser tabs: **OpenShift AI dashboard** (Models as a service, API keys), **OpenShift console**
   (Observe > Metrics; Networking > Gateways / HTTPRoutes in `ai-gateways`; the Kuadrant policy
   view), and IntelliJ on `stack/ai-gateways/`.
5. Warm the CPU models once: `./deploy.sh ai-gateways compare` (the first call can take a minute).

---

## Part A: Praxis AI, the AI-aware proxy (5 minutes)

**A1. One URL, the model decides.**
* **Do:**
  ```bash
  chat() { curl -sk "$1/v1/chat/completions" -H 'content-type: application/json' "${@:3}" \
             -d "{\"model\":\"$2\",\"max_tokens\":30,\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}]}"; echo; }
  chat $P qwen3-0-6b      | jq -r '.model, .choices[0].message.content'
  chat $P gemma-3-270m-it | jq -r '.model, .choices[0].message.content'
  chat $P gpt-4o -o /dev/null -w '%{http_code}\n'              # 404: unknown model
  ```
* **What `chat` does:** it is a shell shortcut for one OpenAI Chat Completions call:
  `chat <base-url> <model> [extra curl options]`. It sends
  ```
  POST <base-url>/v1/chat/completions
  content-type: application/json

  {"model": "<model>", "max_tokens": 30, "messages": [{"role": "user", "content": "Say hi"}]}
  ```
  `-sk` keeps curl quiet and accepts the lab cluster's self-signed certificate, `"${@:3}"` passes
  any further arguments straight to curl (the third line uses that for `-o /dev/null -w
  '%{http_code}'`: print only the HTTP status), and `echo` adds the missing newline. `jq` then
  prints the `model` that answered and the answer text. Note what is **not** in the request: no
  model in the URL, no header that names the model. The only place the model is named is the body.
* **What happens in Praxis** (listener `direct`, `:8080`, route `praxis-ai`; chains in
  [`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml)):
  1. `observability`: a request id and an access-log line.
  2. `classify`: `ai_operation` recognises an OpenAI chat request from method + path;
     `openai_chat_completions_request` parses the JSON body; `model_to_header` copies
     `"model": "qwen3-0-6b"` into a request header `X-Model: qwen3-0-6b` (replacing any `X-Model`
     the client sent).
  3. `translate`: does nothing here (only for Anthropic `/v1/messages`, A2).
  4. `models`: the `router` matches path `/v1/` **and** header `x-model: qwen3-0-6b` → cluster
     `qwen`; `load_balancer` opens TLS to
     `qwen3-0-6b-kserve-workload-svc.maas-models.svc.cluster.local:8000`, verified with the
     OpenShift service CA, and forwards the request unchanged. On the way back `token_count` and
     `time_to_first_token` record `praxis_ai_*_tokens_total{model="qwen3-0-6b"}` and the TTFT (A3).
  5. Same URL, `"model": "gemma-3-270m-it"` → `X-Model: gemma-3-270m-it` → cluster `gemma`.
     `"model": "gpt-4o"` → no route matches that header → Praxis answers **404** itself; no model
     server is contacted.
* **Configured by** ([`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml), ConfigMap
  `praxis-ai-config`). Follow `chat $P gemma-3-270m-it` through the file, top to bottom:
  ```yaml
  # (1) $P is Route praxis-ai -> Service praxis-ai port "direct" -> this listener
  listeners:
    - name: direct
      address: "0.0.0.0:8080"
      filter_chains: [observability, classify, translate, models]   # run in this order

  filter_chains:
    # (2) body {"model": "gemma-3-270m-it", ...}  ->  header  X-Model: gemma-3-270m-it
    - name: classify
      filters:
        - filter: ai_operation
        - filter: openai_chat_completions_request
          conditions: [{when: {path: "/v1/chat/completions"}}]
        - filter: model_to_header
          header: X-Model

    # (3) the header picks the cluster; the cluster says where that model runs
    - name: models
      filters:
        - filter: router
          routes:
            - path_prefix: "/v1/"
              headers:
                x-model: qwen3-0-6b          # X-Model: qwen3-0-6b      -> cluster qwen
              cluster: qwen
            - path_prefix: "/v1/"
              headers:
                x-model: gemma-3-270m-it     # X-Model: gemma-3-270m-it -> cluster gemma   <- our request
              cluster: gemma
            # no route for x-model: gpt-4o   -> 404 from Praxis, nothing is called
        - filter: token_count                # tokens per model, read from the answer's usage block
          provider: openai
        - filter: time_to_first_token
        - filter: load_balancer
          clusters:
            - name: gemma                    # (4) cluster gemma = the KServe workload of the model
              endpoints:
                - "gemma-3-270m-it-kserve-workload-svc.maas-models.svc.cluster.local:8000"
              tls:
                sni: gemma-3-270m-it-kserve-workload-svc.maas-models.svc.cluster.local
                ca: {ca_path: /etc/service-ca/service-ca.crt}   # OpenShift service CA
            # - name: qwen ... (same shape, qwen3-0-6b-kserve-workload-svc)
  ```
  The request is forwarded unchanged (same path `/v1/chat/completions`, same body), so vLLM in the
  Gemma pod receives `"model": "gemma-3-270m-it"`, which is the name it serves, and answers. That's why
  the client must use the exact served name here; the aliases of Part F (`fast` → Gemma) also
  rewrite the name in the body (`model_to_provider`, `target_model`).
  See it happen: `oc logs deploy/praxis-ai -n ai-gateways | grep 'access method' | tail -3` shows
  `cluster="gemma" upstream="gemma-3-270m-it-kserve-workload-svc...:8000"` per request.
* **You see:** both models answer on the **same** URL; an unknown model is a 404 from Praxis itself.
* **Say:** "Every OpenAI client points at one base URL. Praxis reads `model` from the JSON body,
  copies it into an `X-Model` header (`model_to_header`) and routes on that. Gateway API can't do
  this: it matches paths and headers, never the body."

**A1, devil's advocate: "that's just header-based routing, why not Istio, Connectivity Link or Camel?"**

The router at the end *is* header-based. The point is where the header comes from: **the client
never sends it.** An OpenAI client (the Python/JS SDK, LangChain, Continue, Claude Code through
A2) only knows a base URL and puts the model in the JSON body. `X-Model` is created inside Praxis
by `model_to_header`, after it has read and parsed that body. Take that step away and every
option below has to answer "how do I get the model out of the body?":

| Option | Can it route on `"model"` in the body? | What it costs |
|---|---|---|
| **Gateway API / Istio** (HTTPRoute, VirtualService) | No. Matches are path, method, headers and query parameters; Envoy's router never looks at the body. | Works only if **every client sends a header** (`-H 'x-model: …'`, `default_headers` in the SDK) or uses a path per model (Part B, MaaS on 3.4). A client that sets one header but a different `model` gets one model's routing and another's name: the gateway trusts a header it can't check against the body. |
| **Istio + body-to-header extension** | Yes, with extra parts: an `ext_proc` server (e.g. the body-based router of the Gateway API Inference Extension, which is what MaaS's `payload-processing` filter in `openshift-ingress` is for), or Lua/wasm code in an EnvoyFilter. | Another service in every request's path, or code in the proxy, which you build, run and upgrade yourself. It gives you the routing header, nothing else: no protocol translation, token counting or guardrails. |
| **Connectivity Link** | No. Its policies see headers, path and identity. `requestBodyJSON()` doesn't exist on the request side (Part F, "If something goes wrong": using it breaks the rate limits); it only reads the *response* body (`usage.total_tokens`). | Same as Gateway API: it's a policy layer *on* Gateway API, not a different router. It decides **who** may call, not **which model** gets the call. |
| **Camel** | Yes: parse the JSON, `choice().when(jsonpath("$.model") …)`, `toD(...)`. Demo 1's Camel model router does exactly that, and even chooses the model from the prompt. | It's an application you write, build and deploy, in Java, with your own HTTP handling: streaming (SSE) pass-through, Anthropic ⇄ OpenAI translation incl. streaming, token metrics, TLS to the workloads, back-pressure. Right tool when the routing is business logic (content-based, calling other services); a lot of code for "proxy this request to the right model". |
| **Praxis** | Yes, as config: `model_to_header` + `router` (A1) or one `model_to_provider` table (Part F). | Alpha. In return, the body is parsed once and the same parse feeds the routing, translation (A2), token counting (A3), guardrails (E, F3) and model aliases (F1). |

So the honest comparison isn't "Praxis vs header routing". It's **who turns the body into a
routing decision**: every client (headers), an extra service next to Envoy (`ext_proc`), your
own application (Camel), or the AI gateway itself (Praxis). Once the decision is a header, Istio
and Connectivity Link handle it fine, which is exactly how Part F splits the work. Connectivity
Link routes on **path and headers** (`/v1` vs `/v2`, `x-api-version`) and decides **who** may
call. Praxis, behind it, reads the **body**.

When *not* to use Praxis for this: if all clients are yours and can send a model header, or one
path per model is acceptable (MaaS's choice on 3.4), plain Gateway API is enough and you skip a
hop. If the model should be picked from the *content* of the prompt, that's Camel's job (demo 1),
not Praxis 0.9.0's.

**A2. Anthropic clients on OpenAI-only models.**
* **Do:**
  ```bash
  curl -sk $P/v1/messages -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"qwen3-0-6b","max_tokens":30,"messages":[{"role":"user","content":"hello"}]}' | jq '{id,type,stop_reason,usage}'
  curl -skN $P/v1/messages -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"gemma-3-270m-it","max_tokens":10,"stream":true,"messages":[{"role":"user","content":"hello"}]}' | grep '^event' | uniq -c
  ```
* **What happens:** same `direct` listener as A1, but now the path is `/v1/messages` (Anthropic).
  1. `classify`: `anthropic_messages_request` (condition `path: /v1/messages`) parses the Anthropic
     body; `model_to_header` sets `X-Model` from its `model` field, exactly as in A1.
  2. `translate`: `anthropic_messages_to_chat_completions` rewrites the body to OpenAI Chat
     (`system` → a system message, content blocks → plain messages, `max_tokens`, `stream`);
     `path_rewrite` turns `/v1/messages` into `/v1/chat/completions`. It also drops the client's
     `x-api-key` / `Authorization` (an Anthropic credential must never reach an OpenAI backend).
  3. `models`: routed on `X-Model` like A1; vLLM answers in OpenAI format.
  4. On the way back the same filter turns the OpenAI answer into an Anthropic `message`
     (`id: msg_chatcmpl-…`, `stop_reason`, `usage.input_tokens/output_tokens`). With `"stream": true`
     the answer is `text/event-stream`, so `anthropic_messages_to_chat_completions_stream` (its
     `response_conditions` match that content type) converts every OpenAI SSE chunk into Anthropic
     events: `message_start`, `content_block_delta`…, `message_stop`.
  Config: chains `classify` and `translate` in [`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml).
* **You see:** an Anthropic-format reply (`"type":"message"`, `"id":"msg_chatcmpl-…"`), and a
  streamed Anthropic event sequence: `message_start`, `content_block_delta` ×N, `message_stop`.
* **Say:** "vLLM speaks OpenAI Chat. Praxis translates the request, the path and the response,
  streaming included. An Anthropic-only client such as Claude Code can now use models served by
  OpenShift AI."

**A2, devil's advocate: "Camel translates Anthropic too, we have it in this repo. Why Praxis?"**

Camel *can* do this; it's an integration framework and JSON-to-JSON mapping is its home ground.
But look at what the two Camel apps in this repository actually translate:

| | Camel in this repo ([`camel-ai-demo`](../../app/camel-ai-demo/README.md), [`camel-ai-router`](../../app/camel-ai-router/README.md)) | Praxis in A2 |
|---|---|---|
| Direction | **outbound**: the caller speaks Camel's own API (`/api/chat/{provider}`) or OpenAI; Camel *calls* Anthropic as a backend (`AnthropicGateway`, `AnthropicClient`) | **inbound**: the caller speaks the **Anthropic** API (`/v1/messages`), the backend speaks OpenAI |
| Who must adapt | the client uses Camel's API | nobody: Claude Code is pointed at a base URL (`ANTHROPIC_BASE_URL`), nothing else changes |
| Streaming | request/response (no SSE) | OpenAI SSE chunks re-emitted as Anthropic events (`message_start`, `content_block_delta`…, `message_stop`) |
| Effort | a route / class per provider, built and deployed | two filters and a `path_rewrite` in the existing proxy config |

Turning Camel into what A2 does means implementing the **Anthropic Messages API as a server**:
- the request: top-level `system`, content blocks, `stop_sequences`, `max_tokens`, `tools`;
- the response: `content` blocks, `stop_reason`, `usage.input_tokens` / `output_tokens`, Anthropic
  error bodies;
- **streaming**: an Anthropic stream is a stateful event sequence (open a message, open a content
  block, deltas, close the block, a `message_delta` with the usage, close the message), built
  chunk by chunk from OpenAI's very different stream, while it flows. Camel routes usually work on
  whole message bodies, so streaming means low-level code next to the routes. Coding agents like
  Claude Code stream by default, so this is the part that matters.

That is a protocol adapter you own, test against each client release, and keep up to date as the
API grows. In Praxis it's maintained once, upstream, and runs in the same pass as routing (A1)
and token counting (A3).

When Camel is still the better choice: the "translation" is really **business logic**. Examples:
a stable company API in front of changing providers (what `camel-ai-demo` does), fallback between
providers with your own health rules (`camel-ai-router`), or a call that also needs files, Kafka,
a database or a human approval. A proxy shouldn't do that.

Honest limit of A2: we checked plain messages and streaming here. Claude Code also relies heavily
on **tool use** (`tool_use` / `tool_result` blocks ⇄ OpenAI `tool_calls`), and a 0.6B CPU model is
a weak tool caller anyway. Try your real client and a capable model before you promise it.

**A3. Tokens and time to first token, per model.**
* **Do:** `./deploy.sh ai-gateways metrics` (Praxis section), or in the console **Observe > Metrics**:
  ```promql
  sum by (model) (rate(praxis_ai_output_tokens_total{namespace="ai-gateways"}[5m]))
  ```
* **What happens:** nothing new is sent; you read what A1 and A2 left behind. In the `models` chain,
  response filters run in reverse order, so `token_count` (`provider: openai`) reads the OpenAI
  `usage` block of every answer *before* A2's translation rewrites it, and adds it to
  `praxis_ai_prompt_tokens_total` / `praxis_ai_output_tokens_total{model, cluster}`.
  `time_to_first_token` measures the time until the first response byte (`praxis_ai_ttft_seconds`).
  For streams there's normally no `usage` at all; `stream_usage_inject` adds
  `stream_options.include_usage: true` to every streaming request, so vLLM sends a final chunk with
  usage that `token_count` can read. Praxis exposes all of it on `:9902/metrics`; the
  `ServiceMonitor praxis-ai` ([`deployment.yaml`](../../stack/ai-gateways/praxis/deployment.yaml))
  makes OpenShift's user-workload Prometheus scrape it every 15 s, and `./deploy.sh ai-gateways
  metrics` reads the endpoint directly with `oc exec`.
* **You see:** `praxis_ai_prompt_tokens_total`, `praxis_ai_output_tokens_total` and
  `praxis_ai_ttft_seconds` labelled by `model` and `cluster`.
* **Say:** "Token accounting from the gateway, not from the model server. `stream_usage_inject`
  turns on `include_usage` for every streaming request, so streamed tokens count too."

**A4. A rate limit, and what it doesn't know.**
* **Do:** `./deploy.sh ai-gateways burst` (first half).
* **What happens:** `burst` fires 20 `GET /v1/models` at once at Route `praxis-ai-limited`, which
  points at the `limited` listener (`:8081`, chains `observability, throttle, catalog-v1, …`).
  `throttle` is a `rate_limit` filter in `mode: global`: one token bucket for the whole listener,
  holding at most `burst: 5` tokens and refilled with `rate: 5` per second. Each request takes a
  token; with the bucket empty Praxis answers **429** immediately. The 5 that got a token reach
  `catalog-v1`, a `static_response` that answers `/v1/models` with a fixed JSON list: no model is
  called, so the burst costs nothing. `rate_limit` is a security filter (no conditions allowed),
  which is why the limited variant is a separate listener instead of a condition on `direct`.
* **You see:** of 20 parallel requests, 5 pass (200: Praxis answers `/v1/models` itself) and 15 get **429**.
* **Say:** "That's a token bucket on requests, the same for everybody. Praxis has no idea who is
  calling, so it can't give alice and bob different limits. That's where Connectivity Link comes in."

**A5. Hot reload.** (optional)
* **Do:** `oc edit configmap praxis-ai-config -n ai-gateways`, change `rate: 5` to `rate: 50`, then
  `oc logs deploy/praxis-ai -n ai-gateways | grep 'reload complete'` and repeat the burst.
* **What happens:** the ConfigMap is mounted as a *directory* (no `subPath`) at `/etc/praxis`, so
  the kubelet replaces the file in the running pod when the ConfigMap changes (on its next sync, up
  to about a minute). Praxis watches the file, parses and validates the new config, builds new
  pipelines and swaps them in per listener (`config reload complete swapped=[…]` in the log).
  Requests in flight finish on the old pipeline; stateful filters such as the rate-limit bucket
  start empty. If the new file is invalid, the reload is refused (`config reload failed`) and the
  old config keeps serving.
* **Say:** "No restart: routes, clusters, filters and limits are swapped live, and an invalid config
  is rejected while the old one keeps serving."

---

## Part B: Connectivity Link, policies on Gateway API (6 minutes)

**B1. The same models behind a plain Gateway.**
* **Do:** OpenShift console > **Networking > Gateways** (`llm-gateway`) and **HTTPRoutes**
  (`llm-models`) in project `ai-gateways`; then
  ```bash
  curl -sk -o /dev/null -w '%{http_code}\n' $G/gemma-3-270m-it/v1/chat/completions -d '{}'      # 401
  ```
* **What happens:** `$G` is Route `llm-gateway` (edge TLS at the OpenShift router) → Service
  `llm-gateway-openshift-default` → the Envoy pod that the `openshift-default` GatewayClass (the
  Istio inside OpenShift's ingress operator) created for `Gateway llm-gateway`. The Kuadrant
  operator turned the policies on the route into a wasm filter config in that Envoy (EnvoyFilter
  `kuadrant-llm-gateway`). Envoy matches the path `/gemma-3-270m-it/v1/` to a rule of
  `HTTPRoute llm-models`; for that rule the wasm filter first asks Authorino (the AuthPolicy). There
  is no `Authorization: APIKEY …` header, so Authorino says no and Envoy answers **401**: the model
  is never contacted. Config: [`gateway.yaml`](../../stack/ai-gateways/connectivity-link/gateway.yaml),
  [`httproute.yaml`](../../stack/ai-gateways/connectivity-link/httproute.yaml).
* **You see:** one path prefix per model (`/qwen3-0-6b/v1/…`, `/gemma-3-270m-it/v1/…`), and
  **401** without a key.
* **Say:** "Same GatewayClass as MaaS, `openshift-default`, but nothing OpenShift AI generated.
  Everything this gateway knows about callers and tokens comes from two policies we attach to the
  route."

**B2. Identity and authorization per tier.**
* **Do:**
  ```bash
  cl() { curl -sk -o /tmp/r.json -w "%{http_code}  " "$G/$2/v1/chat/completions" -H "Authorization: APIKEY $1" \
           -H 'content-type: application/json' -d "{\"model\":\"$2\",\"max_tokens\":30,\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}]}"; jq -c .usage /tmp/r.json 2>/dev/null || cat /tmp/r.json; echo; }
  cl $KEY_ALICE gemma-3-270m-it     # 200
  cl $KEY_ALICE qwen3-0-6b          # 403: free tier
  cl $KEY_BOB   qwen3-0-6b          # 200: gold tier
  ```
* **What happens**, for `cl $KEY_ALICE qwen3-0-6b`:
  1. Envoy matches the rule for `/qwen3-0-6b/v1/` in `HTTPRoute llm-models`; the wasm filter sends
     the request's headers to Authorino.
  2. Authorino runs `AuthPolicy llm-models-auth`: **authentication** looks for a Secret labelled
     `llm-gateway/consumer=true` whose `api_key` equals the value after `APIKEY `. That Secret
     (`llm-key-alice`) becomes `auth.identity`.
  3. **authorization**: the CEL rule `request.path.startsWith("/gemma-3-270m-it/") ||
     auth.identity.metadata.annotations["llm-gateway/tier"] == "gold"` is false for alice on Qwen →
     **403**. For alice on Gemma, or bob anywhere, it's true.
  4. On success, `response.success.filters.identity` publishes `auth.identity.userid` (the Secret
     name) and `auth.identity.tier` (the annotation) for the token limits (B3).
  5. Envoy applies the route: `URLRewrite` turns `/qwen3-0-6b/v1/chat/completions` into
     `/v1/chat/completions` and sends it to `qwen3-0-6b-kserve-workload-svc` in `maas-models`
     (allowed by the `ReferenceGrant` there), over TLS (KServe's DestinationRule).
  Config: [`auth-policy.yaml`](../../stack/ai-gateways/connectivity-link/auth-policy.yaml),
  [`httproute.yaml`](../../stack/ai-gateways/connectivity-link/httproute.yaml); the key Secret is
  made by `key()` in `ai-gateways.sh`.
* **Say:** "The key is a Kubernetes Secret, the tier is an annotation on it. The `AuthPolicy`
  validates the key with Authorino and runs a CEL rule: free may only call Gemma. Moving alice to
  gold is `./deploy.sh ai-gateways key alice gold`, no redeploy."

**B3. Token quotas per consumer.**
* **Do:** `./deploy.sh ai-gateways burst` (second half), then `cl $KEY_BOB gemma-3-270m-it`.
* **What happens:** `TokenRateLimitPolicy llm-models-tokens` adds two steps around every request:
  1. **Before** forwarding, the wasm filter asks Limitador "may `llm-key-alice` (limit `free`,
     because `auth.identity.tier == "free"`) spend 0 more tokens?". Limitador keeps one counter per
     route, limit and `auth.identity.userid`, over a 1-minute window. Under 300 → go on; over → **429**.
  2. **After** the answer, the wasm filter reads `usage.total_tokens` from the response body and
     reports that number to Limitador, which adds it to alice's counter.
  That's why the request that crosses 300 still succeeds and the *next* one is refused, and why
  bob's counter (limit `gold`, 20 000) is unaffected. Config:
  [`token-rate-limit-policy.yaml`](../../stack/ai-gateways/connectivity-link/token-rate-limit-policy.yaml).
* **You see:** alice gets 200 three or four times (about 95 tokens each), then **429**; bob still gets 200.
* **Say:** "This isn't counting requests. The wasm filter in Envoy reads `usage.total_tokens` from
  every model response and charges it to alice's counter in Limitador. Her next request after the
  counter goes over 300 is refused, and bob has his own counter."

**B4. The policies are visible as objects.**
* **Do:**
  ```bash
  oc get authpolicy,tokenratelimitpolicy -n ai-gateways
  oc get httproute llm-models -n ai-gateways -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'
  ```
* **What happens:** the Kuadrant operator watches the policies and turns each into data-plane config:
  the `AuthPolicy` becomes an Authorino `AuthConfig` (in `kuadrant-system`), the
  `TokenRateLimitPolicy` becomes limits in the `Limitador` CR, and both become entries in the wasm
  config of the gateway's Envoy (EnvoyFilter `kuadrant-llm-gateway`). It reports back on the
  policies (`Accepted`, `Enforced`) and on the HTTPRoute they target (`…PolicyAffected`). That's all
  `oc get` shows: no separate API-management server holds this state.
* **You see:** both policies `Enforced`, and the HTTPRoute status listing
  `kuadrant.io/AuthPolicyAffected` and `kuadrant.io/TokenRateLimitPolicyAffected`.
* **Say:** "Platform engineering owns the Gateway, the API owner owns the route and its policies.
  Demo 10 adds the Dev Portal on top: self-service key requests and approvals."

---

## Part C: OpenShift AI MaaS, the product built on Connectivity Link (5 minutes)

**C1. The developer experience.**
* **Do:** OpenShift AI dashboard > **Models as a service** (or Gen AI studio > API keys): create a
  key; then
  ```bash
  curl -sk $M/v1/models -H "Authorization: Bearer $MAAS_KEY" | jq -r '.data[] | "\(.id)  \(.url)"'
  chat $M/maas-models/qwen3-0-6b qwen3-0-6b -H "Authorization: Bearer $MAAS_KEY" | jq -r '.choices[0].message.content'
  chat $M qwen3-0-6b -H "Authorization: Bearer $MAAS_KEY" -o /dev/null -w '%{http_code}\n'   # 404
  ```
* **What happens:** `$M` is the MaaS gateway (`maas-default-gateway` in `openshift-ingress`, the same
  GatewayClass as Part B). `/v1/models` is answered by `maas-api`: it looks up which models the
  key's subscription covers and returns them with their URLs. A chat call goes to
  `/maas-models/<model>/v1/chat/completions`: an HTTPRoute that OpenShift AI created for the
  `LLMInferenceService`, with an `AuthPolicy` and `TokenRateLimitPolicy` that the MaaS controller
  generated (C2). The AuthPolicy validates the `sk-oai-…` key against `maas-api` and selects the
  subscription; the token limit is charged per user and subscription, as in B3. `$M/v1/chat/completions`
  without the model path matches no route → **404**: MaaS on 3.4 routes on the path, not on the body.
* **You see:** the models this key may use, each with its own base URL
  (`https://maas.<domain>/maas-models/<model>`), an answer on that URL, and a 404 on the shared
  `/v1/chat/completions`.
* **Say:** "This is what a developer wants: a key from a UI and a list of models with their OpenAI
  base URLs. On this OpenShift AI version the base URL is per model, like the Connectivity Link
  route in Part B; one URL for every model is what Praxis adds in Part D."

**C2. Three objects in, Connectivity Link policies out.**
* **Do:** open [`governance/auth-policy.yaml`](../../governance/auth-policy.yaml) and
  [`governance/subscription-free.yaml`](../../governance/subscription-free.yaml), then
  ```bash
  oc get authpolicy,tokenratelimitpolicy -n maas-models
  oc get tokenratelimitpolicy maas-trlp-qwen3-0-6b -n maas-models -o yaml | sed -n '/^spec/,/^status/p'
  ```
* **What happens:** you declare three model-centric objects: `MaaSModelRef` (publish this
  `LLMInferenceService` to MaaS), `MaaSAuthPolicy` (which groups may use which models) and
  `MaaSSubscription` (token limits per model for a group, with a priority). The MaaS controller
  reconciles them into one `AuthPolicy` (`maas-auth-<model>`) and one `TokenRateLimitPolicy`
  (`maas-trlp-<model>`) per model, attached to the model's HTTPRoute. From there Kuadrant does
  exactly what it did in B4 with the policies you wrote by hand.
* **You see:** a generated `AuthPolicy` and `TokenRateLimitPolicy` per model. They are the same
  kinds as `llm-models-auth` and `llm-models-tokens` from Part B, with one limit per subscription
  (`small-models-free`: 5000 tokens/min, `small-models-premium`: 100 000, `developer-lightspeed`).
* **Say:** "MaaS doesn't replace Connectivity Link, it writes the Connectivity Link policies for
  you, from a model-centric API. In Part B we wrote them by hand: more control, more work."

**C3. Same models, three gateways, one table.**
* **Do:** `./deploy.sh ai-gateways compare` (and `compare gemma-3-270m-it`).
* **What happens:** `compare` (in `ai-gateways.sh`) sends one identical chat body to each gateway,
  with that gateway's URL shape and credential: `$P/v1/chat/completions` (no key), `$G/<model>/v1/…`
  (bob's `APIKEY`), `$M/maas-models/<model>/v1/…` (a fresh 1-hour MaaS key, minted through
  `/maas-api/v1/api-keys` with your `oc` token), and Praxis → MaaS through a port-forward (OpenAI
  and Anthropic API). Per row it prints the HTTP status, curl's total time and the `usage` block.
* **You see:** a row each for Praxis, Connectivity Link, MaaS and Praxis→MaaS (OpenAI and
  Anthropic API): same model, comparable token usage and latency (the model dominates; every gateway
  adds milliseconds). A row marked `(retried after a 500)` is the intermittent MaaS key-validation
  error from "If something goes wrong".

---

## Part D: better together, Praxis in front of MaaS (4 minutes)

* **Do:**
  ```bash
  for m in qwen3-0-6b gemma-3-270m-it; do
    curl -s $PM/v1/messages -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
      -d "{\"model\":\"$m\",\"max_tokens\":30,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}" | jq -c '{type,model,usage}'
  done
  curl -sN $PM/v1/messages -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"gemma-3-270m-it","max_tokens":10,"stream":true,"messages":[{"role":"user","content":"hello"}]}' | grep '^event' | uniq -c
  oc get secret praxis-maas-key -n ai-gateways      # Praxis's own MaaS key
  ```
* **What happens**, for `$PM/v1/messages` with `"model": "gemma-3-270m-it"` (listener `via-maas`,
  `:8082`, reached through `oc port-forward`; chain `maas` in
  [`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml)):
  1. `classify` + `translate`: as in A2, the Anthropic request becomes OpenAI Chat and
     `X-Model: gemma-3-270m-it` is set.
  2. `path_rewrite` (conditioned on `x-model`) builds the MaaS path:
     `/maas-models/gemma-3-270m-it/v1/chat/completions`. Several rewrites apply to one request, so
     the later ones carry `allow_rewrite_override: true`; the last matching one wins.
  3. `router` → cluster `maas`; `headers` sets `Host: maas.<apps-domain>` (the MaaS route matches
     on it); `credential_injection` puts `Authorization: Bearer <MAAS_API_KEY>` on the request
     (Secret `praxis-maas-key`), removing anything the client sent.
  4. `load_balancer` sends it to the MaaS gateway's in-cluster Service
     (`maas-default-gateway-openshift-default.openshift-ingress:80`). MaaS then does C1: validate
     the key, check the subscription's token limit, route to Gemma.
  5. The answer comes back through the A2 translation (also for streaming).
* **You see:** Anthropic Messages replies (also streamed) from both MaaS-governed models, on **one**
  URL with the model in the body. Praxis builds the per-model MaaS path
  (`/maas-models/<model>/v1/chat/completions`) from the body's `model`.
* **Say:** "Praxis translates the protocol and the URL; MaaS still authenticates, enforces the
  subscription and counts the tokens. One honest detail: the Anthropic translation strips the
  caller's credentials on purpose, so Praxis calls MaaS with **its own** MaaS key. MaaS sees one
  consumer, the gateway, with one quota. That is why this listener has no public Route: put it
  next to the agents that use it, or give Praxis its own front-door authentication. Claude Code
  with `ANTHROPIC_BASE_URL=$PM` now runs on a model your platform team governs."

---

## Part E: guardrails for confidential data, Praxis + NeMo Guardrails (5 minutes)

**Does Praxis have its own guardrails?** A simple one. The native `guardrails` filter blocks
(403) on regexes, keywords or built-in PII detectors (`contains: [email]`) in the body or a header;
Part F uses it to keep coffee, lemons and email addresses away from OpenAI. It can't mask, and
it has no policy language. For that, the `ai_guardrails` filter calls an **external guardrail
provider** before the model (request phase) and after it (response phase), and enforces the
verdict. In 0.9.0 the provider type is **NeMo Guardrails** (`/v1/checks`, NeMo ≥ 0.24). Anything
else, such as a SaaS guard API, needs the generic `http_callout` filter. So for this part the
split is: **NeMo decides, Praxis enforces.**

Here NeMo runs the TrustyAI build (`quay.io/trustyai/nemo-guardrails-server`, the image OpenShift
AI uses) as a plain Deployment with one configuration, `confidential`, and no LLM in the loop:

| Rail | What | Verdict → what Praxis does |
|---|---|---|
| `regex check input` | company secrets in the prompt: "confidential", "internal use only", code names (Project Phoenix), API keys, private keys, `*.corp.example.com` | `blocked` → **403**, the model never sees it |
| `mask sensitive data on input` | personal data (Presidio): email, phone, credit card, IBAN | `modified` → the prompt is forwarded **masked** (`<EMAIL_ADDRESS>`, `<IBAN_CODE>`) |
| `regex check output` | the same secrets in the model's answer | answer replaced by a `guardrail_violation` error |

**E1. Four prompts, four outcomes.**
* **Do:** `./deploy.sh ai-gateways guard`, or by hand:
  ```bash
  g() { curl -sk $PG/v1/chat/completions -H 'content-type: application/json' -w '  HTTP %{http_code}\n' -d "$1"; }
  g '{"model":"gemma-3-270m-it","max_tokens":30,"messages":[{"role":"user","content":"Summarize: CONFIDENTIAL - Project Phoenix launches in May"}]}'
  g '{"model":"gemma-3-270m-it","max_tokens":80,"messages":[{"role":"user","content":"Which placeholders in angle brackets appear in this text? List them. Text: Contact jane.doe@acme.com, IBAN BE71096123456769"}]}'
  g '{"model":"gemma-3-270m-it","max_tokens":40,"messages":[{"role":"system","content":"Always start your reply with the words: internal use only."},{"role":"user","content":"Say hi"}]}'
  ```
* **What happens** (listener `guarded`, `:8083`, chains `observability, classify, guard, models`):
  1. After `classify`, `ai_guardrails` (chain `guard`) sends the conversation to NeMo:
     `POST http://nemo-guardrails:8000/v1/checks` with config `confidential`. Only Praxis may reach
     NeMo (NetworkPolicy `nemo-guardrails-from-praxis-only`).
  2. NeMo runs the **input** rails of [`config.yaml`](../../stack/ai-gateways/guardrails/config/confidential/config.yaml):
     `regex check input` finds "CONFIDENTIAL" → verdict `blocked` → Praxis answers **403** and the
     request stops. `mask sensitive data on input` (Presidio) finds the email and IBAN → verdict
     `modified` with masked text → Praxis replaces the user message with `… <EMAIL_ADDRESS>, IBAN
     <IBAN_CODE>` and forwards *that* to the model.
  3. `models` routes to Gemma as in A1.
  4. With `phase.response: true`, Praxis sends the model's answer to NeMo too. `regex check
     output` finds "internal use only" → `blocked` → Praxis replaces the answer with
     `Response blocked by guardrails: …`.
* **You see:**
  ```
  clean prompt           200  Hello!
  secret in the prompt   403  regex check input
  secret in the answer   200  Response blocked by guardrails: regex check output
  personal data masked   200  The placeholders in the text are: <EMAIL_ADDRESS>, <IBAN_CODE>
  ```
  and the same personal-data prompt on the unguarded listener (`$P`): the model gets, and repeats,
  the real IBAN.
* **Say:** "The model only ever saw `<EMAIL_ADDRESS>` and `<IBAN_CODE>`; the real values stopped
  at the gateway. A prompt with a project code name never reached the model at all. And because it
  runs on the response too, a model that leaks a secret, say from a RAG document, gets its answer
  replaced."

**E2. Change the policy, no code.**
* **Do:** add a code name to `stack/ai-gateways/guardrails/config/confidential/config.yaml`
  (`patterns:`), then
  `oc apply -k stack/ai-gateways/guardrails && oc rollout restart deploy/nemo-guardrails -n ai-gateways`.
* **What happens:** `kustomization.yaml` in `stack/ai-gateways/guardrails` generates ConfigMap
  `nemo-config-confidential` from `config.yaml`; the Deployment mounts it at
  `/app/config/confidential`. NeMo reads its configs when it starts, hence the rollout restart.
  Praxis isn't touched: it only knows the endpoint and the config id `confidential`.
* **Say:** "The policy is a ConfigMap owned by security, the enforcement point is the gateway owned
  by the platform team, and the application teams change nothing."

**E3. Fail closed, and the limits.**
* **Do:** `oc scale deploy/nemo-guardrails -n ai-gateways --replicas=0`, send a prompt to `$PG`
  (**500**: no unscreened traffic), then scale back to 1.
* **What happens:** with no NeMo pod, the `/v1/checks` callout fails (connection refused or the
  15 s `timeout_ms`). `ai_guardrails` fails closed by default, so Praxis answers **500** instead of
  forwarding an unscreened prompt.
* **Say:** "`ai_guardrails` is a security filter: no conditions, fail closed by default. Today it
  screens OpenAI Chat without streaming (streaming plus response screening returns 422 until Praxis
  screens SSE), and masking rewrites Chat bodies only, which is why the guarded listener has no
  Anthropic translation."

**And the other two gateways?** Connectivity Link has no content guardrails: Authorino and
Limitador decide on headers, identity and token counts, not on the prompt. On OpenShift AI,
guardrails are TrustyAI services (NeMo Guardrails, the Guardrails Orchestrator) with their own
endpoint in front of the model; MaaS itself doesn't screen content. The same `confidential`
ConfigMap runs unchanged in a TrustyAI `NemoGuardrails` CR once the `trustyai` component is
`Managed` in the DataScienceCluster (it isn't on this cluster, hence the plain Deployment; see
[`app/coffee-guardrails/openshift/nemoguardrails.yaml`](../../app/coffee-guardrails/openshift/nemoguardrails.yaml)).

---

## Part F: Connectivity Link + Praxis, one LLM API (20 minutes)

**The story:** Parts A to E compare the gateways. Part F combines them into one LLM API product,
each gateway doing what it is good at. **Connectivity Link** is the front door: it knows **who** is
calling (API keys, tiers), throttles requests, counts **tokens** per consumer and versions the API.
It never reads the request body. **Praxis** sits behind it: it knows **which model** is asked and
**what is in the prompt**, so it does model routing, routing to OpenAI, and guardrails. The glue is
two headers the Connectivity Link `AuthPolicy` writes on every request (`x-consumer`,
`x-consumer-tier`).

```
                     Connectivity Link: Gateway llm-gateway                      Praxis AI (praxis-ai pod)
 client ──HTTPS──▶  HTTPRoute llm-api-v1  /v1/*  ──────────────────────────▶  api-v1 :8084  local models only ──┐
 APIKEY sk-llm-…    HTTPRoute llm-api-v2  /v2/*, /v1/* + x-api-version: 2 ─▶  api-v2 :8085                       │
                    AuthPolicy          API key → x-consumer, x-consumer-tier      data-classification, tier-gate │
                    RateLimitPolicy     5 req/s per consumer                       model_to_provider ─────────────┤
                    TokenRateLimitPolicy free 500 / gold 20 000 tokens/min           │                          ▼
                    TelemetryPolicy     metrics labels user, tier                    │       qwen3-0-6b, gemma-3-270m-it
                                                                                     ▼       (KServe, maas-models)
                                                          openai-egress 127.0.0.1:8086
                                                          guardrails (coffee, lemons, email) → 403
                                                          credential_injection (OPENAI_API_KEY) ──▶ api.openai.com
```

| Scenario | Where | YAML |
|---|---|---|
| F1 Model routing (incl. aliases) | Praxis | `praxis-ai.yaml`: chains `classify`, `model-routing`, `unknown-model-v2` |
| F2 Local model versus OpenAI (+ confidential stays local) | Praxis | `praxis-ai.yaml`: `model-routing`, `openai`, `data-classification`; `deployment.yaml`: `OPENAI_API_KEY` |
| F3 Block OpenAI calls about coffee, lemons, with email addresses | Praxis | `praxis-ai.yaml`: listener `openai-egress`, chain `openai-guardrails` |
| F4 Throttle: 5 requests per second, then change it | Connectivity Link (+ Praxis) | `api-policies.yaml`: `RateLimitPolicy llm-api-throttle`; `praxis-ai.yaml`: chain `throttle` |
| F5 Token limits | Connectivity Link | `api-policies.yaml`: `TokenRateLimitPolicy llm-api-tokens` |
| F6 API versioning | Connectivity Link | `api-routes.yaml`: `HTTPRoute llm-api-v1`, `llm-api-v2` |
| F7 Who may use OpenAI (identity-aware routing) | both | `api-policies.yaml`: `AuthPolicy llm-api-auth`; `praxis-ai.yaml`: chain `tier-gate` |
| F8 Metrics: who, which API / model, latency, tokens | both | `api-policies.yaml`: `TelemetryPolicy`; `praxis-ai.yaml`: `token_count`; `deployment.yaml`: `ServiceMonitor` |

### Before you start

* `./deploy.sh ai-gateways deploy` (it includes the console), or only the console:
  `./deploy.sh ai-gateways console`. Open the URL it prints
  (`https://ai-gateway-console-ai-gateways.<apps-domain>`).
* OpenAI (F2, F3, F7): `export OPENAI_API_KEY=sk-... && ./deploy.sh ai-gateways openai-key`. It
  stores the key in Secret `praxis-openai-key` and restarts Praxis. The console header shows
  **OpenAI key set / not set**. Without a key every call that reaches OpenAI is a 401 from OpenAI;
  everything else in Part F, including the guardrail blocks, works anyway.
* Terminal variant of every scenario: `./deploy.sh ai-gateways api`. For the curl lines below:
  ```bash
  source stack/ai-gateways/.keys.env
  G=https://$(oc get route llm-gateway -n ai-gateways -o jsonpath='{.spec.host}')
  ask() { curl -sk "$G$1" -H "Authorization: APIKEY $2" -H 'content-type: application/json' "${@:5}" \
            -d "{\"model\":\"$3\",\"max_tokens\":40,\"messages\":[{\"role\":\"user\",\"content\":\"$4\"}]}" \
            -w '  HTTP %{http_code}\n'; }
  ```
* In the console, **calling as** (top right) switches between alice (free) and bob (gold). Every
  page has the YAML that makes it work on the right, with the relevant lines highlighted, and a
  **live from the cluster** toggle that shows the object as it is running now. **Reset limits**
  puts the throttle and token limits back to the defaults.

**F1. Model routing.** Console: *Model routing*, **Send to all**.
* **Do:** `ask /v2/chat/completions $KEY_BOB smart "hi"`, then the same with `fast`, `gemma-3-270m-it`, `gpt-5`.
* **What happens**, for `ask /v2/chat/completions $KEY_BOB smart "hi"`:
  1. **Connectivity Link** (Envoy of `llm-gateway`): `/v2/` matches `HTTPRoute llm-api-v2`. The
     Gateway-level `AuthPolicy llm-api-auth` validates bob's key and adds `x-consumer: llm-key-bob`
     and `x-consumer-tier: gold` to the request; `RateLimitPolicy` and `TokenRateLimitPolicy` check
     bob's counters in Limitador. The route rewrites `/v2/` to `/v1/`, removes `Authorization` and
     forwards to Service `praxis-ai`, port 8085.
  2. **Praxis**, listener `api-v2`: `data-classification` does nothing (no header); `classify` sets
     `X-Model: smart`; `catalog-v2` only answers `/v1/models`; `unknown-model-v2` lets `smart`
     through (it's in the list); `tier-gate` only cares about OpenAI models.
  3. `model_to_provider` finds `smart` → upstream `qwen`, `target_model: qwen3-0-6b`: it rewrites
     `"model"` in the body to `qwen3-0-6b` and selects cluster `qwen`; `load_balancer` sends it to
     the Qwen workload (TLS, service CA). Unlike A1, the client name and the served name can differ.
  4. On the way back: `token_count` records the tokens under `model="smart"`; Connectivity Link
     charges `usage.total_tokens` to bob and adds `x-api-version: 2` to the response.
* **You see:** one URL, seven model names. `smart` is answered by `qwen3-0-6b`, `fast` by
  `gemma-3-270m-it`, `cloud` / `gpt-4o-mini` go to OpenAI, `gpt-5` is a 404 with a readable error.
* **Say:** "Clients ask for a capability, the platform decides which model that is today. Swap the
  model behind `smart` in one line, no client changes. Gateway API can't do this: it never sees the body."
* **Configured by** ([`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml)): `model_to_header`
  in the `classify` chain copies the body's `model` into `X-Model`; one `model_to_provider` table
  picks the upstream cluster **and rewrites `model` in the body** to the name that upstream serves:
  ```yaml
  - name: model-routing
    filters:
      - filter: model_to_provider
        models:
          - {model: qwen3-0-6b,      upstream: qwen,          target_model: qwen3-0-6b,      paths: ["/v1/chat/completions"]}
          - {model: gemma-3-270m-it, upstream: gemma,         target_model: gemma-3-270m-it, paths: ["/v1/chat/completions"]}
          - {model: gpt-4o-mini,     upstream: openai-egress, target_model: gpt-4o-mini,     paths: ["/v1/chat/completions"]}
          - {model: fast,            upstream: gemma,         target_model: gemma-3-270m-it, paths: ["/v1/chat/completions"]}   # alias
          - {model: smart,           upstream: qwen,          target_model: qwen3-0-6b,      paths: ["/v1/chat/completions"]}   # alias
          - {model: cloud,           upstream: openai-egress, target_model: gpt-4o-mini,     paths: ["/v1/chat/completions"]}   # alias
      - filter: token_count              # praxis_ai_*_tokens_total{model}, local and OpenAI
        provider: openai
      - filter: load_balancer            # clusters qwen, gemma (service-CA TLS), openai-egress (127.0.0.1:8086)
  - name: unknown-model-v2               # anything not in the table: 404 + JSON error
    filters:
      - filter: static_response
        status: 404
        conditions:
          - unless: {headers: {x-model: qwen3-0-6b}}
          # ... one unless per name in the table
  ```

**F2. Routing to a local model versus OpenAI.** Console: *Local model vs OpenAI*, as **bob**, **Ask both**; then tick **confidential** and ask again.
* **Do:**
  ```bash
  ask /v2/chat/completions $KEY_BOB smart       "Why run an LLM on your own platform?"
  ask /v2/chat/completions $KEY_BOB gpt-4o-mini "Why run an LLM on your own platform?"
  ask /v2/chat/completions $KEY_BOB gpt-4o-mini "Summarize our Q3 numbers" -H 'x-data-classification: confidential'
  ```
* **What happens:** `smart` goes to Qwen as in F1. For `gpt-4o-mini`, `model_to_provider` selects
  upstream `openai-egress`, which is Praxis itself on `127.0.0.1:8086` (a second listener in the
  same pod). There, `openai-guardrails` checks the body (F3); if it passes, the `openai` chain routes
  to cluster `openai`, sets `Host: api.openai.com`, removes `x-consumer`, `x-consumer-tier`, `x-model`,
  `x-data-classification`, and `credential_injection` sets `Authorization: Bearer $OPENAI_API_KEY`.
  `load_balancer` opens TLS to `api.openai.com:443`. With `x-data-classification: confidential`,
  the first `api-v2` chain (`data-classification`, a `json_body` filter) rewrites `"model"` to
  `qwen3-0-6b` *before* `classify` runs, so everything after it (X-Model, tier gate, routing) only
  ever sees the local model.
* **You see:** the same API and client code answered by the in-house Qwen and by OpenAI, with
  latency and tokens side by side. With `x-data-classification: confidential` the OpenAI request
  is answered by `qwen3-0-6b`: it never left the cluster.
* **Say:** "The OpenAI key lives in one Secret, read by one listener; no application team ever
  sees it. Praxis strips whatever credential the client sent and removes our internal headers
  before anything leaves the company."
* **Configured by** ([`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml),
  [`deployment.yaml`](../../stack/ai-gateways/praxis/deployment.yaml)):
  ```yaml
  - name: data-classification            # first chain of api-v2, before classify
    filters:
      - filter: json_body
        request_replace: [{pointer: /model, value: qwen3-0-6b}]
        conditions:
          - when: {headers: {x-data-classification: confidential}}
  - name: openai                         # on the 127.0.0.1:8086 egress listener
    filters:
      - filter: router
        routes: [{path_prefix: "/v1/", cluster: openai}]
      - filter: headers
        request_set: [{name: Host, value: api.openai.com}]
        request_remove: [x-consumer, x-consumer-tier, x-model, x-data-classification]
      - filter: credential_injection
        clusters:
          - {name: openai, header: Authorization, header_prefix: "Bearer ",
             env_var: OPENAI_API_KEY, strip_client_credential: true}
      - filter: load_balancer
        clusters:
          - {name: openai, endpoints: ["api.openai.com:443"], tls: {sni: api.openai.com}}
  ```
  ```yaml
  # deployment.yaml (praxis-ai container)
  - name: OPENAI_API_KEY
    valueFrom:
      secretKeyRef: {name: praxis-openai-key, key: OPENAI_API_KEY}   # ./deploy.sh ai-gateways openai-key
  ```

**F3. Block OpenAI calls about coffee, lemons, or with email addresses.** Console: *Block OpenAI*, as **bob**, **Run all**.
* **Do:**
  ```bash
  ask /v2/chat/completions $KEY_BOB gpt-4o-mini "How do I brew coffee for ten people?"   # 403
  ask /v2/chat/completions $KEY_BOB cloud       "I have three lemons, what can I bake?"  # 403
  ask /v2/chat/completions $KEY_BOB gpt-4o-mini "Reply to jane.doe@acme.com"            # 403
  ask /v2/chat/completions $KEY_BOB fast        "How do I brew coffee for ten people?"   # 200, local
  ```
* **What happens:** up to the egress hop it's F2. On listener `openai-egress`, the `guardrails`
  filter scans the request body: a match on `(?i)\bcoffee\b`, `(?i)\blemons?\b` or the built-in
  email detector → Praxis answers **403** (body `Forbidden`) right there, so the `openai` chain never
  runs and nothing leaves the cluster. The 403 travels back through `api-v2` and the gateway to the
  client; there's no `usage` block, so no tokens are charged. `fast` is routed to Gemma by
  `model_to_provider` and never touches the egress listener, which is why the same prompt is fine locally.
* **You see:** every prompt about coffee or lemons, and every prompt with an email address, is a
  **403** when it would go to OpenAI, in about half a second (OpenAI never saw it). The same prompt
  to a local model is answered. A clean prompt goes through (200, or 401 without an OpenAI key).
* **Say:** "The policy sits on the only road out to OpenAI, so it covers every client, every alias
  and every future model name that ends there, and nothing that stays inside."
* **Configured by** ([`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml)). Praxis's
  native `guardrails` filter, no external service. It is a *security filter*: Praxis refuses
  conditions on it ("only for OpenAI" would be a bypass), so OpenAI-bound traffic takes a loopback
  hop through its own listener, where the filter applies to everything:
  ```yaml
  listeners:
    - name: openai-egress
      address: "127.0.0.1:8086"            # unreachable from outside the pod
      filter_chains: [observability, openai-guardrails, openai]
  filter_chains:
    - name: openai-guardrails
      filters:
        - filter: guardrails
          rules:
            - {target: body, pattern: "(?i)\\bcoffee\\b"}
            - {target: body, pattern: "(?i)\\blemons?\\b"}
            - {target: body, contains: [email]}       # built-in PII detector
  insecure_options:
    allow_private_endpoints: true          # the 127.0.0.1 hop; every endpoint in the file is static
  ```

**F4. Throttle the API: 5 requests per second, then change it.** Console: *Throttle 5 req/s*.
* **Do:** **Fire 10** (Connectivity Link, as alice), switch to bob and fire again; set the limit
  to **2**, **Apply**, fire again. Then switch the limiter to **Praxis** and do the same. Terminal:
  ```bash
  for i in $(seq 10); do curl -sk -o /dev/null -w '%{http_code}\n' $G/v2/models -H "Authorization: APIKEY $KEY_ALICE" & done | sort | uniq -c
  oc patch ratelimitpolicy llm-api-throttle -n ai-gateways --type=merge \
    -p '{"spec":{"limits":{"per-consumer":{"rates":[{"limit":2,"window":"1s"}]}}}}'
  ```
* **What happens:** each `GET /v2/models` passes the AuthPolicy, then the wasm filter asks Limitador
  to add 1 to the counter for route `llm-api-v2`, limit `per-consumer`, user `llm-key-alice`, in
  the current 1-second window. Requests 1 to 5 get through to Praxis, where `catalog-v2` answers
  them itself; from the 6th in the same second, Envoy answers **429** and Praxis never sees the
  request. bob has his own counter. The `TokenRateLimitPolicy` skips `/models`
  (`!request.path.endsWith("/models")`). **Apply** in the console merge-patches the
  `RateLimitPolicy`; the Kuadrant operator rewrites the Limitador limits within seconds. Praxis
  variant: Route `praxis-ai-limited` → listener `limited` → `rate_limit` bucket as in A4; **Apply**
  edits `rate`/`burst` in ConfigMap `praxis-ai-config` and annotates the Praxis pod so the kubelet
  syncs the file right away, then Praxis hot-reloads (A5).
* **You see:** 10 parallel requests: 5 × 200, 5 × 429; bob has his own 5. After the change: 2 × 200,
  8 × 429, within a few seconds. The Praxis limiter gives the same numbers, but for **everybody
  together**: it doesn't know who is calling.
* **Say:** "A policy is an object; changing a limit is a patch, not a deployment. Connectivity Link
  limits per consumer; Praxis's bucket is per listener (or per IP)."
* **Configured by** ([`api-policies.yaml`](../../stack/ai-gateways/connectivity-link/api-policies.yaml),
  [`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml)):
  ```yaml
  kind: RateLimitPolicy
  metadata:
    name: llm-api-throttle
  spec:
    targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: llm-gateway}
    limits:
      per-consumer:
        rates: [{limit: 5, window: 1s}]        # <- the console's Apply patches this
        counters: [{expression: auth.identity.userid}]
  ```
  ```yaml
  - name: throttle                         # Praxis, listener limited (route praxis-ai-limited)
    filters:
      - filter: rate_limit
        mode: global
        rate: 5                            # <- the console edits the ConfigMap, Praxis hot-reloads
        burst: 5
  ```
  The bursts hit `GET /v2/models` (and `/v1/models` on `praxis-ai-limited`), which Praxis answers
  itself (`static_response`, chains `catalog-v1` / `catalog-v2`): no model is loaded by a burst.

**F5. Token limits.** Console: *Token limits*, as **alice**, **Send until limited**; then as bob.
* **Do:** `for i in $(seq 8); do ask /v2/chat/completions $KEY_ALICE fast "Tell me about OpenShift"; done`
* **What happens:** the B3 mechanism, on the API routes: before each request the wasm filter checks
  alice's counter (route `llm-api-v2`, limit `api-free` because her tier is `free`), and after each
  answer it reads `usage.total_tokens` and adds it. OpenAI answers carry `usage` too, so they're
  charged the same way. Changing a limit in the console is a JSON patch of
  `/spec/limits/api-free/rates/0/limit`; the counter itself keeps running until its window ends.
* **You see:** about 90 tokens per answer; after roughly 500 tokens in the minute, **429**. bob, on
  gold (20 000 tokens/min), carries on. Change `free` to 2000 in the console and alice continues.
* **Say:** "Requests are a poor proxy for cost. Connectivity Link reads `usage.total_tokens` from
  every answer, local or OpenAI, and charges it to the caller. The answer that crosses the line
  still arrives; the next request doesn't."
* **Configured by** ([`api-policies.yaml`](../../stack/ai-gateways/connectivity-link/api-policies.yaml)),
  with the tier coming from the key Secret's annotation via the `AuthPolicy` (F7):
  ```yaml
  kind: TokenRateLimitPolicy
  metadata:
    name: llm-api-tokens
  spec:
    targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: llm-gateway}
    limits:
      api-free:
        rates: [{limit: 500, window: 1m}]
        when:
          - predicate: auth.identity.tier == "free"
          - predicate: '!request.path.endsWith("/models")'   # the catalog has no usage block
        counters: [{expression: auth.identity.userid}]
      api-gold:
        rates: [{limit: 20000, window: 1m}]
        # same when / counters for gold
  ```

**F6. API versioning.** Console: *API versioning*, model `gemma-3-270m-it`, **Send**; then model `fast`.
* **Do:**
  ```bash
  curl -sk -D - -o /dev/null $G/v1/models -H "Authorization: APIKEY $KEY_ALICE" | grep -iE 'deprecation|sunset|link|x-api-version'
  ask /v1/chat/completions $KEY_ALICE fast "hi"                          # 404: no aliases in v1
  ask /v1/chat/completions $KEY_ALICE fast "hi" -H 'x-api-version: 2'    # 200, served by v2
  ask /v2/chat/completions $KEY_ALICE fast "hi"                          # 200
  ```
* **What happens:** both HTTPRoutes attach to the same Gateway and hostname, so Envoy merges their
  rules and picks the most specific match: `/v2/…` → `llm-api-v2`; `/v1/…` with
  `x-api-version: 2` → the `llm-api-v2` rule with a header match (same path, more header matches
  wins); any other `/v1/…` → `llm-api-v1`. Each rule's `backendRef` picks a different Praxis port,
  so a different listener: `api-v1` (`:8084`) has no aliases and no OpenAI, and
  `unknown-model-v1` answers **404** for `fast`. On the way back, `ResponseHeaderModifier` adds
  `x-api-version` (and for v1, `Deprecation` / `Sunset` / `Link`) to every response, including errors.
* **You see:** v1 and v2 side by side on the same host. v1 answers carry `Deprecation`, `Sunset`
  and `Link: </v2/chat/completions>; rel="successor-version"`. `fast` is a 404 on v1 and works on
  v2, also through the `x-api-version: 2` header on the v1 path.
* **Say:** "Existing clients keep working and are told, in every response, until when. New
  capabilities only ship in v2. All of it is plain Gateway API."
* **Configured by** ([`api-routes.yaml`](../../stack/ai-gateways/connectivity-link/api-routes.yaml)):
  ```yaml
  kind: HTTPRoute
  metadata: {name: llm-api-v1}
  spec:
    rules:
      - matches: [{path: {type: PathPrefix, value: /v1/}}]
        filters:
          - type: RequestHeaderModifier
            requestHeaderModifier: {remove: [Authorization]}       # the key stops at the gateway
          - type: ResponseHeaderModifier
            responseHeaderModifier:
              set:
                - {name: Deprecation, value: "@1793491200"}             # RFC 9745
                - {name: Sunset, value: "Wed, 30 Jun 2027 23:59:59 GMT"} # RFC 8594
                - {name: Link, value: '</v2/chat/completions>; rel="successor-version"'}
        backendRefs: [{name: praxis-ai, port: 8084}]               # Praxis api-v1
  ---
  kind: HTTPRoute
  metadata: {name: llm-api-v2}
  spec:
    rules:
      - matches: [{path: {type: PathPrefix, value: /v2/}}]
        filters:
          - type: URLRewrite
            urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /v1/}}
        backendRefs: [{name: praxis-ai, port: 8085}]               # Praxis api-v2
      - matches:                         # more header matches than the v1 rule: this one wins
          - path: {type: PathPrefix, value: /v1/}
            headers: [{name: x-api-version, value: "2"}]
        backendRefs: [{name: praxis-ai, port: 8085}]
  ```
  On the Praxis side each version is a listener with its own chains: `api-v1` has no aliases and
  no OpenAI (`unknown-model-v1` answers 404 for anything but the two local models).

**F7. Who may use OpenAI.** Console: *Who may use OpenAI*, **Run**.
* **Do:**
  ```bash
  ask /v2/chat/completions $KEY_ALICE cloud "hi"                              # 403 tier_not_allowed
  ask /v2/chat/completions $KEY_BOB   cloud "hi"                              # OpenAI
  ask /v2/chat/completions $KEY_ALICE cloud "hi" -H 'x-consumer-tier: gold'   # still 403
  ```
* **What happens:** Authorino returns the headers from `response.success.headers` to Envoy along
  with "allowed", and Envoy *sets* them on the request to Praxis, replacing any header of the same
  name the client sent: alice's own `x-consumer-tier: gold` becomes `free`. In Praxis, `cloud` is
  in the model list (passes `unknown-model-v2`), then `tier-gate`'s `static_response` has two
  conditions, `when x-model: cloud` and `unless x-consumer-tier: gold`; both hold for alice →
  **403** `tier_not_allowed`. For bob the `unless` fails, so the request goes on to F2's OpenAI path.
* **You see:** free alice can't use OpenAI, gold bob can, and alice sending `x-consumer-tier: gold`
  herself changes nothing.
* **Say:** "This decision needs who is calling, which only Connectivity Link knows, and what is
  asked, which only Praxis knows. The AuthPolicy writes the identity into headers, overwriting
  anything the client sent; Praxis decides on them. Moving alice to gold is
  `./deploy.sh ai-gateways key alice gold`."
* **Configured by** ([`api-policies.yaml`](../../stack/ai-gateways/connectivity-link/api-policies.yaml),
  [`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml)):
  ```yaml
  kind: AuthPolicy
  metadata: {name: llm-api-auth}
  spec:
    targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: llm-gateway}
    rules:
      authentication:
        api-key-consumers:
          apiKey: {allNamespaces: true, selector: {matchLabels: {llm-gateway/consumer: "true"}}}
          credentials: {authorizationHeader: {prefix: APIKEY}}
      response:
        success:
          headers:                                   # set on the request towards Praxis
            x-consumer:      {plain: {expression: auth.identity.metadata.name}}
            x-consumer-tier: {plain: {expression: 'auth.identity.metadata.annotations["llm-gateway/tier"]'}}
          filters:
            identity: {json: {properties: {userid: ..., tier: ...}}}   # for the limits and metrics
  ```
  ```yaml
  - name: tier-gate                          # Praxis, api-v2
    filters:
      - filter: static_response
        status: 403
        body: '{"error":{"type":"tier_not_allowed", ...}}'
        conditions:
          - when:   {headers: {x-model: gpt-4o-mini}}
          - unless: {headers: {x-consumer-tier: gold}}
      # same for x-model: cloud
  ```
  Praxis's api listeners have no Route: only the gateway (and pods inside the cluster) reach them,
  so the headers can be trusted.

**F8. Metrics: who calls which API and model, how fast, how many tokens.** Console: *Metrics*,
**Mixed traffic**, wait for a scrape (15 to 30 s).
* **What happens:** the `TelemetryPolicy` makes Kuadrant add two values to every Limitador call from
  the wasm filter: `user` and `tier`. Limitador runs with `--metric-labels-default descriptors[1]`,
  so they become labels on `authorized_calls`, `limited_calls` and `authorized_hits`, next to
  `limitador_namespace="ai-gateways/<route>"`. Prometheus scrapes Limitador (PodMonitor
  `kuadrant-limitador-monitor`), Praxis (`ServiceMonitor praxis-ai`) and the gateway Envoy
  (`istio-pod-monitor`). The console backend runs the PromQL against the Thanos querier with its
  ServiceAccount (`cluster-monitoring-view`); the ledger is the backend's own in-memory list of the
  calls it made (it starts empty after a console restart).
* **You see:** per consumer and API version (Limitador): allowed calls, 429s and hits charged; per
  model (Praxis): prompt and output tokens; per upstream cluster (Praxis): average latency and
  status classes; and the ledger, which joins them per request: consumer, API, model asked → served,
  status, latency, tokens. The PromQL is under the tables, for **Observe > Metrics**, e.g.
  ```promql
  sum by (user, tier, limitador_namespace) (authorized_hits{limitador_namespace=~"ai-gateways/.*"})
  sum by (model) (praxis_ai_output_tokens_total{namespace="ai-gateways"})
  sum by (cluster) (praxis_http_request_duration_seconds_sum{namespace="ai-gateways"})
    / sum by (cluster) (praxis_http_request_duration_seconds_count{namespace="ai-gateways"})
  ```
* **Say:** "Connectivity Link reports per consumer and per route, which is per API version. Praxis
  reports per model and per upstream. Same Prometheus, same dashboards as everything else on the platform."
* **Configured by** ([`api-policies.yaml`](../../stack/ai-gateways/connectivity-link/api-policies.yaml),
  [`deployment.yaml`](../../stack/ai-gateways/praxis/deployment.yaml)):
  ```yaml
  kind: TelemetryPolicy                      # extensions.kuadrant.io/v1alpha1
  metadata: {name: llm-gateway-telemetry}
  spec:
    targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: llm-gateway}
    metrics:
      default:
        labels:                              # -> authorized_calls / limited_calls / authorized_hits{user, tier}
          user: auth.identity.userid
          tier: auth.identity.tier
  ```
  plus `token_count` / `time_to_first_token` in Praxis's `model-routing` chain and the
  `ServiceMonitor praxis-ai` (`:9902/metrics`, every 15 s). Two honest limits: the token metric in
  Praxis is labelled with the model **as the client named it** (aliases are their own rows), and
  Limitador can't label by model, because the wasm shim can't read the request body (see "If
  something goes wrong").

**Why the policies sit on the Gateway.** `llm-api-auth`, `llm-api-throttle`, `llm-api-tokens` and
`llm-gateway-telemetry` target the Gateway, so they are the defaults for every route on it. A route
with its own policy of the same kind replaces the default for that route: `llm-models` (Part B)
keeps its own `AuthPolicy` and `TokenRateLimitPolicy`, and inherits only the throttle and the
telemetry. Platform defaults with per-API overrides, no copy-paste.

---

**When to use which**

| You need | Use |
|---|---|
| Developers self-serving keys to models served on OpenShift AI, quotas per team, usage reporting | **MaaS** |
| The same policies for non-model APIs too, or models that MaaS doesn't serve, or full control over each policy | **Connectivity Link** directly |
| Body-aware routing, protocol translation (Anthropic, Responses, Bedrock, Vertex), MCP/A2A routing, guardrail callouts, external providers with credential injection | **Praxis AI** (alpha), alongside or in front of the other two |
| Keep confidential and personal data away from models | **NeMo Guardrails** for the policy, enforced by **Praxis** (`ai_guardrails`) or called by the app / TrustyAI orchestrator |
| The prompt decides which model answers (context-based routing) | none of the three out of the box: the Camel model router ([demo 1](01-models-and-rag.md)) |
| One LLM API for internal teams: keys, quotas, versions, metrics per consumer, **and** aliases, OpenAI egress with guardrails, data that must stay local | **Connectivity Link in front of Praxis** (Part F) |

---

## Configuration reference

Everything below is in the repository; the snippets are trimmed to the parts that matter. Part F's
snippets are with each scenario above; its files are
[`connectivity-link/api-routes.yaml`](../../stack/ai-gateways/connectivity-link/api-routes.yaml),
[`connectivity-link/api-policies.yaml`](../../stack/ai-gateways/connectivity-link/api-policies.yaml),
the `api-v1` / `api-v2` / `openai-egress` listeners and their chains at the end of
[`praxis/praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml), and the console in
[`console/`](../../stack/ai-gateways/console/) (React + Vite + Tailwind UI, a small Node backend
that calls the gateway as alice / bob and patches the policies, and
[`openshift/console.yaml`](../../stack/ai-gateways/console/openshift/console.yaml): BuildConfig,
Deployment, Route and a Role limited to the objects it reads or changes).

### Praxis AI — [`stack/ai-gateways/praxis/`](../../stack/ai-gateways/praxis/)

[`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml), the whole gateway in one file
(mounted from ConfigMap `praxis-ai-config`):

```yaml
admin:
  metrics_address: "0.0.0.0:9902"      # /metrics, /healthy, /ready (kubelet + Prometheus)

clusters:                              # top level: health checks
  - name: qwen
    endpoints: ["qwen3-0-6b-kserve-workload-svc.maas-models.svc.cluster.local:8000"]
    trusted_private_endpoints: [qwen3-0-6b-kserve-workload-svc.maas-models.svc.cluster.local]
    tls:
      sni: qwen3-0-6b-kserve-workload-svc.maas-models.svc.cluster.local
      ca:
        ca_path: /etc/service-ca/service-ca.crt   # OpenShift service CA, verified (no verify: false)
    health_check:
      type: tcp                        # http probes are plaintext in core 0.7.5
      interval_ms: 5000
  # - name: gemma ... (same shape)

listeners:
  - name: direct                       # route praxis-ai
    address: "0.0.0.0:8080"
    filter_chains: [observability, classify, translate, models]
  - name: limited                      # route praxis-ai-limited
    address: "0.0.0.0:8081"
    filter_chains: [observability, throttle, classify, translate, models]
  - name: via-maas                     # no Route: oc port-forward svc/praxis-ai 18082:8082
    address: "0.0.0.0:8082"
    filter_chains: [observability, classify, translate, maas]

filter_chains:
  - name: observability
    filters:
      - filter: request_id
      - filter: access_log

  - name: throttle
    filters:
      - filter: rate_limit             # security filter: no conditions allowed, hence its own listener
        mode: global
        rate: 2
        burst: 4

  - name: classify                     # which API, which model?
    filters:
      - filter: ai_operation
      - filter: anthropic_messages_request
        on_invalid: continue
        conditions: [{when: {path: "/v1/messages"}}]
      - filter: openai_chat_completions_request
        conditions: [{when: {path: "/v1/chat/completions"}}]
      - filter: model_to_header        # body "model" -> X-Model (client value replaced)
        header: X-Model

  - name: translate                    # Anthropic Messages -> OpenAI Chat, streaming too
    filters:
      - filter: anthropic_messages_to_chat_completions
        conditions: [{when: {path: "/v1/messages"}}]
      - filter: anthropic_messages_to_chat_completions_stream
        conditions: [{when: {path: "/v1/messages"}}]
        response_conditions: [{when: {headers: {content-type: "text/event-stream"}}}]
      - filter: path_rewrite
        replace: {pattern: "^/v1/messages$", replacement: "/v1/chat/completions"}
        conditions: [{when: {path: "/v1/messages"}}]

  - name: models
    filters:
      - filter: router
        routes:
          - {path_prefix: "/v1/", headers: {x-model: qwen3-0-6b},      cluster: qwen}
          - {path_prefix: "/v1/", headers: {x-model: gemma-3-270m-it}, cluster: gemma}
      - filter: stream_usage_inject    # include_usage on every streaming request
      - filter: token_count            # praxis_ai_prompt/output_tokens_total{model,cluster}
        provider: openai
      - filter: time_to_first_token    # praxis_ai_ttft_seconds{model,cluster}
      - filter: load_balancer          # core 0.7.5: repeat endpoints + TLS here
        clusters:
          - name: qwen
            endpoints: ["qwen3-0-6b-kserve-workload-svc.maas-models.svc.cluster.local:8000"]
            trusted_private_endpoints: [qwen3-0-6b-kserve-workload-svc.maas-models.svc.cluster.local]
            tls:
              sni: qwen3-0-6b-kserve-workload-svc.maas-models.svc.cluster.local
              ca: {ca_path: /etc/service-ca/service-ca.crt}
          # - name: gemma ...

  - name: maas                         # Part D: everything to the MaaS gateway
    filters:
      # MaaS (3.4) routes on the path: build /maas-models/<model>/v1/... from X-Model.
      # Every path_rewrite matches the ORIGINAL path; the last one that applies wins.
      - filter: path_rewrite
        replace: {pattern: "^/v1/", replacement: "/maas-models/qwen3-0-6b/v1/"}
        allow_rewrite_override: true   # the translate chain also rewrites the path
        conditions: [{when: {headers: {x-model: qwen3-0-6b}}}]
      - filter: path_rewrite           # /v1/messages -> straight to the MaaS chat path
        replace: {pattern: "^/v1/messages$", replacement: "/maas-models/qwen3-0-6b/v1/chat/completions"}
        allow_rewrite_override: true
        conditions: [{when: {path: "/v1/messages", headers: {x-model: qwen3-0-6b}}}]
      # ... the same two for gemma-3-270m-it
      - filter: router
        routes: [{path_prefix: "/", cluster: maas}]
      - filter: headers
        request_set:
          - {name: Host, value: maas.apps.<cluster-domain>}   # set by ai-gateways.sh deploy
      # Praxis is the MaaS consumer: its own key, for every request on this listener.
      # Security filter: Praxis refuses a condition on it (no "only for /v1/messages").
      - filter: credential_injection
        clusters:
          - name: maas
            header: Authorization
            header_prefix: "Bearer "
            env_var: MAAS_API_KEY        # Secret praxis-maas-key, created by ai-gateways.sh deploy
            strip_client_credential: true
      - filter: load_balancer
        clusters:
          - name: maas
            endpoints: ["maas-default-gateway-openshift-default.openshift-ingress.svc.cluster.local:80"]
            trusted_private_endpoints: [maas-default-gateway-openshift-default.openshift-ingress.svc.cluster.local]
```

[`deployment.yaml`](../../stack/ai-gateways/praxis/deployment.yaml), the parts that matter on
OpenShift:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ai-gateways-service-ca
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"   # -> key service-ca.crt
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: praxis-ai
spec:
  template:
    spec:
      containers:
        - name: praxis-ai
          image: ghcr.io/praxis-proxy/ai:0.9.0
          command: ["praxis-ai", "-c", "/etc/praxis/praxis-ai.yaml"]
          env:
            - name: MAAS_API_KEY                      # Praxis's own MaaS key (via-maas listener)
              valueFrom:
                secretKeyRef: {name: praxis-maas-key, key: MAAS_API_KEY}
          readinessProbe:
            httpGet: {path: /healthy, port: metrics}  # not /ready: one model down != gateway down
          securityContext:                            # runs as is under restricted-v2
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: ["ALL"]}
          volumeMounts:
            - {name: config, mountPath: /etc/praxis}          # directory mount: hot reload works
            - {name: service-ca, mountPath: /etc/service-ca}
```

### Guardrails — [`stack/ai-gateways/guardrails/`](../../stack/ai-gateways/guardrails/) and the Praxis `guard` chain

[`config/confidential/config.yaml`](../../stack/ai-gateways/guardrails/config/confidential/config.yaml),
the NeMo policy (ConfigMap `nemo-config-confidential`, mounted at `/app/config/confidential`):

```yaml
models: []                                  # deterministic rails only, no LLM

rails:
  config:
    regex_detection:
      input:
        case_insensitive: true
        patterns: &secrets
          - "\\b(strictly )?confidential\\b"
          - "\\binternal use only\\b"
          - "\\bproject (phoenix|nightingale)\\b"         # code names
          - "\\bsk-(oai|llm|ant|proj)-[a-z0-9_-]{8,}"      # API keys
          - "-----begin [a-z ]*private key-----"
          - "\\b[a-z0-9.-]+\\.corp\\.example\\.com\\b"    # internal host names
      output:
        case_insensitive: true
        patterns: *secrets
    sensitive_data_detection:               # Presidio
      input:
        entities: [EMAIL_ADDRESS, PHONE_NUMBER, CREDIT_CARD, IBAN_CODE]

  input:
    flows:
      - regex check input                   # -> blocked
      - mask sensitive data on input        # -> modified (masked)
  output:
    flows:
      - regex check output                  # -> blocked
```

[`deployment.yaml`](../../stack/ai-gateways/guardrails/deployment.yaml), trimmed:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nemo-guardrails
  namespace: ai-gateways
spec:
  template:
    spec:
      containers:
        - name: nemo-guardrails
          image: quay.io/trustyai/nemo-guardrails-server:latest   # NeMo 0.24, Presidio, spaCy
          env:
            - {name: CONFIG_ID, value: confidential}              # default config
          volumeMounts:
            - {name: confidential, mountPath: /app/config/confidential}
      volumes:
        - name: confidential
          configMap: {name: nemo-config-confidential}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy                                               # only Praxis may call NeMo
metadata:
  name: nemo-guardrails-from-praxis-only
spec:
  podSelector: {matchLabels: {app: nemo-guardrails}}
  policyTypes: [Ingress]
  ingress:
    - from: [{podSelector: {matchLabels: {app: praxis-ai}}}]
      ports: [{protocol: TCP, port: 8000}]
```

In [`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml): the guarded listener and
the `guard` chain:

```yaml
insecure_options:
  allow_private_upstreams: true          # NeMo is a cluster-internal callout target

listeners:
  - name: guarded                        # route praxis-ai-guarded
    address: "0.0.0.0:8083"
    filter_chains: [observability, classify, guard, models]   # no translate: masking is Chat-only

filter_chains:
  - name: guard
    filters:
      - filter: ai_guardrails            # security filter: no conditions, fails closed
        outbound_chain: nemo-outbound
        provider:
          type: nemo
          endpoint: "http://nemo-guardrails.ai-gateways.svc.cluster.local:8000/v1/checks"
          guardrails:
            config_ids: ["confidential"]
          timeout_ms: 15000
          max_message_checks: 32
        phase:
          request: true                  # before the model: block or mask
          response: true                 # after the model: block leaked secrets
  - name: nemo-outbound                  # filters for the callout itself (audit, credentials)
    filters:
      - filter: request_id
```

### Connectivity Link — [`stack/ai-gateways/connectivity-link/`](../../stack/ai-gateways/connectivity-link/)

[`gateway.yaml`](../../stack/ai-gateways/connectivity-link/gateway.yaml) (platform engineer):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: llm-gateway
  namespace: ai-gateways
  annotations:
    networking.istio.io/service-type: ClusterIP     # exposed with an edge Route
spec:
  gatewayClassName: openshift-default               # same class as the MaaS gateway
  listeners:
    - name: http
      hostname: llm-gateway.apps.<cluster-domain>
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces: {from: Same}
```

[`httproute.yaml`](../../stack/ai-gateways/connectivity-link/httproute.yaml) (model owner),
including the `ReferenceGrant`s that `maas-models` needs for a cross-namespace backend:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-models
  namespace: ai-gateways
spec:
  parentRefs: [{name: llm-gateway}]
  hostnames: [llm-gateway.apps.<cluster-domain>]
  rules:
    - matches:
        - path: {type: PathPrefix, value: /qwen3-0-6b/v1/}
      filters:
        - type: URLRewrite
          urlRewrite:
            path: {type: ReplacePrefixMatch, replacePrefixMatch: /v1/}
      backendRefs:
        - {name: qwen3-0-6b-kserve-workload-svc, namespace: maas-models, port: 8000}
      timeouts: {request: 0s, backendRequest: 0s}
    # - /gemma-3-270m-it/v1/ -> gemma-3-270m-it-kserve-workload-svc (same shape)
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant                                # one per Service, see "If something goes wrong"
metadata:
  name: allow-ai-gateways-qwen
  namespace: maas-models
spec:
  from: [{group: gateway.networking.k8s.io, kind: HTTPRoute, namespace: ai-gateways}]
  to:   [{group: "", kind: Service, name: qwen3-0-6b-kserve-workload-svc}]
```

[`auth-policy.yaml`](../../stack/ai-gateways/connectivity-link/auth-policy.yaml) (API owner):

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: llm-models-auth
  namespace: ai-gateways
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: llm-models}
  rules:
    authentication:
      api-key-consumers:
        apiKey:
          allNamespaces: true                       # key Secrets live in ai-gateways
          selector:
            matchLabels: {llm-gateway/consumer: "true"}
        credentials:
          authorizationHeader: {prefix: APIKEY}
    authorization:
      tier-may-use-model:                           # free -> Gemma only, gold -> everything
        patternMatching:
          patterns:
            - predicate: >-
                request.path.startsWith("/gemma-3-270m-it/") ||
                auth.identity.metadata.annotations["llm-gateway/tier"] == "gold"
    response:
      success:
        filters:
          identity:                                 # -> auth.identity.userid / .tier for the limits
            json:
              properties:
                userid: {expression: auth.identity.metadata.name}
                tier:   {expression: 'auth.identity.metadata.annotations["llm-gateway/tier"]'}
```

[`token-rate-limit-policy.yaml`](../../stack/ai-gateways/connectivity-link/token-rate-limit-policy.yaml)
(API owner):

```yaml
apiVersion: kuadrant.io/v1alpha1
kind: TokenRateLimitPolicy
metadata:
  name: llm-models-tokens
  namespace: ai-gateways
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: llm-models}
  limits:
    free:
      rates: [{limit: 300, window: 1m}]             # tokens, not requests
      when: [{predicate: 'auth.identity.tier == "free"'}]
      counters: [{expression: auth.identity.userid}]
    gold:
      rates: [{limit: 20000, window: 1m}]
      when: [{predicate: 'auth.identity.tier == "gold"'}]
      counters: [{expression: auth.identity.userid}]
```

A consumer key (created by `./deploy.sh ai-gateways key <user> <free|gold>`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: llm-key-alice
  namespace: ai-gateways
  labels:
    llm-gateway/consumer: "true"                    # selected by the AuthPolicy
    authorino.kuadrant.io/managed-by: authorino     # watched by Authorino
  annotations:
    llm-gateway/tier: free                          # read by authorization + token limits
stringData:
  api_key: sk-llm-alice-...
```

Plus [`envoyfilter-authorino-tls.yaml`](../../stack/ai-gateways/connectivity-link/envoyfilter-authorino-tls.yaml),
the same Authorino-over-TLS fix as demo 10's partner gateway, scoped to `llm-gateway`.

### OpenShift AI MaaS — [`governance/`](../../governance/) and [`models/`](../../models/)

The model ([`models/qwen3-0-6b/llminferenceservice.yaml`](../../models/qwen3-0-6b/llminferenceservice.yaml)),
attached to the MaaS gateway and published to MaaS
([`maasmodelref.yaml`](../../models/qwen3-0-6b/maasmodelref.yaml)):

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen3-0-6b
  namespace: maas-models
  annotations:
    security.opendatahub.io/enable-auth: "true"
spec:
  model: {name: qwen3-0-6b, uri: "hf://Qwen/Qwen3-0.6B"}
  router:
    route: {}
    gateway:
      refs: [{name: maas-default-gateway, namespace: openshift-ingress}]
  # template: vLLM CPU, --enable-force-include-usage (token accounting in streams), ...
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: qwen3-0-6b
  namespace: maas-models
spec:
  modelRef: {kind: LLMInferenceService, name: qwen3-0-6b}
```

Who may call it ([`governance/auth-policy.yaml`](../../governance/auth-policy.yaml)) and with
which token quota ([`governance/subscription-free.yaml`](../../governance/subscription-free.yaml)):

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: small-models-access
  namespace: models-as-a-service
spec:
  modelRefs:
    - {name: gemma-3-270m-it, namespace: maas-models}
    - {name: qwen3-0-6b, namespace: maas-models}
  subjects:
    groups: [{name: "system:authenticated"}]
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: small-models-free
  namespace: models-as-a-service
spec:
  owner:
    groups: [{name: "system:authenticated"}]
  modelRefs:
    - name: qwen3-0-6b
      namespace: maas-models
      tokenRateLimits: [{limit: 5000, window: 1m}]
    # - gemma-3-270m-it ... (same)
  priority: 10                                       # premium (maas-premium-users) is 20
```

What the MaaS controller **generates** from those, on the model's HTTPRoute (trimmed from
`oc get tokenratelimitpolicy maas-trlp-qwen3-0-6b -n maas-models -o yaml`). Compare it with
`llm-models-tokens` above:

```yaml
apiVersion: kuadrant.io/v1alpha1
kind: TokenRateLimitPolicy
metadata:
  name: maas-trlp-qwen3-0-6b
  namespace: maas-models
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: HTTPRoute, name: qwen3-0-6b-kserve-route}
  limits:
    models-as-a-service-small-models-free-qwen3-0-6b-tokens:
      rates: [{limit: 5000, window: 1m}]
      counters: [{expression: auth.identity.userid}]
      when:
        - predicate: >-
            auth.identity.selected_subscription_key == "models-as-a-service/small-models-free@maas-models/qwen3-0-6b"
            && !request.path.endsWith("/v1/models")
    models-as-a-service-small-models-premium-qwen3-0-6b-tokens:
      rates: [{limit: 100000, window: 1m}]
      # ...
```

And the generated `AuthPolicy` (`maas-auth-qwen3-0-6b`): MaaS API keys (`Bearer sk-oai-…`)
validated against `maas-api`, OpenShift tokens for `/v1/models`, and OPA rules for group
membership and subscription selection. That's about 150 lines of policy you don't write yourself.

---

## Part in IntelliJ

Open these files (**Shift twice**, type the name):

| File | Point at |
|---|---|
| `praxis-ai.yaml` | `model_to_header`, the `translate` chain, `token_count`, the `maas` chain with the Host header |
| `deployment.yaml` (ai-gateways/praxis) | `inject-cabundle`, `/healthy` as readiness, the directory mount for hot reload |
| `auth-policy.yaml` (ai-gateways/connectivity-link) | the CEL authorization rule and the `response.success.filters.identity` that feeds the limits |
| `token-rate-limit-policy.yaml` | tokens, `when` per tier, `counters` per consumer |
| `governance/subscription-free.yaml` | the same limit, expressed per model and per group |
| `config.yaml` (ai-gateways/guardrails/config/confidential) | the NeMo policy: regex block list for secrets, Presidio entities to mask |
| `api-routes.yaml` (ai-gateways/connectivity-link) | Part F: path and header versioning, `Deprecation` / `Sunset` / `Link`, `remove: [Authorization]` |
| `api-policies.yaml` | Part F: Gateway-level AuthPolicy injecting `x-consumer-tier`, RateLimitPolicy 5/s, TokenRateLimitPolicy, TelemetryPolicy |
| `praxis-ai.yaml`, end of file | Part F: `model_to_provider` table, `tier-gate`, `data-classification`, the `openai-egress` listener with `guardrails` and `credential_injection` |
| `console/server/index.mjs` | what each console button does (`chat`, `burst`, `setThrottle`, `setTokens`, the PromQL) |
| `ai-gateways.sh` | `key` (a consumer is just a labelled Secret), `compare`, `burst`, `guard`, `api`, `openai-key`, `console` |

---

## Prove it from the terminal

```bash
./deploy.sh ai-gateways deploy
./deploy.sh ai-gateways test        # Praxis 200/200/404/200 + guarded 200/403, Connectivity Link 401/200/403/200, MaaS 401
./deploy.sh ai-gateways compare     # Praxis, Connectivity Link, MaaS, Praxis->MaaS (OpenAI + Anthropic): all 200
./deploy.sh ai-gateways guard       # NeMo via Praxis: 200 / 403 / answer blocked / <EMAIL_ADDRESS> masked
./deploy.sh ai-gateways burst       # Praxis: 4 pass, 16 x 429; Connectivity Link: alice 429 after ~300 tokens
./deploy.sh ai-gateways metrics     # Praxis token/TTFT metrics, Limitador counters for ai-gateways/llm-models
./deploy.sh ai-gateways api         # Part F: versioning, aliases, local vs OpenAI, guardrails 403, tier gate, throttle 5x200/5x429
./deploy.sh ai-gateways status
./deploy.sh ai-gateways openai-key  # store $OPENAI_API_KEY for Praxis (OpenAI egress), restart Praxis
./deploy.sh ai-gateways console     # rebuild + redeploy the AI Gateway Console after a change in stack/ai-gateways/console
```

The console can also run on your laptop against the cluster, e.g. while changing it:
```bash
cd stack/ai-gateways/console && npm ci
K8S_API=$(oc whoami --show-server) K8S_TOKEN=$(oc whoami -t) \
PROMETHEUS_URL=https://$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}') \
  npm run server &          # API on :8080
npm run dev                 # UI on http://localhost:5173 (proxies /api)
```

## Reset

```bash
oc apply -k stack/ai-gateways/praxis          # undo live ConfigMap edits (hot-reloads)
oc apply -k stack/ai-gateways/connectivity-link   # undo patched limits (or: console, "Reset limits")
./deploy.sh ai-gateways key alice free        # put alice back on free (same key)
./deploy.sh ai-gateways destroy               # namespace ai-gateways + the two ReferenceGrants;
                                              # MaaS, Connectivity Link and the models stay
```

Token counters reset on their own after the one-minute window.

## If something goes wrong

Part F (Connectivity Link + Praxis, console):

* **Every OpenAI call is 401 `Incorrect API key provided: not-set`:** no OpenAI key yet.
  `export OPENAI_API_KEY=sk-... && ./deploy.sh ai-gateways openai-key`. The key is read at start,
  hence the restart. A 403 with body `Forbidden` is the guardrails, before OpenAI.
* **`tokenratelimitpolicy/llm-api-tokens` shows `Enforced=False`, "policy rule(s) overridden":**
  cosmetic (Connectivity Link 1.4). The policy targets the Gateway, and `llm-models` has its own
  `TokenRateLimitPolicy`, which overrides it for that one route; Kuadrant then reports the whole
  policy as not enforced. The limits are in place on `llm-api-v1` / `llm-api-v2`
  (`oc get envoyfilter kuadrant-llm-gateway -n ai-gateways -o yaml | grep -o 'tokenlimit.api_free[^"]*' | sort -u`),
  and F5 shows the 429.
* **A TelemetryPolicy label `requestBodyJSON("/model")` (to get the model per consumer) breaks the
  limits:** the wasm shim can't read the request body at that point, the rate limit call fails
  (`kuadrant_wasm_shim: Task failed` in the gateway log) and, with `failureMode: allow`, nothing is
  limited any more. Only label with what's known from headers and identity. After removing a label,
  delete and re-create the TelemetryPolicy if the generated wasm config keeps it.
* **Praxis refuses a config with `security filter 'guardrails' ... has request conditions`:**
  `guardrails`, `rate_limit` and `credential_injection` can't be conditional. That's why the OpenAI
  guardrails sit on their own listener (`openai-egress`) that only OpenAI-bound requests reach.
* **`endpoint '127.0.0.1:8086' resolves to a sensitive address`:** the loopback hop needs
  `insecure_options.allow_private_endpoints: true`; `trusted_private_endpoints` doesn't accept IPs.
* **`pipeline contains multiple cluster-selecting filters before load_balancer (model_to_provider,
  router)`:** `model_to_provider` selects the cluster itself; use it instead of a `router`, not next to it.
* **`json_body: condition header 'x-model' cannot resolve a unique pending value` (500):** a
  `json_body` conditioned on `X-Model`, which `model_to_header` only sets while the body is being
  read. Condition on a header the client sent (like `x-data-classification`) or use
  `model_to_provider` for model rewrites.
* **An unknown model on `/v1` hangs until the route timeout (180 s) and then gives 404:** a bare
  404 from the Praxis router has no body framing and Envoy waits for more. Answer unknown models
  with a `static_response` (chains `unknown-model-v1` / `unknown-model-v2`).
* **The console's Praxis throttle change takes a minute:** the kubelet syncs ConfigMap volumes
  periodically. The console annotates the Praxis pod after the change, which makes the kubelet sync
  it right away (a few seconds). By hand: `oc annotate pod -l app=praxis-ai -n ai-gateways touch=$(date +%s) --overwrite`.
* **Console: `Backend: ... 403`:** its Role only covers the objects named in
  [`console.yaml`](../../stack/ai-gateways/console/openshift/console.yaml); a renamed policy or a
  third consumer key needs a line there (and `CONSUMERS` in the Deployment).
* **Console metrics tables stay empty:** wait for a scrape (Praxis every 15 s, Limitador 30 s), and
  check the ClusterRoleBinding `ai-gateway-console-monitoring-view` (Thanos querier access).

Parts A to E:

* **MaaS answers 503 for everything, `wasm_fail_stream` in the gateway log**
  (`oc logs -n openshift-ingress deploy/maas-default-gateway-openshift-default | grep wasm_fail`):
  after a cluster restart the MaaS gateway came up before the Kuadrant operator and never loaded
  the wasm plugin. `ai-gateways.sh` detects this (`maas_check`) and prints the fix:
  `oc rollout restart deploy/maas-default-gateway-openshift-default -n openshift-ingress`. To make it
  self-healing, deploy [`platform/30-gateway/wasm-watchdog.yaml`](../../platform/30-gateway/wasm-watchdog.yaml).
  Praxis Part A and Connectivity Link Part B don't depend on MaaS; Parts C and D do.
* **`llm-gateway` answers 503 right after deploy:** the same wasm-fetch race on a fresh Envoy pod.
  `deploy` checks for a 401 and restarts the gateway pods once. By hand:
  `oc delete pod -n ai-gateways -l gateway.networking.k8s.io/gateway-name=llm-gateway`.
* **One model on `llm-gateway` answers `500` (`cluster_not_found` in the gateway log), the other
  works:** `oc get httproute llm-models -n ai-gateways -o yaml` shows `ResolvedRefs=False
  RefNotPermitted`. On this cluster the `openshift-default` controller only honoured the first entry
  of a `ReferenceGrant` with several `to:` Services, so there is one `ReferenceGrant` per Service.
* **Every `llm-gateway` request is a 500, `gRPC status code is not OK` in the gateway log:** the
  Authorino TLS fix is missing (`oc get envoyfilter llm-gateway-authn-ssl -n ai-gateways`). See demo 10.
* **A valid key gets 401:** the Secret needs both labels from the start
  (`llm-gateway/consumer=true` and `authorino.kuadrant.io/managed-by=authorino`). Re-create it with
  `./deploy.sh ai-gateways key <user> <tier>`.
* **alice gets one more 200 than the arithmetic says:** Limitador checks the counter *before* the
  request and adds the tokens from the response *after* it, so the request that crosses 300 still
  succeeds and the next one is refused. Usage reported by the model is what counts.
* **`praxis_upstream_healthy_endpoints` is 0, `all endpoints unhealthy, routing to all (panic mode)`
  in the Praxis log:** a `type: http` health check on a TLS cluster. In Praxis core 0.7.5 the HTTP
  probe is plaintext; use `type: tcp` (as the config does).
* **Praxis returns 502 to a model, TLS error in the log:** the SNI must be the Service DNS name in
  the certificate (`<model>-kserve-workload-svc.maas-models.svc.cluster.local`), and
  `/etc/service-ca/service-ca.crt` must exist (`oc get cm ai-gateways-service-ca -n ai-gateways -o yaml`).
* **MaaS answers `500 Internal Server Error.` now and then, and the same call works a second
  later:** `maas-api` failed to validate the API key
  (`oc logs -n redhat-ods-applications deploy/maas-api | grep 'validation lookup failed'` shows
  `database lookup failed: context canceled`). That's a MaaS platform issue, not the demo's;
  `compare` retries a 500 once and marks the row.
* **MaaS `/v1/chat/completions` is 404 (`route_not_found`):** on OpenShift AI 3.4 MaaS has no
  body-based routing on this cluster; use the per-model base URL from `/v1/models`
  (`/maas-models/<model>/v1/...`). The Praxis `via-maas` listener builds that path for you.
* **Praxis → MaaS `/v1/messages` returns 401 although the client sent a MaaS key:** by design.
  `anthropic_messages_to_chat_completions` removes `x-api-key` and `authorization` so an Anthropic
  credential never reaches an OpenAI backend. Praxis injects its own key (`credential_injection`,
  Secret `praxis-maas-key`). Re-run `./deploy.sh ai-gateways deploy` if that key expired (30 days)
  or was minted while MaaS was down.
* **Praxis pod in CrashLoopBackOff with `security filter '...' has request conditions`:**
  `rate_limit` and `credential_injection` are security filters; Praxis refuses `conditions` on them
  because a condition is a bypass. Give them their own listener instead.
* **Praxis hot reload: `multiple path rewriting filters in pipeline`:** two `path_rewrite` filters
  on one listener need `allow_rewrite_override: true` on the later one. The rejected config is not
  applied; the previous one keeps serving.
* **Guarded listener: every request 500:** NeMo is unreachable or slow (fail closed). Check
  `oc get pods -n ai-gateways -l app=nemo-guardrails` (the image is large; the first start pulls
  it for a few minutes) and the NetworkPolicy, which only admits pods labelled `app: praxis-ai`.
* **Guarded listener: `422`:** a streaming request (`"stream": true`) while `phase.response` is on.
  Praxis can't screen SSE yet; send non-streaming requests, or set `response: false`.
* **NeMo `/v1/checks` returns 422 when called by hand:** the body is an OpenAI chat request plus
  `"guardrails": {"config_ids": ["confidential"]}` (not a top-level `config_ids`), and
  `rail_types` must only name rail types the config has flows for.
* **Praxis refuses to start: private address for the guardrails endpoint:** set
  `insecure_options.allow_private_upstreams: true` (Praxis's SSRF guard also covers callouts) and
  restrict who can reach NeMo with the NetworkPolicy.
* **Praxis `/v1/models` is 404:** this config only routes requests that carry a `model`. MaaS
  aggregates `/v1/models` per key; Connectivity Link has one `/<model>/v1/models` per model.
* **Praxis features in the docs that crash the pod with `unknown filter type`** (`token_ceiling`,
  token rate limiting, Responses API state): experimental filters aren't in the published
  `ghcr.io/praxis-proxy/ai:0.9.0` image. Praxis is alpha; APIs and config may change before 1.0.

Sources: [Praxis AI](https://github.com/praxis-proxy/ai), [Praxis on OpenShift AI workshop](https://github.com/rh-aiservices-bu/praxis-workshop),
[Red Hat Connectivity Link](https://docs.redhat.com/en/documentation/red_hat_connectivity_link),
[Kuadrant TokenRateLimitPolicy](https://docs.kuadrant.io/), [EnMaaS pilot blog](https://www.redhat.com/en/blog/EnMaaS-Red-Hat-pilot-for-open-source-inference).
