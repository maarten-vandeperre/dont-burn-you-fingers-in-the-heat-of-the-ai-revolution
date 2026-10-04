package org.acme.projection;

import com.fasterxml.jackson.databind.JsonNode;
import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.model.Filters;
import com.mongodb.client.model.PushOptions;
import com.mongodb.client.model.Sorts;
import com.mongodb.client.model.UpdateOptions;
import com.mongodb.client.model.Updates;
import io.opentelemetry.instrumentation.annotations.WithSpan;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.bson.Document;
import org.bson.conversions.Bson;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

/**
 * The read model: one document per customer, shaped for the UI.
 *
 * <pre>
 * { _id: 1, fullName: "Ada Lovelace", email: "...", firstName, lastName,
 *   orders: [ { orderId, product, quantity, createdAt } ],
 *   totals: { orders: 2, items: 5 },
 *   lastChange: { table, operation, at },
 *   history: [ last 10 changes ] }
 * </pre>
 */
@ApplicationScoped
public class CustomerViewRepository {

    @Inject
    MongoClient mongo;

    @ConfigProperty(name = "projection.database", defaultValue = "projections")
    String database;

    @WithSpan("projection.customer")
    public void applyCustomer(ChangeEvent e) {
        if ("d".equals(e.op())) {
            int id = e.before() == null ? -1 : e.before().path("id").asInt(-1);
            collection().deleteOne(Filters.eq("_id", id));
            return;
        }
        JsonNode row = e.after();
        int id = row.path("id").asInt();
        String first = row.path("first_name").asText("");
        String last = row.path("last_name").asText("");
        collection().updateOne(Filters.eq("_id", id), Updates.combine(
                Updates.set("firstName", first),
                Updates.set("lastName", last),
                Updates.set("fullName", (first + " " + last).strip()),
                Updates.set("email", row.path("email").asText("")),
                Updates.setOnInsert("orders", new ArrayList<Document>()),
                lastChange(e),
                history(e, "customer " + e.operation())
        ), new UpdateOptions().upsert(true));
        recomputeTotals(id);
    }

    @WithSpan("projection.order")
    public void applyOrder(ChangeEvent e) {
        int orderId = (e.after() != null ? e.after() : e.before()).path("id").asInt();
        // remove the previous version of the order wherever it is (also handles customer changes)
        List<Integer> affected = new ArrayList<>();
        collection().find(Filters.eq("orders.orderId", orderId)).forEach(d -> affected.add(d.getInteger("_id")));
        collection().updateMany(Filters.eq("orders.orderId", orderId),
                Updates.pull("orders", new Document("orderId", orderId)));

        if (!"d".equals(e.op())) {
            JsonNode row = e.after();
            int customerId = row.path("customer_id").asInt();
            Document order = new Document("orderId", orderId)
                    .append("product", row.path("product").asText(""))
                    .append("quantity", row.path("quantity").asInt(1))
                    .append("createdAt", row.path("created_at").asText(""));
            // upsert: the order event may arrive before the customer event (different topics)
            collection().updateOne(Filters.eq("_id", customerId), Updates.combine(
                    Updates.push("orders", order),
                    lastChange(e),
                    history(e, "order " + orderId + " " + e.operation() + ": " + order.getString("product"))
            ), new UpdateOptions().upsert(true));
            affected.add(customerId);
        } else {
            affected.forEach(id -> collection().updateOne(Filters.eq("_id", id),
                    Updates.combine(lastChange(e), history(e, "order " + orderId + " deleted"))));
        }
        affected.stream().distinct().forEach(this::recomputeTotals);
    }

    public List<Document> all() {
        List<Document> result = new ArrayList<>();
        collection().find().sort(Sorts.ascending("_id")).into(result);
        return result;
    }

    private void recomputeTotals(int customerId) {
        Document doc = collection().find(Filters.eq("_id", customerId)).first();
        if (doc == null) {
            return;
        }
        List<Document> orders = doc.getList("orders", Document.class, List.of());
        int items = orders.stream().mapToInt(o -> o.getInteger("quantity", 0)).sum();
        collection().updateOne(Filters.eq("_id", customerId),
                Updates.set("totals", new Document("orders", orders.size()).append("items", items)));
    }

    private static Bson lastChange(ChangeEvent e) {
        return Updates.set("lastChange", new Document("table", e.table())
                .append("operation", e.operation())
                .append("at", Instant.ofEpochMilli(e.sourceTsMs() == 0 ? System.currentTimeMillis() : e.sourceTsMs()).toString()));
    }

    private static Bson history(ChangeEvent e, String what) {
        Document entry = new Document("what", what)
                .append("at", Instant.ofEpochMilli(e.sourceTsMs() == 0 ? System.currentTimeMillis() : e.sourceTsMs()).toString());
        return Updates.pushEach("history", List.of(entry), new PushOptions().slice(-10));
    }

    private MongoCollection<Document> collection() {
        return mongo.getDatabase(database).getCollection("customer_views");
    }
}
