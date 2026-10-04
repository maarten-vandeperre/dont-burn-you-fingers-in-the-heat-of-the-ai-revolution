# Demo 7: Platform Coffee

**The story:** one small, real-looking application uses every platform capability at once: AI
ordering on the platform's models, a menu service that is released and broken on purpose through
the mesh, an audit trail nobody had to code into the application, and AI traces in MLflow.

**Duration:** 20 minutes (12 UI, 8 IntelliJ). Each part also works on its own.

| Part | Platform capability |
|---|---|
| Ordering in plain language | Models-as-a-Service, Camel model router, LangChain4j |
| Orders and audit trail | PostgreSQL, Debezium, Kafka, MongoDB |
| Menu releases and chaos | Service Mesh: versions, mirroring, fault injection; app fault tolerance |
| AI traces | OpenShift AI MLflow, fed by the platform's OpenTelemetry collector |

Every step below has three parts: **Do**, **You see**, **Say**.

---

## Before you start

1. Terminal:
   ```bash
   ./deploy.sh app menu reset     # menu v1, no faults
   ./deploy.sh app urls           # "Coffee shop" URL
   ```
   On a platform that ran the demo apps before the coffee shop existed: `./deploy.sh app update` once.
2. Browser: **Coffee shop**, **Kiali** (Traffic Graph, namespace ai-demo), **OpenShift AI**.
3. **IntelliJ** on the repository folder.
4. Place one test order (the first model call is the slowest).

---

## Part A: order in plain language (4 minutes)

**A1. An order the model understands.**
* **Do:** Coffee shop > tab **Order**. Text `Two large oat lattes and a cappuccino, please.` >
  **Interpret order**.
* **You see:** a quote with each line, unit prices and the total (EUR 14.00 with menu v1), the badges
  `menu v1` and `menu live`, and `MLflow trace tr-...`.
* **Say:** "The model turns free text into structured JSON. The prices come from the menu service,
  never from the model: a model can be wrong, the price list cannot."

**A2. Ambiguity and limits.**
* **Do:** `Coffee, please.` > **Interpret order**. Then `A mocha` (not on menu v1).
* **You see:** a clarifying question; then a refusal: the drink is not on the current menu.
* **Say:** "The server validates every line against the live menu. That is the guardrail."

**A3. Place it.**
* **Do:** **Place order**. The app switches to **Orders**.
* **You see:** the order, read from PostgreSQL, status PLACED.

---

## Part B: an audit trail nobody coded (3 minutes)

* **Do:** **Orders** > click **Start brewing**, **Mark ready**, **Collected**. Then tab **Audit**.
* **You see:** events, newest first: `created` for the order and each line, `updated` such as
  `order 3: BREWING -> READY`. Click an event: the row **before** and **after** and the Kafka offset.
* **Do:** cancel another order in **Orders**, back to **Audit**.
* **You see:** `deleted` events with the complete deleted row.
* **Say:** "The coffee shop only writes to PostgreSQL. Debezium turns every change into an event,
  the projection-service stores them in MongoDB, and this tab reads only MongoDB. A complete audit
  trail, without a single line of audit code in the application."

---

## Part C: release the menu through the mesh (3 minutes)

Switch scenarios in a terminal (or Developer Hub > **Create** > **Coffee menu: traffic & chaos**).
After each switch: tab **Menu & resilience** > **Probe coffee-menu**.

| Do | You see |
|---|---|
| `./deploy.sh app menu canary 20` | probe about 80% v1 / 20% v2; the Order tab sometimes offers the mocha |
| `./deploy.sh app menu green` | 100% v2: new prices; the same order now costs more, quote shows `menu v2` |
| `./deploy.sh app menu blue` | back to v1, instantly |
| `./deploy.sh app menu mirror` | probe 100% v1, yet `oc logs deploy/coffee-menu-v2 -n ai-demo -c app` shows every call |

* **Say:** "The coffee shop never knows which menu version it talks to. Release decisions live in
  the mesh, not in the application."

---

## Part D: break it on purpose (3 minutes)

| Do | Raw probe | The shop |
|---|---|---|
| `./deploy.sh app menu delay 50` | about half the calls take 3 s (p95 near 3000 ms) | ordering stays fast: after 1.5 s it uses its cached menu, badge `menu cache` |
| `./deploy.sh app menu abort 30` | about 30% `HTTP 503` | retries hide most errors, the rest is answered from the cache |
| `./deploy.sh app menu abort 100` | 100% `HTTP 503` | the circuit breaker opens; every order is priced from the cache and still works |

