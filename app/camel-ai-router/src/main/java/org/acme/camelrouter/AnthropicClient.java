package org.acme.camelrouter;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

/**
 * Anthropic's native Messages API: unlike OpenAI/local/vLLM, this is NOT wire-compatible with
 * {@code /v1/chat/completions} (different auth header, no top-level "model"-less system message,
 * different response shape). {@link AnthropicGateway} translates both directions so that callers
 * of this router only ever see the OpenAI shape.
 */
@RegisterRestClient(configKey = "anthropic")
public interface AnthropicClient {

    @POST
    @Path("/v1/messages")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    JsonNode messages(@HeaderParam("x-api-key") String apiKey,
                       @HeaderParam("anthropic-version") String version,
                       JsonNode request);
}
