# camel-ai-router: demo guide

**The story:** one OpenAI-compatible endpoint in front of four backends (local, OpenAI,
Anthropic, vLLM on OpenShift AI), built with Apache Camel's **Content-Based Router**,
**Circuit Breaker** and **Fallback** EIPs. By default it goes to OpenAI; if OpenAI is not
configured, to the local model; if neither is, it refuses. If OpenAI starts failing, it falls
back to local immediately — and if it keeps failing, the router stops even trying it for a while
and goes to local directly.

**Duration:** 13 minutes. **Screens:** a terminal with `curl`, IntelliJ on
`app/camel-ai-router/src/main/java/org/acme/camelrouter`, and a browser on
`http://localhost:8085/admin` for Part F.

Every step has three parts: **Do**, **You see**, **Say**.

---

## Before you start

```bash
cd app/camel-ai-router
cp .env.example .env     # fill in OPENAI_API_KEY, or just LOCAL_BASE_URL — either is enough
./start.sh
curl -s localhost:8085/v1/models | jq
```
No real key handy? Use the two fake backends from the README's
["Try the circuit breaker without any real API key"](README.md#try-the-circuit-breaker-without-any-real-api-key)
section instead of `./start.sh` — that is exactly what the rest of this guide assumes
(`BREAKER_FAILURE_THRESHOLD=2`, `BREAKER_OPEN_MINUTES=1`, OpenAI on :9102 always failing, local on
:9101 always succeeding).

---

## Part A: the default policy (2 minutes)

* **Do:**
  ```bash
  curl -s localhost:8085/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"hi"}]}' -D - | grep -i x-router
  ```
* **You see:** `X-Router-Provider: openai` (or `local`, if you did not configure an OpenAI key).
* **Say:** "No `provider` field anywhere in that request. The router's own default policy picked
  OpenAI because it is configured; if it were not, it would have picked the local model; if
  neither were configured, it would have answered with a `503` instead of guessing."
* **Defined in:** `RoutingDecision.resolve()` — plain Java, not nested EIPs, on purpose: it is the
  one place that answers "which backend, and why".

## Part B: steering (2 minutes)

* **Do:**
  ```bash
  curl -s "localhost:8085/v1/chat/completions?provider=local" -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"hi"}]}' -D - | grep -i x-router
  curl -s localhost:8085/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"provider":"local","messages":[{"role":"user","content":"hi"}]}' -D - | grep -i x-router
  ```
* **You see:** both answer with `X-Router-Provider: local` — a query parameter and a body field,
  same effect.
* **Say:** "Either way to steer it. Try `?provider=bogus` and you get a `400` immediately — it
  never reaches an HTTP client as a confusing connection error."

## Part C: a provider failing, falling back right away (3 minutes)

* **Do:** make OpenAI fail (already the case with the fake backend above; with a real key,
  temporarily set `OPENAI_API_KEY` to garbage and `podman compose up -d`), then:
  ```bash
  curl -s localhost:8085/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"hi"}]}' -D - | grep -i x-router
  ```
* **You see:** `HTTP/1.1 200`, `X-Router-Provider: local` — the OpenAI call failed, and the
  **same request** still got an answer, from local, immediately.
* **Say:** "No retry loop, no 500 shown to the user. Camel's Circuit Breaker EIP wraps the OpenAI
  call; its `onFallback()` checks whether local is configured and, since it is, replays the exact
  same request there." Open `ChatRoutes.guarded()` and show the `.circuitBreaker()
  .onFallback()` block.
* **Do:** `curl -s localhost:8085/v1/router/status | jq '.providers.openai'`
* **You see:** `"recent_failures": 1`, `"forced_local_now": false`.
* **Say:** "One failure recorded. One more (the threshold here is 2) and it stops trying OpenAI
  altogether for a while."

## Part D: "x failures in y minutes ⇒ z minutes forced to local" (3 minutes)

* **Do:**
  ```bash
  curl -s -o /dev/null localhost:8085/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"hi"}]}'   # the 2nd failure
  curl -s localhost:8085/v1/router/status | jq '.providers.openai'
  ```
* **You see:** `"forced_local_now": true`, `"forced_local_until": "..."` about a minute out.
* **Say:** "Two failures within the window, so for the next minute every request skips OpenAI
  entirely — not even an attempt, straight to local. Stop the fake OpenAI server altogether if you
  want: the next request still answers instantly, because it is not even tried."
* **Do:** wait out the minute (`sleep 65`), then repeat Part A's `curl`.
* **You see:** `X-Router-Provider: openai` again (once it is healthy).
* **Say:** "`ProviderHealthTracker` is the one piece MicroProfile Fault Tolerance's own circuit
  breaker cannot do on its own: a *time*-windowed policy, not just a count of the last *n* calls.
  Both numbers — the breaker's own count-based safety net, and this time-based policy — are
  configurable, independently per provider."

## Part E: Anthropic is a different wire format (2 minutes)

* **Do:** with `ANTHROPIC_API_KEY` set:
  ```bash
  curl -s "localhost:8085/v1/chat/completions?provider=anthropic" -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"system","content":"be terse"},{"role":"user","content":"hi"}]}' | jq
  ```
* **You see:** a normal OpenAI-shaped response (`choices[0].message.content`, `usage.prompt_tokens`).
* **Say:** "Anthropic's own API looks nothing like this — different auth header, a separate
  `system` field, a different response shape entirely. `AnthropicGateway` translates both
  directions so the router is OpenAI-compatible end to end, whichever backend actually answered."
  Show `AnthropicGateway.toAnthropicRequest` / `toOpenAiResponse`.

## Part F: the admin page, and Hawtio for the route(s) themselves (3 minutes)

* **Do:** open **http://localhost:8085/admin** in a browser (keep it open through this whole
  demo — it auto-refreshes every 3 seconds).
* **You see:** every call made so far in Parts A–E, newest first: time, a colored **category**
  pill (`local` / `maas` / `foundation-model`), the provider that actually answered (with the
  originally *requested* one shown too when a fallback changed it), status, duration, and
  `fallback` / `forced-local` flags on the rows where that happened in Part C/D.
* **Say:** "Every single thing we just did by curling and reading JSON by hand is right here, live,
  for whoever is on call. No new infrastructure — it is a 200-entry ring buffer in memory, fed from
  the same `UsageRecorder` bean that already emits the Prometheus metrics."
* **Do:** click any row, ideally one of the fallback rows from Part C.
* **You see:** the exact request body the caller sent (**prompt**) and the exact body the chosen
  backend returned (**response**), pretty-printed, side by side.
* **Say:** "This is the actual payload, not a summary — if a demo (or a production call) ever
  looks wrong, this is where you'd look first." Show `CallLogStore.record()` and point out it is
  called from exactly two places: `UsageRecorder.success()` and `.errorBody()` — success and
  failure both get logged.
* **Do:** click **"Camel routes (Hawtio) →"** in the top-right of the admin page (opens
  `/hawtio`); in Hawtio, open the **Camel** plugin in the left nav.
* **You see:** every route this app defined — `chat-completions`, `local`, `openai-guarded`,
  `anthropic-guarded`, `vllm-guarded`, `admin-page`, ... — each with a diagram and live stats
  (message counts, processing time).
* **Say:** "This isn't our code — it's two dependencies (`hawtio-quarkus`,
  `camel-quarkus-management`) and two config lines. Camel registers every route as a JMX MBean;
  Hawtio talks to that over an embedded HTTP/Jolokia bridge, so this works in a container with no
  JMX port exposed."
* **Do:** select the `chat-completions` route in Hawtio and click **Stop**; then, in the terminal:
  ```bash
  curl -s -o /dev/null -w '%{http_code}\n' localhost:8085/v1/chat/completions -d '{}'
  ```
* **You see:** `405` — the route is gone from the HTTP router, live, no redeploy.
* **Say:** "That's genuine operational control, not just a dashboard — the same Start/Stop/
  Suspend/Resume buttons work on any route here." Click **Start** in Hawtio to bring it back,
  then confirm with the same `curl` (now `200` again, body `{}` is rejected further in but at
  least the route answers).
* **Do (if time):** open the **Debug** tab for the `chat-completions` route, set a breakpoint on
  the `routingDecision` step, send one more request from a second terminal, and show the
  suspended message's headers/properties/body in Hawtio.
* **Say:** "This is as close to 'editing a live route' as it gets for compiled Java DSL — the
  route's structure can't be hot-swapped, but every message flowing through it can be paused,
  inspected, and edited before you let it continue."

---

## Wrap-up talking points

* One Camel route (`ChatRoutes`), four backends, and the only backend-specific code is in the
  gateways — adding a fifth provider is a new `*Gateway` + `*Client` pair and one line in
  `ProviderRegistry`/`ChatRoutes`.
* The resilience policy is pure configuration (`BREAKER_*`), not code, and testable without any
  real provider — see the fake-backend recipe in the README.
* On OpenShift AI, `vllm` is the exact same shape as `openai`/`local` (OpenAI-compatible), just
  reached through Models-as-a-Service; nothing in the routing or circuit breaker code is
  OpenShift-specific.
* Observability came "for free" once the EIPs existed: the admin page and Hawtio are both just
  wiring on top of what Camel already tracks (exchange properties, JMX-managed routes) — no
  separate logging pipeline or APM agent needed for a demo like this one.
