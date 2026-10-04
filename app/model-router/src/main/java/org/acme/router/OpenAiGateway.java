package org.acme.router;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.inject.Named;
import org.apache.camel.Body;
import org.apache.camel.Exchange;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.rest.client.inject.RestClient;

import java.util.Optional;

/** Calls OpenAI; only used for alias "openai" and as fallback of alias "auto". */
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

    public JsonNode chat(@Body ObjectNode request, Exchange exchange) {
        String key = apiKey.filter(k -> !k.isBlank())
                .orElseThrow(() -> new IllegalStateException("OPENAI_API_KEY is not configured"));
        request.put("model", model);
        request.remove("chat_template_kwargs");
        exchange.setProperty("backend", "openai/" + model);
        return client.chat("Bearer " + key, request);
    }
}
