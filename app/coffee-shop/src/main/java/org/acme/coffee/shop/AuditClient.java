package org.acme.coffee.shop;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.QueryParam;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

/** The audit trail in MongoDB, built by the projection-service from the Debezium events. */
@RegisterRestClient(configKey = "projection")
@Path("/api/coffee-audit")
public interface AuditClient {

    @GET
    JsonNode audit(@QueryParam("limit") int limit, @QueryParam("orderId") Long orderId);
}
