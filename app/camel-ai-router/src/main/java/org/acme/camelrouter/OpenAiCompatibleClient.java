package org.acme.camelrouter;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.HeaderParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

/**
 * The shape every "OpenAI-compatible" backend shares: OpenAI itself, any local server (Ollama,
 * llama.cpp, vLLM, Podman AI Lab, ...) and vLLM served through OpenShift AI Models-as-a-Service.
 * One interface, reused (not re-declared) by {@link OpenAiClient}, {@link LocalClient} and
 * {@link VllmClient}, each registered against its own base URL via {@code @RegisterRestClient}.
 */
public interface OpenAiCompatibleClient {

    @POST
    @Path("/v1/chat/completions")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    JsonNode chat(@HeaderParam("Authorization") String authorization, JsonNode request);
}
