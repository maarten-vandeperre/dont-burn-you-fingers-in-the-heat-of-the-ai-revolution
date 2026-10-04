package org.acme.coffee.shop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.micrometer.core.instrument.MeterRegistry;
import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.DELETE;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.jboss.logging.Logger;

import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.Collectors;

/**
 * Order flow: text -> LangChain4j (via model-router) -> quote priced with the live menu
 * (coffee-menu) -> confirmed order in PostgreSQL -> status changes -> Debezium -> MongoDB audit.
 * The server prices everything; prices suggested by the model are ignored.
 */
@Path("/api")
public class CoffeeResource {

    private static final Logger LOG = Logger.getLogger(CoffeeResource.class);
    private static final Set<String> SIZES = Set.of("small", "regular", "large");
    private static final Set<String> MILKS = Set.of("none", "dairy", "oat", "soy");
    private static final List<String> LIFECYCLE = List.of("PLACED", "BREWING", "READY", "COLLECTED");
    private static final int MAX_CUPS = 6;

    public record Input(String text) {}
    public record Confirm(String quoteId) {}
    public record PricedItem(String drink, String size, String milk, int quantity, boolean decaf, int unitCents, int totalCents) {}
    public record Quote(String id, String text, List<PricedItem> items, int totalCents, String menuVersion,
                        String menuSource, Instant expiresAt) {}
    public record Interpretation(String clarification, Quote quote, String model, long elapsedMs, String traceId) {}
    public record LineView(String drink, String size, String milk, int quantity, boolean decaf, int unitCents, int totalCents) {}
    public record OrderView(Long id, String status, int totalCents, int cups, String modelAlias, String menuVersion,
                            String orderText, OffsetDateTime createdAt, OffsetDateTime updatedAt, List<LineView> lines) {}

    @Inject CoffeeAssistant assistant;
    @Inject MenuService menus;
    @Inject ObjectMapper json;
    @Inject MeterRegistry registry;
    @Inject @RestClient AuditClient audit;
    @Inject Tracer tracer;

    @ConfigProperty(name = "quarkus.langchain4j.openai.chat-model.model-name", defaultValue = "qwen")
    String modelAlias;

    @ConfigProperty(name = "coffee.mlflow-url", defaultValue = "")
    String mlflowUrl;

    private final Map<String, Quote> quotes = new ConcurrentHashMap<>();

    @GET
    @Path("/config")
    public Map<String, Object> config() {
        return Map.of("model", modelAlias, "currency", "EUR", "maxCups", MAX_CUPS, "mlflowUrl", mlflowUrl);
    }

    @GET
    @Path("/menu")
    public MenuService.LiveMenu menu() {
        return menus.current();
    }

    /** n raw calls to coffee-menu: version split, errors and latency as the mesh delivers them. */
    @GET
    @Path("/menu/probe")
    public MenuService.ProbeResult probe(@QueryParam("n") Integer n) {
        return menus.probe(n == null ? 50 : Math.max(1, Math.min(n, 300)));
    }

    /**
     * One MLflow trace per order: a new root span "coffee order" (linked to the HTTP request trace)
     * with the order as input and the quote or question as output. Everything below it, the
     * LangChain4j call, the model-router request and the menu lookups, is marked for MLflow by
     * MlflowSpanMarker through the baggage entry.
     */
    @POST
    @Path("/interpret")
    public Interpretation interpret(Input input) {
        if (input == null || input.text() == null || input.text().isBlank() || input.text().length() > 500) {
            throw problem(400, "Please enter an order between 1 and 500 characters.");
        }
        Span root = tracer.spanBuilder("coffee order")
                .setNoParent()
                .addLink(Span.current().getSpanContext())
                .setSpanKind(SpanKind.INTERNAL)
                .setAttribute(MlflowSpanMarker.ATTRIBUTE, "coffee-shop")
                .setAttribute("mlflow.spanType", "CHAIN")
                .setAttribute("mlflow.spanInputs", jsonString(Map.of("order", input.text())))
                .setAttribute("gen_ai.request.model", modelAlias)
                .startSpan();
        Context ai = Baggage.builder().put(MlflowSpanMarker.BAGGAGE_KEY, "coffee-shop").build()
                .storeInContext(Context.root().with(root));
        try (Scope ignored = ai.makeCurrent()) {
            Interpretation result = interpretOrder(input, root.getSpanContext().getTraceId());
            root.setAttribute("mlflow.spanOutputs", jsonString(result.quote() != null
                    ? Map.of("items", result.quote().items(), "totalCents", result.quote().totalCents(),
                             "menuVersion", result.quote().menuVersion(), "menuSource", result.quote().menuSource())
                    : Map.of("clarification", result.clarification())));
            return result;
        } catch (RuntimeException e) {
            root.recordException(e);
            root.setStatus(StatusCode.ERROR, e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage());
            root.setAttribute("mlflow.spanOutputs", jsonString(Map.of("error", String.valueOf(e.getMessage()))));
            throw e;
        } finally {
            root.end();
        }
    }

