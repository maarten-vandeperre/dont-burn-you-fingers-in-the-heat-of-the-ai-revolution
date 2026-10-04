package org.acme.frontend;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

/** x-variant is forwarded so the mesh can route A/B traffic (header based VirtualService match). */
@RegisterRestClient(configKey = "rag")
@Path("/api/rag")
public interface RagClient {

    @POST
    @Path("/ask")
    JsonNode ask(@HeaderParam("x-variant") String variant, JsonNode request);

    @GET
    @Path("/version")
    JsonNode version(@HeaderParam("x-variant") String variant);
}