* **Do:** keep Kiali's graph open: the coffee-menu edge turns red with 503s.
* **Say:** "Chaos is a few lines of mesh configuration. The application survives because it has
  timeouts, retries, a circuit breaker and a fallback: four annotations, shown in a minute."
* **Do:** `./deploy.sh app menu reset`.

---

## Part E: the AI trace in MLflow (2 minutes)

* **Do:** in the Order tab click **open in MLflow** after an interpretation (or OpenShift AI >
  **Applications** > **MLflow UI**, workspace **ai-demo**, experiment **coffee-shop**, tab **Traces**).
* **You see:** one trace per order: root span `coffee order` with the order as input and the quote
  as output; below it the LangChain4j span with the full prompt (rules plus the menu of the moment)
  and the model's JSON; the menu lookups, with the 1.5 s timeouts if chaos was on.
* **Say:** "AI engineers see exactly what the model saw and said, per request. No MLflow SDK in the
  app: the platform's collector forwards these spans."

---

## Part F: the code in IntelliJ (8 minutes)

**F1. The AI service.**
* **Do:** open `CoffeeAssistant.java` (app/coffee-shop).
* **Point at:** `@RegisterAiService`, the `@SystemMessage` with the rules, and `@UserMessage` with the
  `{drinks}` of the live menu.
* **Say:** "A Java interface is the whole AI integration. The menu goes into every prompt, so a new
  menu version is understood without retraining or redeploying."

**F2. The server prices, the model does not.**
* **Do:** open `CoffeeResource.java`, method **`price`**.
* **Point at:** every line checked against the menu, sizes and milk validated, at most six cups,
  prices computed server-side.

**F3. Fault tolerance in four annotations.**
* **Do:** open `MenuService.java`, method **`current`**.
* **Point at:** `@Timeout(1500)`, `@Retry(maxRetries = 2, ...)`, `@CircuitBreaker(...)`,
  `@Fallback(fallbackMethod = "cached")`.
* **Say:** "That is why part D did not break the shop."

**F4. The chaos is configuration.**
* **Do:** open `app/deploy/patterns/menu-delay.yaml` and `menu-abort.yaml`.
* **Point at:** `fault.delay.fixedDelay: 3s` and `fault.abort.httpStatus: 503` with a percentage.

**F5. The audit trail.**
* **Do:** open `CoffeeAuditConsumer.java` (app/projection-service).
* **Point at:** `@Incoming("coffee-orders")` / `@Incoming("coffee-lines")`, the readable `summary`,
  and the insert into the `coffee_audit` collection.

**F6. The MLflow trace.**
* **Do:** in `CoffeeResource.java`, method **`interpret`**, then `MlflowSpanMarker.java`.
* **Point at:** `spanBuilder("coffee order")`, `setNoParent()`, the attributes `mlflow.spanInputs` /
  `mlflow.spanOutputs`; the marker that tags every child span for the collector's MLflow pipeline.

---

## Part G: prove it from the terminal (optional)

```bash
./deploy.sh app coffee
```
Expected: a quote (`2 lines, total 14 EUR, menu v1 (live)`), order PLACED > BREWING > READY, then the
audit events from MongoDB and `OK audit complete after ~4 s`.

```bash
./deploy.sh app menu delay 100 && ./deploy.sh app coffee && ./deploy.sh app menu reset
```
Expected: the probe shows about 3000 ms latency, yet the order completes with `menu v1 (cache)`.

## Reset

```bash
./deploy.sh app menu reset
```

## If something goes wrong

* **Route not found:** `./deploy.sh app update` (or `./deploy.sh app all` on a fresh platform).
* **Audit stays empty:** the connector must capture the coffee tables:
  `oc get kafkaconnector inventory-postgres -n kafka -o jsonpath='{.spec.config.table\.include\.list}'`;
  `./deploy.sh app setup` adds them.
* **"not something we can make":** the model chose a drink that is not on the current menu: that is
  the validation working. Rephrase, or switch to menu v2.
* **502 on interpret:** the model is slow or down; `COFFEE_MODEL` on the coffee-shop Deployment picks
  the alias (`qwen`, `gemma`, `openai`, `auto`).
* **No MLflow link or traces:** `./deploy.sh app mlflow`, then interpret a new order.
