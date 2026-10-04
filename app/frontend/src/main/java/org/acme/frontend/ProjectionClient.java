package org.acme.frontend;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@RegisterRestClient(configKey = "projection")
@Path("/api")
public interface ProjectionClient {

    @GET
    @Path("/customer-views")
    JsonNode customerViews();
}
