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

### Show it on Kafka (optional, 4 minutes)

The Audit tab shows the **source table** of each change (`coffee.orders`). The event itself
travels through a Kafka **topic** named `<prefix>.<schema>.<table>`: Debezium's prefix is
`inventory` (`stack/kafka/connector.yaml`), so:

| Source table (Audit tab) | Kafka topic | Read by |
|---|---|---|
| `coffee.orders` | `inventory.coffee.orders` | projection-service, consumer group `projection-service-coffee` |
| `coffee.order_lines` | `inventory.coffee.order_lines` | same |

**B1. The topics.**
* **Do:** in a terminal, define a small helper once:
  ```bash
  kafka() { local tool=$1; shift; oc exec -n kafka platform-dual-role-0 -c kafka -- /opt/kafka/bin/"$tool" --bootstrap-server localhost:9092 "$@"; }
  ```
  (bash and zsh; it runs the Kafka tools inside the Kafka pod)
  ```bash
  kafka kafka-topics.sh --list | grep -v '^__'
  ```
* **You see:** `inventory.coffee.orders`, `inventory.coffee.order_lines`, the topics of demo 4
  (`inventory.inventory.customers`, `inventory.inventory.orders`) and Kafka Connect's own
  `debezium-connect-*` topics.
* **Say:** "Nobody created these topics: Debezium did, one per captured table."

**B2. The events, as they are stored.**
* **Do:**
  ```bash
  kafka kafka-console-consumer.sh --topic inventory.coffee.orders --from-beginning --timeout-ms 5000 \
    | jq -c 'select(. != null) | (.payload // .) | {op, order: (.after // .before).id, status: [.before.status, .after.status]}'
  ```
* **You see:** one line per change, oldest first, for example:
  ```
  {"op":"c","order":1,"status":[null,"PLACED"]}
  {"op":"u","order":1,"status":["PLACED","BREWING"]}
  {"op":"u","order":1,"status":["BREWING","READY"]}
  ```
  `op`: `c` created, `u` updated, `d` deleted, `r` read during the initial snapshot.
* **Do (the full event):** the first event with all its fields:
  ```bash
  kafka kafka-console-consumer.sh --topic inventory.coffee.orders --from-beginning --max-messages 1 \
    | jq '.payload // .'
  ```
* **You see:** `before`, `after` (the complete rows), `source` (database, schema, table, transaction
  id, log position) and `ts_ms`.
* **Say:** "Every change, with the row before and after. The Audit tab is just a readable view of
  these events."

**B3. Watch a change travel, live.**
* **Do:** leave this running in a terminal next to the browser (Ctrl+C to stop):
  ```bash
  kafka kafka-console-consumer.sh --topic inventory.coffee.orders \
    | jq -c 'select(. != null) | (.payload // .) | {op, order: (.after // .before).id, status: [.before.status, .after.status]}'
  ```
  In the app: **Orders** > **Start brewing** on an order.
* **You see:** within a second a new line such as `{"op":"u","order":2,"status":["PLACED","BREWING"]}`,
  and two seconds later the same change in the **Audit** tab.
* **Say:** "The application did an UPDATE in PostgreSQL. Debezium read it from the database log
  and put it on Kafka; the projection-service turned it into the audit document."

**B4. Who reads it, and how far behind.**
* **Do:**
  ```bash
  kafka kafka-consumer-groups.sh --describe --group projection-service-coffee
  ```
* **You see:** per topic `CURRENT-OFFSET` (what the projection-service has processed),
  `LOG-END-OFFSET` (what is on the topic) and `LAG` (the difference): normally `0`.
* **Do (resilience):** `oc scale deploy/projection-service -n ai-demo --replicas=0`; advance an order
  twice in the app; run the command again: `LAG` is `2` and the Audit tab stays the same. Then
  `oc scale deploy/projection-service -n ai-demo --replicas=1`: after a few seconds `LAG` is `0`
  and both events are in the Audit tab.
* **Say:** "Kafka keeps the events while the consumer is down. Nothing is lost, it just catches up."

---

## Part C: release the menu through the mesh (3 minutes)

Switch scenarios in a terminal (or Developer Hub > **Create** > **Coffee menu: traffic & chaos**).
Each command applies one VirtualService file. To change the weights or the mirror percentage in
the file and apply it yourself, use the file in the table and `oc apply -f` that path. The
object name stays `coffee-menu`. Full edits: [service-mesh.md](service-mesh.md), section 3.

| Command | File | Field |
|---|---|---|
| `./deploy.sh app menu canary 20` | `app/deploy/patterns/menu-canary.yaml` | `weight` 80 on subset v1, 20 on v2 |
| `./deploy.sh app menu green` | `app/deploy/patterns/menu-green.yaml` | `subset: v2` |
| `./deploy.sh app menu blue` | `app/deploy/patterns/menu-blue.yaml` | `subset: v1` |
| `./deploy.sh app menu mirror` | `app/deploy/patterns/menu-mirror.yaml` | `mirror.subset: v2`, `mirrorPercentage.value: 100.0` |

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

The fault is a block on the same VirtualService. `menu-delay.yaml` sets `fault.delay.fixedDelay`
and `fault.delay.percentage.value`. `menu-abort.yaml` sets `fault.abort.httpStatus` (503) and
`fault.abort.percentage.value`. Apply the file, or let the helper rewrite the percentage and apply it:

```bash
oc apply -f app/deploy/patterns/menu-delay.yaml    # 3s on 50% of calls, as committed
oc apply -f app/deploy/patterns/menu-abort.yaml    # HTTP 503 on 30% of calls, as committed
oc apply -f app/deploy/patterns/menu-reset.yaml    # v1, no fault
```

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
