package org.acme.projection;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.model.Filters;
import com.mongodb.client.model.Sorts;
import io.micrometer.core.instrument.MeterRegistry;
import io.opentelemetry.instrumentation.annotations.WithSpan;
import io.smallrye.reactive.messaging.annotations.Blocking;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.bson.Document;
import org.bson.conversions.Bson;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.reactive.messaging.Incoming;
import org.jboss.logging.Logger;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Audit trail of the coffee shop: every change of coffee.orders and coffee.order_lines in
 * PostgreSQL becomes one immutable document in MongoDB (collection coffee_audit), including the
 * row before and after the change and a readable summary. The coffee-shop UI reads its audit tab
 * from here, never from PostgreSQL.
 */
@ApplicationScoped
public class CoffeeAuditConsumer {

    private static final Logger LOG = Logger.getLogger(CoffeeAuditConsumer.class);

    @Inject ObjectMapper mapper;
    @Inject MongoClient mongo;
    @Inject MeterRegistry registry;

    @ConfigProperty(name = "projection.database", defaultValue = "projections")
    String database;

    @Incoming("coffee-orders")
    @Blocking
    public void onOrder(ConsumerRecord<String, String> record) throws Exception {
        store(record);
    }

    @Incoming("coffee-lines")
    @Blocking
    public void onLine(ConsumerRecord<String, String> record) throws Exception {
        store(record);
    }

    @WithSpan("projection.coffee-audit")
    void store(ConsumerRecord<String, String> record) throws Exception {
        if (record.value() == null) {
            return; // tombstone after a delete
        }
        ChangeEvent e = ChangeEvent.parse(mapper, record.value());
        JsonNode row = e.after() != null ? e.after() : e.before();
        long orderId = "orders".equals(e.table()) ? row.path("id").asLong() : row.path("order_id").asLong();
        long at = e.sourceTsMs() == 0 ? System.currentTimeMillis() : e.sourceTsMs();
        Document doc = new Document("table", e.table())
                .append("op", e.op())
                .append("operation", e.operation())
                .append("orderId", orderId)
                .append("summary", summary(e))
                .append("at", Instant.ofEpochMilli(at).toString())
                .append("lagMs", Math.max(0, System.currentTimeMillis() - at))
                .append("kafka", new Document("topic", record.topic()).append("partition", record.partition())
                        .append("offset", record.offset()))
                .append("before", e.before() == null ? null : Document.parse(e.before().toString()))
                .append("after", e.after() == null ? null : Document.parse(e.after().toString()));
        collection().insertOne(doc);
        registry.counter("cdc.events", "table", "coffee." + e.table(), "op", e.operation()).increment();
        LOG.infof("audit coffee.%s %s order %d", e.table(), e.operation(), orderId);
    }

    public List<Document> latest(int limit, Long orderId) {
        Bson filter = orderId == null ? new Document() : Filters.eq("orderId", orderId);
        List<Document> result = new ArrayList<>();
        collection().find(filter).sort(Sorts.descending("at", "_id")).limit(Math.max(1, Math.min(limit, 500)))
                .projection(new Document("_id", 0)).into(result);
        return result;
    }

    private static String summary(ChangeEvent e) {
        if ("orders".equals(e.table())) {
            JsonNode a = e.after();
            JsonNode b = e.before();
            return switch (e.op()) {
                case "c", "r" -> "order %d placed: %d cups, %s, menu %s, model %s".formatted(a.path("id").asLong(),
                        a.path("cups").asInt(), euro(a.path("total_cents").asInt()), a.path("menu_version").asText("?"),
                        a.path("model_alias").asText("?"));
                case "u" -> b != null && !b.path("status").asText().equals(a.path("status").asText())
                        ? "order %d: %s -> %s".formatted(a.path("id").asLong(), b.path("status").asText(), a.path("status").asText())
                        : "order %d updated (%s)".formatted(a.path("id").asLong(), a.path("status").asText());
                case "d" -> "order %d cancelled (was %s, %s)".formatted(b.path("id").asLong(), b.path("status").asText("?"),
                        euro(b.path("total_cents").asInt()));
                default -> "order event " + e.op();
            };
        }
        JsonNode l = e.after() != null ? e.after() : e.before();
        String drink = "%d x %s %s %s%s".formatted(l.path("quantity").asInt(), l.path("size").asText(""),
                l.path("milk").asText("").equals("none") ? "" : l.path("milk").asText(""), l.path("drink").asText(""),
                l.path("decaf").asBoolean() ? " (decaf)" : "").replaceAll("\\s+", " ");
        return switch (e.op()) {
            case "c", "r" -> "line added to order %d: %s, %s".formatted(l.path("order_id").asLong(), drink, euro(l.path("total_cents").asInt()));
            case "d" -> "line removed from order %d: %s".formatted(l.path("order_id").asLong(), drink);
            default -> "line of order %d changed: %s".formatted(l.path("order_id").asLong(), drink);
        };
    }

    private static String euro(int cents) {
        return String.format(Locale.ROOT, "EUR %d.%02d", cents / 100, cents % 100);
    }

    private MongoCollection<Document> collection() {
        return mongo.getDatabase(database).getCollection("coffee_audit");
    }
}
