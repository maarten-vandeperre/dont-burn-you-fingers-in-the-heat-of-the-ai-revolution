# Demo 4: Change data capture

**The story:** applications write to their own database and nothing else. Every change becomes an
event automatically (Debezium), and other services build the view they need from those events,
without touching the source database or the application that owns it.

**Duration:** 12 minutes (5 UI, 2 console, 5 IntelliJ).

**Path:** orders-service > PostgreSQL `inventory-db` > Debezium (Kafka Connect) > Kafka topics
`inventory.inventory.customers` / `.orders` > projection-service > MongoDB `customer_views`.

Every step below has three parts: **Do**, **You see**, **Say**.

---

## Before you start

1. Terminal:
   ```bash
   oc get kafkaconnector inventory-postgres -n kafka   # READY True
   ./deploy.sh app urls
   ```
2. Browser: **Demo UI**, tab **CDC**; **OpenShift console**.
3. **IntelliJ** on the repository folder.

---

## Part A: watch a change travel (5 minutes)

**A1. The three stages on one screen.**
* **Do:** Demo UI > **CDC**.
* **You see:** three cards: **1. Write to PostgreSQL** (forms), **2. Debezium + Kafka**, and
  **3. MongoDB read model** (refreshed every 2 seconds).
* **Say:** "Left is the system of record. Right is a read model in a different database, built only
  from events."

**A2. Create a customer.**
* **Do:** fill in first name, last name and email in card 1, click **Create customer**.
* **You see:** within one or two seconds a new customer document appears in card 3.
* **Say:** "The orders-service only did an INSERT in PostgreSQL. Debezium read it from the database
  log and published an event; the projection-service turned it into this document."

**A3. Place orders.**
* **Do:** select the new customer and click **Place order** twice.
* **You see:** the MongoDB document now lists both orders and the updated totals.
* **Say:** "This view joins customers and orders, ready for reading. The source database never gets
  these read queries."

**A4. Resilience (optional).**
* **Do:** `oc scale deploy/projection-service -n ai-demo --replicas=0` (or Developer Hub > Create >
  "Scale a demo service"). Place two more orders: card 3 does not change. Scale back to 1.
* **You see:** after a few seconds the missing orders appear.
* **Say:** "Kafka kept the events. The consumer continues where it stopped: nothing is lost."

---

## Part B: the plumbing in the OpenShift console (2 minutes)

* **Do:** **Workloads** > **Topology**, project **kafka**.
* **You see:** the Kafka cluster `platform`, Kafka Connect `debezium` and `inventory-db`.
* **Do:** **Installed Operators** (under Ecosystem or Operators, depending on the console version)
  > **Streams for Apache Kafka** > tab **Kafka Connector** > `inventory-postgres`.
* **You see:** Ready, and its configuration.
* **Say:** "Kafka, Connect and the connector are Kubernetes resources managed by an operator, just
  like the applications."

---

## Part B2: show it on Kafka (4 minutes)

Each captured table has its own topic, named `<prefix>.<schema>.<table>` with Debezium's prefix
`inventory`: table `inventory.customers` becomes topic `inventory.inventory.customers`, table
`inventory.orders` becomes `inventory.inventory.orders`. The projection-service reads both with
consumer group `projection-service`.

**K1. The topics.**
* **Do:** in a terminal, define a small helper once:
  ```bash
  kafka() { local tool=$1; shift; oc exec -n kafka platform-dual-role-0 -c kafka -- /opt/kafka/bin/"$tool" --bootstrap-server localhost:9092 "$@"; }
  ```
  (bash and zsh; it runs the Kafka tools inside the Kafka pod)
  ```bash
  kafka kafka-topics.sh --list | grep -v '^__'
  ```
* **You see:** `inventory.inventory.customers`, `inventory.inventory.orders` (and the coffee shop's
  `inventory.coffee.*`, demo 7). Debezium created them, one per captured table.

**K2. The events.**
* **Do:**
  ```bash
  kafka kafka-console-consumer.sh --topic inventory.inventory.customers --from-beginning --timeout-ms 5000 \
    | jq -c 'select(. != null) | (.payload // .) | {op, table: .source.table, before, after}'
  ```
* **You see:** one line per change, with `op` (`r` for the rows of the initial snapshot, `c`
  created, `u` updated, `d` deleted) and the complete row before and after.

**K3. Watch it live.**
* **Do:** run the consumer without `--from-beginning` and `--timeout-ms` (Ctrl+C to stop):
  ```bash
  kafka kafka-console-consumer.sh --topic inventory.inventory.orders \
    | jq -c 'select(. != null) | (.payload // .) | {op, after}'
  ```
  In the demo UI, tab **CDC**: **Place order**.
* **You see:** the event in the terminal within a second, and the MongoDB card updated two
  seconds later.

**K4. Consumer lag.**
* **Do:**
  ```bash
  kafka kafka-consumer-groups.sh --describe --group projection-service
  ```
* **You see:** `CURRENT-OFFSET`, `LOG-END-OFFSET` and `LAG` per topic. Combine with A4: with the
  projection-service scaled to 0, `LAG` grows with every order; after scaling back it returns to `0`.

---

## Part C: the code and configuration in IntelliJ (5 minutes)

**C1. The application only writes to its database.**
* **Do:** open `OrdersResource.java` (app/orders-service).
* **Point at:** the `@POST` methods with `@Transactional` and a plain `persist()`.
* **Say:** "No Kafka, no event code, no dual write. Just JPA."

**C2. The database allows reading its log.**
* **Do:** open `stack/kafka/inventory-db.yaml`.
* **Point at:** `wal_level = logical` and `max_replication_slots`.

**C3. The connector: which tables become events.**
* **Do:** open `stack/kafka/connector.yaml`.
* **Point at:** `plugin.name: pgoutput`, `topic.prefix: inventory` and `table.include.list`.
* **Say:** "Declarative: this file decides which tables are captured. The topics are named
  `<prefix>.<schema>.<table>`."

**C4. The consumer builds the view.**
* **Do:** open `CdcConsumer.java` (app/projection-service), then `ChangeEvent.java`, then
  `CustomerViewRepository.java`.
* **Point at:** `@Incoming("customers")` / `@Incoming("orders")`; the Debezium envelope `op`,
  `before`, `after`; the MongoDB `upsert(true)` in `applyCustomer` / `applyOrder`.
* **Say:** "Every event says what changed, before and after. The projection applies it idempotently,
  so replays and out-of-order events are harmless."

---

## Part D: prove it from the terminal (optional)

```bash
./deploy.sh app cdc
```
Expected: `OK customer <id>`, `OK order demo-...`, `OK projected after ~2 s` and the MongoDB document.

```bash
./deploy.sh cdc-demo
```
Expected: `OK inserted order 'demo-...'` and `OK Debezium captured it:` with `{"op":"c","after":{...}}`.
This insert goes straight into PostgreSQL: no application involved.

Look at each stage directly:
```bash
oc exec -n kafka deploy/inventory-db -- psql -d inventory -c 'select * from inventory.orders order by id desc limit 3'
oc exec -n kafka platform-dual-role-0 -c kafka -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
oc exec -n ai-demo deploy/mongodb -c mongodb -- mongosh --quiet projections --eval 'db.customer_views.find().limit(2)'
```

## If something goes wrong

* **Nothing reaches MongoDB:** `oc get kafkaconnector inventory-postgres -n kafka` must be Ready; then
  `oc logs deploy/projection-service -n ai-demo -c app`.
* **Kafka Connect not Ready:** its image build pulls the Debezium plugin; `oc get build -n kafka`.
