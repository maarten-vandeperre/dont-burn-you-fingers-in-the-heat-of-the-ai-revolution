package org.acme.camelrouter;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.inject.Named;
import org.apache.camel.Body;
import org.apache.camel.Exchange;
import org.apache.camel.ExchangeProperty;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.rest.client.inject.RestClient;

import java.util.Optional;

/**
 * Calls the local OpenAI-compatible model (Ollama, llama.cpp, vLLM, Podman Desktop AI Lab, ...).
 * Most local servers need no API key at all; {@code LOCAL_API_KEY} is sent as a Bearer token
 * only when set.
 */
@ApplicationScoped
@Named("localGateway")
public class LocalGateway {

    @Inject
    @RestClient
    LocalClient client;

    @ConfigProperty(name = "router.local.api-key")
    Optional<String> apiKey;

    @ConfigProperty(name = "router.local.model")
    Optional<String> model;

    public JsonNode chat(@Body ObjectNode request, @ExchangeProperty("modelProvided") boolean modelProvided,
                          Exchange exchange) {
        // modelProvided reflects the ORIGINAL caller request, not the body's current state: on a
        // fallback from OpenAI/vLLM, that gateway may already have written its own default model
        // into the (shared) body. Without checking the original intent, that default would leak
        // into the local request even though the caller never asked for it.
        if (!modelProvided && model.isPresent() && !model.get().isBlank()) {
            request.put("model", model.get());
        } else if (!modelProvided) {
            request.remove("model"); // let the local server use whichever model it serves
        }
        String authorization = apiKey.filter(k -> !k.isBlank()).map(k -> "Bearer " + k).orElse(null);
        exchange.setProperty("backend", "local/" + request.path("model").asText("default"));
        return client.chat(authorization, request);
    }
}