    private Interpretation interpretOrder(Input input, String traceId) {
        MenuService.LiveMenu menu = menus.current();
        Map<String, Integer> prices = menu.items().stream()
                .collect(Collectors.toMap(MenuClient.MenuItem::drink, MenuClient.MenuItem::priceCents));
        long start = System.nanoTime();
        String content;
        try {
            content = assistant.interpret(String.join(", ", prices.keySet()), input.text());
        } catch (RuntimeException e) {
            LOG.warnf("model call failed: %s", e.getMessage());
            throw problem(502, "The model service did not answer. Try again, or another model alias.");
        }
        long ms = (System.nanoTime() - start) / 1_000_000;
        JsonNode result = parse(content);
        String clarification = result.path("clarification").asText("");
        if (!clarification.isBlank()) {
            return new Interpretation(clarification.substring(0, Math.min(clarification.length(), 240)), null, modelAlias, ms, traceId);
        }
        List<PricedItem> items = price(result.path("items"), prices);
        int total = items.stream().mapToInt(PricedItem::totalCents).sum();
        Quote quote = new Quote(UUID.randomUUID().toString(), input.text(), items, total, menu.version(), menu.source(),
                Instant.now().plusSeconds(600));
        quotes.values().removeIf(q -> q.expiresAt().isBefore(Instant.now()));
        quotes.put(quote.id(), quote);
        registry.counter("coffee.interpretations", "model", modelAlias).increment();
        return new Interpretation("", quote, modelAlias, ms, traceId);
    }

    @POST
    @Path("/orders")
    @Transactional
    public OrderView confirm(Confirm input) {
        Quote quote = input == null ? null : quotes.remove(input.quoteId());
        if (quote == null || quote.expiresAt().isBefore(Instant.now())) {
            throw problem(410, "This quote expired. Please interpret the order again.");
        }
        CoffeeOrder order = new CoffeeOrder();
        order.status = LIFECYCLE.getFirst();
        order.totalCents = quote.totalCents();
        order.cups = quote.items().stream().mapToInt(PricedItem::quantity).sum();
        order.modelAlias = modelAlias;
        order.menuVersion = quote.menuVersion();
        order.orderText = quote.text();
        order.updatedAt = OffsetDateTime.now();
        for (PricedItem i : quote.items()) {
            CoffeeOrderLine line = new CoffeeOrderLine();
            line.order = order;
            line.drink = i.drink();
            line.size = i.size();
            line.milk = i.milk();
            line.decaf = i.decaf();
            line.quantity = i.quantity();
            line.unitCents = i.unitCents();
            line.totalCents = i.totalCents();
            order.lines.add(line);
        }
        order.persist();
        registry.counter("coffee.orders", "event", "placed").increment();
        LOG.infof("coffee order %d placed: %d cups, %d cents, menu %s", order.id, order.cups, order.totalCents, order.menuVersion);
        return view(order);
    }

    @GET
    @Path("/orders")
    public List<OrderView> orders() {
        return CoffeeOrder.<CoffeeOrder>find("order by id desc").page(0, 50).list().stream().map(CoffeeResource::view).toList();
    }

