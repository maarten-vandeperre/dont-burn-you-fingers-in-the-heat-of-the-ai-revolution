package org.acme.projection;

import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.QueryParam;
import org.bson.Document;

import java.util.List;

@Path("/api/coffee-audit")
public class CoffeeAuditResource {

    @Inject
    CoffeeAuditConsumer audit;

    @GET
    public List<Document> list(@QueryParam("limit") Integer limit, @QueryParam("orderId") Long orderId) {
        return audit.latest(limit == null ? 100 : limit, orderId);
    }
}
