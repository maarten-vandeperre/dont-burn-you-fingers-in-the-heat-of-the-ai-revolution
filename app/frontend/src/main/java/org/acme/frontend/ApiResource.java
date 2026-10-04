package org.acme.frontend;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.inject.Inject;
import jakarta.ws.rs.DELETE;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.PUT;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.rest.client.inject.RestClient;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/** Backend for frontend: the browser only talks to this service (through the mesh ingress gateway). */
@Path("/api")
public class ApiResource {

    @Inject @RestClient RagClient rag;
    @Inject @RestClient OrdersClient orders;
    @Inject @RestClient ProjectionClient projection;
    @Inject MeshProbe probe;

    public record TrafficResult(int requests, Map<String, Integer> versions, Map<String, Integer> pods, int errors) {}

    @POST
    @Path("/ask")
    public JsonNode ask(@HeaderParam("x-variant") String variant, JsonNode request) {
        return rag.ask(variant, request);
    }

    /** Fires n cheap version calls at the rag-service and counts which version answered. */
    @GET
    @Path("/traffic")
    public TrafficResult traffic(@QueryParam("n") Integer n, @QueryParam("variant") String variant) {
        int count = n == null ? 50 : Math.max(1, Math.min(n, 500));
        // sequential on purpose: every call is a child span of this request, so one trace shows the split
        Map<String, Integer> versions = new TreeMap<>();
        Map<String, Integer> pods = new TreeMap<>();
        int errors = 0;
        for (int i = 0; i < count; i++) {
            try {
                JsonNode v = rag.version(variant);
                versions.merge(v.path("version").asText("?"), 1, Integer::sum);
                pods.merge(v.path("pod").asText("?"), 1, Integer::sum);
            } catch (RuntimeException e) {
                errors++;
            }
        }
        return new TrafficResult(count, versions, pods, errors);
    }

    @GET @Path("/customers")
    public JsonNode customers() { return orders.customers(); }

    @POST @Path("/customers")
    public JsonNode createCustomer(JsonNode c) { return orders.createCustomer(c); }

    @PUT @Path("/customers/{id}")
    public JsonNode updateCustomer(@PathParam("id") int id, JsonNode c) { return orders.updateCustomer(id, c); }

    @POST @Path("/orders")
    public JsonNode createOrder(JsonNode o) { return orders.createOrder(o); }

    @DELETE @Path("/orders/{id}")
    public Response deleteOrder(@PathParam("id") int id) {
        orders.deleteOrder(id);
        return Response.noContent().build();
    }

    /** The MongoDB read model, built from the Debezium events. */
    @GET @Path("/customer-views")
    public JsonNode customerViews() { return projection.customerViews(); }

    /** "Who can access who": calls every service from this pod and reports what the mesh allowed. */
    @GET @Path("/mesh/probe")
    public List<MeshProbe.Result> meshProbe() { return probe.probeAll(); }

    @GET @Path("/info")
    public Map<String, String> info() {
        Map<String, String> m = new LinkedHashMap<>();
        m.put("service", "frontend");
        m.put("pod", System.getenv().getOrDefault("HOSTNAME", "local"));
        return m;
    }
}