    /** PLACED -> BREWING -> READY -> COLLECTED: each step is an update event for the audit trail. */
    @POST
    @Path("/orders/{id}/advance")
    @Transactional
    public OrderView advance(@PathParam("id") Long id) {
        CoffeeOrder order = CoffeeOrder.<CoffeeOrder>findByIdOptional(id).orElseThrow(() -> problem(404, "Unknown order."));
        int next = LIFECYCLE.indexOf(order.status) + 1;
        if (next <= 0 || next >= LIFECYCLE.size()) {
            throw problem(409, "Order " + id + " is already " + order.status + ".");
        }
        order.status = LIFECYCLE.get(next);
        order.updatedAt = OffsetDateTime.now();
        registry.counter("coffee.orders", "event", order.status.toLowerCase(Locale.ROOT)).increment();
        return view(order);
    }

    @DELETE
    @Path("/orders/{id}")
    @Transactional
    public Response cancel(@PathParam("id") Long id) {
        if (!CoffeeOrder.deleteById(id)) {
            throw problem(404, "Unknown order.");
        }
        registry.counter("coffee.orders", "event", "cancelled").increment();
        return Response.noContent().build();
    }

    /** Read model: the change history from MongoDB, never from PostgreSQL. */
    @GET
    @Path("/audit")
    public JsonNode auditTrail(@QueryParam("limit") Integer limit, @QueryParam("orderId") Long orderId) {
        return audit.audit(limit == null ? 100 : limit, orderId);
    }

    private String jsonString(Object value) {
        try {
            return json.writeValueAsString(value);
        } catch (Exception e) {
            return String.valueOf(value);
        }
    }

    private JsonNode parse(String content) {
        String text = content == null ? "" : content.replaceAll("(?s)<think>.*?</think>", "").strip();
        if (text.startsWith("```")) {
            text = text.replaceFirst("^```(?:json)?\\s*", "").replaceFirst("\\s*```$", "");
        }
        try {
            JsonNode node = json.readTree(text);
            if (node == null || !node.isObject()) {
                throw new IllegalArgumentException("not an object");
            }
            return node;
        } catch (Exception e) {
            throw problem(502, "The model returned something that is not an order. Please try again.");
        }
    }

    private static List<PricedItem> price(JsonNode nodes, Map<String, Integer> prices) {
        if (!nodes.isArray() || nodes.isEmpty() || nodes.size() > MAX_CUPS) {
            throw problem(502, "The model must return between one and six drinks. Please try again.");
        }
        Map<String, PricedItem> merged = new LinkedHashMap<>();
        int cups = 0;
        for (JsonNode n : nodes) {
            String drink = n.path("drink").asText("").toLowerCase(Locale.ROOT);
            String size = n.path("size").asText("regular").toLowerCase(Locale.ROOT);
            String milk = n.path("milk").asText("none").toLowerCase(Locale.ROOT);
            int quantity = n.path("quantity").asInt(1);
            boolean decaf = n.path("decaf").asBoolean(false);
            if (!prices.containsKey(drink) || !SIZES.contains(size) || !MILKS.contains(milk) || quantity < 1 || quantity > MAX_CUPS
                    || drink.equals("espresso") && (!size.equals("small") || !milk.equals("none"))) {
                throw problem(422, "\"" + drink + "\" is not something we can make from the current menu.");
            }
            cups += quantity;
            if (cups > MAX_CUPS) {
                throw problem(422, "An order can contain up to six cups in total.");
            }
            int unit = prices.get(drink) + (size.equals("large") ? 70 : 0) + (milk.equals("oat") || milk.equals("soy") ? 40 : 0);
            String key = drink + "|" + size + "|" + milk + "|" + decaf;
            PricedItem previous = merged.get(key);
            int q = quantity + (previous == null ? 0 : previous.quantity());
            merged.put(key, new PricedItem(drink, size, milk, q, decaf, unit, unit * q));
        }
        return new ArrayList<>(merged.values());
    }

    private static OrderView view(CoffeeOrder o) {
        return new OrderView(o.id, o.status, o.totalCents, o.cups, o.modelAlias, o.menuVersion, o.orderText,
                o.createdAt, o.updatedAt, o.lines.stream()
                .map(l -> new LineView(l.drink, l.size, l.milk, l.quantity, l.decaf, l.unitCents, l.totalCents)).toList());
    }

    private static WebApplicationException problem(int status, String message) {
        return new WebApplicationException(Response.status(status).entity(Map.of("error", message)).build());
    }
}
