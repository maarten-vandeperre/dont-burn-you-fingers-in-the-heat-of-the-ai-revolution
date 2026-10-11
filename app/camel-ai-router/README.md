# camel-ai-router: one OpenAI-compatible endpoint, four backends, Camel circuit breaker + fallback

A small Quarkus + Apache Camel service that exposes a single OpenAI-compatible
`/v1/chat/completions` endpoint and routes every call to one of four backends:

* **local** — any OpenAI-compatible server on your machine or network: Ollama, llama.cpp, vLLM,
  Podman Desktop AI Lab, ...
* **openai** — the real OpenAI API (or an OpenAI-compatible proxy you point it at)
* **anthropic** — Anthropic's Claude models (native Messages API; translated to/from the OpenAI
  shape, see [below](#anthropic-is-translated-not-proxied))
* **vllm** — vLLM served "online", typically through OpenShift AI Models-as-a-Service, or any
  other OpenShift route in front of vLLM

The caller only ever sees one OpenAI-shaped API. Which backend actually answers is decided by a
default policy, by the caller (`?provider=` or a body field), and by a **Camel Circuit Breaker +
Fallback** pair of EIPs that keep the service answering when an online provider is slow, out of
quota, or simply down.

```
client ──POST /v1/chat/completions──> camel-ai-router (Quarkus + Camel, :8085)
                                           │
                                 RoutingDecision.resolve()        <- steering, default policy,
                                           │                         "forced to local" check
                        ┌──────────────────┼──────────────────┬─────────────────┐
                        ▼                  ▼                  ▼                 ▼
                     direct:local   openai-guarded     anthropic-guarded   vllm-guarded
                     (no CB, it's      (circuitBreaker + onFallback -> local, see below)
                      the fallback          │                  │                 │
                      target itself)        ▼                  ▼                 ▼
                                          OpenAI          Anthropic           vLLM on
                                                        (translated)      OpenShift AI
```

## Routing rules

1. **Steering.** The caller can pick the backend explicitly: the query parameter `?provider=...`
   or a `"provider": "..."` field in the JSON body (query param wins if both are present), one of
   `local`, `openai`, `anthropic`, `vllm`. The field is never forwarded downstream (it is not part
   of the OpenAI wire format, and some providers reject unknown fields).
2. **Default policy (`auto`, i.e. no steering).** **OpenAI if configured; otherwise the local
   model if configured; otherwise the request is rejected** with a clear error. Anthropic and
   vLLM are *only* used when explicitly steered to — they are never picked automatically.
3. **A "configured" check, always.** Steering to (or defaulting to) a backend that lacks its
   credentials/URL is rejected immediately with `503` — it never reaches the HTTP client as a
   confusing connection error.

## Circuit breaker + fallback (the Camel integration patterns)

Two complementary layers, both only ever falling back to the **local** model, and only when it is
configured:

### 1. Per-call: Circuit Breaker + Fallback EIP

Every online provider (openai, anthropic, vllm) is called through Camel's
[Circuit Breaker EIP](https://camel.apache.org/components/latest/eips/circuitBreaker-eip.html)
(MicroProfile Fault Tolerance): a timeout, and `onFallback()` for **any** failure — a timeout, a
500, an expired or wrong API key, "out of tokens", a dropped connection, anything:

```java
from("direct:openai-guarded")
    .circuitBreaker()
        .faultToleranceConfiguration()
            .timeoutEnabled(true).timeoutDuration(timeoutMs)
            .requestVolumeThreshold(failureThreshold).failureRatio(100).delay(openMinutes * 60_000L)
        .end()
        .to("direct:openai")
    .onFallback()
        // local configured? -> direct:local. Otherwise the error propagates (handled above by
        // chat-completions' own onException, which answers the caller with it).
    .end();
```

Falls back to local **immediately, on the very first failure**, whenever a local model is also
configured. If local is *not* configured, the error is returned to the caller as-is (there is
nothing to fall back to) — this is the "if none is configured, throw an error" / "no fallback
possible" case.

### 2. Across calls: "x failures in y minutes ⇒ force local for z minutes"

The per-call breaker above re-tries the online provider on the very next request (that is how
Circuit Breaker EIPs normally work: fail fast, retry soon). On top of it, `ProviderHealthTracker`
implements the exact, explicitly time-windowed policy asked for: once a provider has accumulated
**x failures within the last y minutes**, every request for the next **z minutes** goes to the
local model *directly* — **without even attempting the online call** — then automatically starts
trying it again. All three numbers are configurable, globally and per provider:

```properties
router.breaker.failure-threshold=5     # x
router.breaker.window-minutes=2        # y
router.breaker.open-minutes=5          # z
router.breaker.openai.failure-threshold=3     # per-provider override (same 3 keys)
```

Watch it live on `GET /v1/router/status` (see [API](#api)). This is why there are *two*
mechanisms instead of one: MicroProfile Fault Tolerance's circuit breaker only supports a
count-based rolling window (the last *n* calls), not a time-based one (the last *y* minutes) —
`ProviderHealthTracker` adds exactly that, in about 60 lines of plain Java.

### Anthropic is translated, not proxied

Anthropic's native API (`/v1/messages`) is not wire-compatible with OpenAI's
`/v1/chat/completions`: different auth header (`x-api-key` + `anthropic-version`, not `Bearer`), a
separate top-level `system` field instead of a `system`-role message, a required `max_tokens`,
and a different response shape (`content: [{type, text}]`, `usage.input_tokens` /
`output_tokens`). `AnthropicGateway` translates both directions, so the router stays
OpenAI-compatible end to end regardless of which backend actually answered — the caller never
needs to know.

## Admin page & Hawtio

`GET /admin` — a single page, no build step, served straight from a classpath resource — shows
**every call the router has handled**: which backend actually answered (or tried to and fell
back), the category (**local** / **maas** / **foundation-model** — see below), status, and
duration; click a row to see the **exact prompt and response bodies**. It also links to **Hawtio**
for a live view of the Camel route(s) themselves.

```
http://localhost:8085/admin
┌────────────────────────────────────────────────────────────────────────────┐
│ Time        Category          Provider              Status      Duration  │
│ 10:41:03.1  [foundation-model] openai                OK 200      412 ms    │  ← click a row to see
│ 10:41:05.4  [local]            local  (req: openai)  OK 200       38 ms    │     the prompt/response
│ 10:41:05.4  [local]            local  (req: openai)  OK 200 fallback  39ms │
└────────────────────────────────────────────────────────────────────────────┘
```

### Where the call log is populated

Everything is wired through plain Camel/CDI, no new infrastructure. Four touch points, in order:

1. **The raw prompt is captured once**, right after the body is read as a string and before
   `RoutingDecision` strips the `"provider"` field or any gateway mutates it — so the log always
   shows exactly what the caller sent, success or failure (`ChatRoutes.java`):

   ```java
   .convertBodyTo(String.class)
   .setProperty("rawRequestBody", simple("${body}"))
   .bean("routingDecision", "resolve")
   ```

2. **Every successful call is recorded** in `UsageRecorder.success()` (the same bean that already
   emits Micrometer metrics), with the category derived from the provider that actually answered:

   ```java
   callLog.record(ProviderRegistry.category(provider), provider, requested, backend, forcedLocal,
           fallback, true, 200, took.toMillis(), rawRequestBody(exchange), responseJson);
   ```

3. **Every failed call is recorded too**, in `UsageRecorder.errorBody()` (called from each
   `onException()` in `ChatRoutes`), with the OpenAI-shaped error body as the "response":

   ```java
   callLog.record(category, provider, requested, backend, forcedLocal, fallback, false, status,
           took(exchange).toMillis(), rawRequestBody(exchange), errorJson);
   ```

4. **The category itself** — what the admin page's colored pill shows — is one line in
   `ProviderRegistry.java`, so adding a backend later just means extending this `switch`:

   ```java
   public static String category(String provider) {
       return switch (provider) {
           case LOCAL -> "local";
           case VLLM -> "maas";                       // OpenShift AI Models-as-a-Service
           case OPENAI, ANTHROPIC -> "foundation-model"; // hosted frontier model APIs
           default -> "unknown";
       };
   }
   ```

The entries themselves live in `CallLogStore` — a capped in-memory ring buffer
(`CallLogStore.CAPACITY = 200`, edit that constant for a longer/shorter history), **not** a
database: it is for "what just happened" visibility, lost on restart, same spirit as the admin
page. `GET /admin/calls` (list, used by the page's table) and `GET /admin/calls/{id}` (one call's
full detail, used when you click a row) are plain Camel routes in `AdminRoutes.java`:

```java
from("platform-http:/admin/calls/{id}?httpMethodRestrict=GET")
        .routeId("admin-calls-detail")
        .bean("callLogStore", "callJson")
        .setHeader(Exchange.CONTENT_TYPE, constant("application/json"));
```

The page itself (`src/main/resources/admin/admin.html` — vanilla HTML/CSS/JS, no framework, no
build step) is read once at startup by `AdminPage.java` and served as-is; edit that file and
rebuild to change the UI.

### Hawtio: view (and operate on) the live Camel route(s)

`/admin` links to **`/hawtio`**, the standard [Hawtio](https://hawt.io) console wired up for this
app via two dependencies in `build.gradle.kts`:

```kotlin
// camel-quarkus-management registers the Camel context/routes as JMX MBeans -- what Hawtio
// actually talks to, over an embedded Jolokia HTTP bridge (no JMX port needs to be exposed).
implementation("io.hawt:hawtio-quarkus:5.2.1")
implementation("org.apache.camel.quarkus:camel-quarkus-management")
implementation("org.apache.camel.quarkus:camel-quarkus-jaxb")   // route diagram tab
implementation("org.apache.camel.quarkus:camel-quarkus-debug")  // breakpoint / message editor tab
```

and two properties in `application.properties` (this is a demo with no users configured, so
authentication is off; see [Hawtio's security docs](https://hawt.io/docs/security.html) for
turning it back on with `quarkus.security.users.embedded.*`):

```properties
quarkus.hawtio.authenticationEnabled=false
quarkus.camel.debug.enabled=true
```

Open **http://localhost:8085/hawtio**, go to the **Camel** plugin, and you get, per route
(`chat-completions`, `local`, `openai-guarded`, `anthropic-guarded`, `vllm-guarded`, `admin-page`,
...):

* the **route diagram** and live per-endpoint statistics (message counts, timings)
* **Start / Stop / Suspend / Resume**, for real — this is operational control of the running
  route, not just a read-only view. Proven end to end (what the Hawtio buttons do under the hood,
  via the Jolokia HTTP bridge the console itself talks to):

  ```bash
  curl -X POST localhost:8085/hawtio/jolokia -H 'Content-Type: application/json' -d \
    '{"type":"exec","mbean":"org.apache.camel:context=camel-1,type=routes,name=\"chat-completions\"","operation":"stop()"}'
  # -> GET /v1/chat/completions now 405: the route is gone from the HTTP router, live, with zero redeploys.
  # ...and "operation":"start()" the same way brings it straight back.
  ```
* the **Debug** tab: set a breakpoint on any node in a route, send a request, and the message
  (headers, properties, body) is suspended there for inspection — and **editing**, before letting
  it continue. This is the closest thing to live-editing a route's behavior that is meaningful for
  compiled Java DSL routes (the route's *structure* is compiled code and cannot be hot-swapped,
  but the *messages* flowing through it, and whether each route is running at all, genuinely can).

## Configuration

Copy `.env.example` to `.env` (git-ignored) and fill in what you have. **Nothing is required to
start the app**, but the default routing needs at least `OPENAI_API_KEY` or `LOCAL_BASE_URL`.

| Variable | Backend | Meaning |
|---|---|---|
| `OPENAI_API_KEY` | openai | set ⇒ openai is "configured" |
| `OPENAI_MODEL` | openai | default model when the caller does not send one (`gpt-4o-mini`) |
| `OPENAI_BASE_URL` | openai | override to point at an OpenAI-compatible proxy |
| `ANTHROPIC_API_KEY` | anthropic | set ⇒ anthropic is "configured" |
| `ANTHROPIC_MODEL` | anthropic | default model (`claude-3-5-haiku-latest`) |
| `ANTHROPIC_MAX_TOKENS` | anthropic | required by the Messages API; default when the caller omits `max_tokens` |
| `VLLM_BASE_URL` | vllm | set ⇒ vllm is "configured". `https://maas.<apps-domain>/<namespace>/<model>` for OpenShift AI MaaS |
| `VLLM_API_KEY` | vllm | optional (gateway dependent) |
| `VLLM_MODEL` | vllm | default model when the caller does not send one |
| `VLLM_TRUST_ALL` | vllm | `true` for a self-signed lab ingress certificate |
| `LOCAL_BASE_URL` | local | set ⇒ local is "configured". From inside a container the laptop is `host.containers.internal`, not `localhost` |
| `LOCAL_API_KEY` | local | optional — most local servers need none |
| `LOCAL_MODEL` | local | default model when the caller does not send one |
| `BREAKER_FAILURE_THRESHOLD` | all online | x: failures |
| `BREAKER_WINDOW_MINUTES` | all online | y: minutes |
| `BREAKER_OPEN_MINUTES` | all online | z: minutes forced to local |
| `BREAKER_TIMEOUT_MS` | all online | per-call timeout before it counts as a failure |

Per-provider overrides (not exposed as env vars, set directly if you build your own image/config):
`router.breaker.openai.failure-threshold`, `router.breaker.anthropic.window-minutes`,
`router.breaker.vllm.open-minutes`, ...

## Run

```bash
./start.sh                               # first run: creates .env from .env.example, then builds + starts
podman compose logs -f camel-ai-router   # until "started in ..."
```
Or plain `podman compose up --build -d`. API on **http://localhost:8085**.

```bash
curl -s localhost:8085/v1/models | jq
curl -s localhost:8085/v1/router/status | jq
curl -s localhost:8085/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "messages": [{"role": "user", "content": "Two cappuccinos please"}]
}' | jq
```
Then open **http://localhost:8085/admin** to see that call in the log (click it for the exact
prompt/response), and **http://localhost:8085/hawtio** for the live Camel route view.

Stop: `podman compose down`. After changing `.env`: `podman compose up -d` again.

### Running without podman (local JVM)

```bash
./gradlew quarkusDev     # live reload on :8080
```

## API

| | |
|---|---|
| `POST /v1/chat/completions` | OpenAI chat completions request, plus optional `"provider"` field. Response headers `X-Router-Provider` (who actually answered) and `X-Router-Backend` (provider + model) |
| `?provider=local\|openai\|anthropic\|vllm\|auto` | same steering, as a query parameter instead of a body field |
| `GET /v1/models` | the four backend ids and whether each is configured |
| `GET /v1/router/status` | which backend `auto` would use right now, and per online provider: recent failures, threshold/window/open-duration, whether it is currently forced to local and until when |
| `GET /admin` | admin page: live call log (click a row for the prompt/response), links to Hawtio |
| `GET /admin/calls`, `GET /admin/calls/{id}` | JSON APIs behind the admin page (list / one call's full detail) |
| `GET /hawtio` | Hawtio console: live Camel route diagrams/stats, start/stop/suspend/resume, message debugger |
| `GET /q/health`, `/q/health/ready` | container healthcheck |
| `GET /q/metrics` | Prometheus: `ai_router_requests_total{provider,outcome}`, `ai_router_tokens_total{provider,type}`, `ai_router_fallbacks_total{requested,reason}`, `ai_router_latency_seconds{provider,backend}` |

Errors are OpenAI-shaped: `{"error": {"type": "...", "message": "...", "provider": "..."}}` —
`400` unknown `provider`, `503` provider not configured, `502` the provider call failed (and
either there was no local model to fall back to, or local failed too).

## Try the circuit breaker without any real API key

Two one-line fake OpenAI-compatible servers are enough to see the whole policy end to end:
```bash
# a "good" local model on :9101, and an openai that always fails on :9102
python3 -c "
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); self.rfile.read(n)
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps({'choices':[{'message':{'role':'assistant','content':'hi from local'}}],
            'usage':{'prompt_tokens':1,'completion_tokens':1}}).encode())
HTTPServer(('0.0.0.0', 9101), H).serve_forever()" &
python3 -c "
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); self.rfile.read(n)
        self.send_response(500); self.end_headers()
HTTPServer(('0.0.0.0', 9102), H).serve_forever()" &

OPENAI_API_KEY=sk-test OPENAI_BASE_URL=http://localhost:9102 \
LOCAL_BASE_URL=http://localhost:9101 \
BREAKER_FAILURE_THRESHOLD=2 BREAKER_WINDOW_MINUTES=2 BREAKER_OPEN_MINUTES=1 \
./gradlew quarkusDev
```
Then, in another terminal: a default (`auto`) request goes to OpenAI, fails, and falls back to
local (`X-Router-Provider: local`) — do it twice and `curl localhost:8080/v1/router/status` shows
`"forced_local_now": true` for `openai`; every request for the next minute goes to local directly
(and would, even if you stopped the fake OpenAI server entirely); after that minute it tries
OpenAI again on its own.

## OpenShift AI Models-as-a-Service for `vllm`

`VLLM_BASE_URL=https://maas.<apps-domain>/<namespace>/<model>`, the key from **OpenShift AI > Gen
AI Studio > API keys**. Lab clusters with a self-signed ingress certificate: `VLLM_TRUST_ALL=true`.
Steer to it explicitly (`?provider=vllm`), or let it be the local fallback's online counterpart by
simply configuring it alongside `OPENAI_API_KEY` — the default policy itself never auto-selects
vLLM or Anthropic, only OpenAI then local, as asked.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `503 no provider is configured` | neither `OPENAI_API_KEY` nor `LOCAL_BASE_URL` is set in `.env` |
| `503 provider 'x' is not configured` | you steered to a backend without its credentials/URL; fill in `.env` and `podman compose up -d` |
| `400 unknown provider` | `?provider=` or the body field is not one of `local`, `openai`, `anthropic`, `vllm`, `auto` |
| `502` even though local is configured | local failed too (check `podman compose logs camel-ai-router` and reach the local server directly); the error message is the local server's own |
| requests keep going to local even though OpenAI looks fine | `GET /v1/router/status`: `forced_local_now` for openai; wait out `forced_local_until`, or restart the app to reset it sooner |
| vLLM / self-signed certificate errors | `VLLM_TRUST_ALL=true` in `.env` |
| `404` on `POST /v1/chat/completions` | the request's `Content-Type` was not `application/json` (e.g. `curl -d '...'` without `-H 'Content-Type: application/json'` sends `application/x-www-form-urlencoded` by default). The endpoint only accepts `application/json` (enforced by Vert.x before Camel is even invoked, via the `consumes=application/json` route option) and rejects anything else; always set the header explicitly |
