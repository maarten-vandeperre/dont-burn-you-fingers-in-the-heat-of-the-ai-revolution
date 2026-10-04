package org.acme.router;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

/** MaaS path based routing: https://maas.<apps-domain>/<namespace>/<model>/v1/chat/completions */
@RegisterRestClient(configKey = "maas")
@Path("/")
public interface MaasClient {

    @POST
    @Path("{namespace}/{model}/v1/chat/completions")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    JsonNode chat(@PathParam("namespace") String namespace,
                  @PathParam("model") String model,
                  @HeaderParam("Authorization") String authorization,
                  JsonNode request);
}
