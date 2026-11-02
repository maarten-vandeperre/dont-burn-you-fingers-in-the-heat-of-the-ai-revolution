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

/** Calls OpenAI (or an OpenAI-compatible proxy configured as its base URL). */
@ApplicationScoped
@Named("openAiGateway")
public class OpenAiGateway {

    @Inject
    @RestClient
    OpenAiClient client;

    @ConfigProperty(name = "router.openai.api-key")
    Optional<String> apiKey;

    @ConfigProperty(name = "router.openai.model", defaultValue = "gpt-4o-mini")
    String model;

    public JsonNode chat(@Body ObjectNode request, @ExchangeProperty("modelProvided") boolean modelProvided,
                          Exchange exchange) {
        String key = apiKey.filter(k -> !k.isBlank())
                .orElseThrow(() -> new IllegalStateException("OPENAI_API_KEY is not configured"));
        if (!modelProvided) {
            request.put("model", model); // the caller's choice always wins; this is only a default
        }
        exchange.setProperty("backend", "openai/" + request.path("model").asText(model));
        return client.chat("Bearer " + key, request);
    }
}
