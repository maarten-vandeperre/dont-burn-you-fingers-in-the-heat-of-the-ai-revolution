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
 * Calls vLLM served "online" through OpenShift AI Models-as-a-Service (or any other OpenShift
 * route in front of vLLM). Lab clusters often sit behind a self-signed ingress certificate:
 * {@code VLLM_TRUST_ALL=true} skips certificate validation for this client only.
 */
@ApplicationScoped
@Named("vllmGateway")
public class VllmGateway {

    @Inject
    @RestClient
    VllmClient client;

    @ConfigProperty(name = "router.vllm.api-key")
    Optional<String> apiKey;

    @ConfigProperty(name = "router.vllm.model")
    Optional<String> model;

    public JsonNode chat(@Body ObjectNode request, @ExchangeProperty("modelProvided") boolean modelProvided,
                          Exchange exchange) {
        if (!modelProvided && model.isPresent() && !model.get().isBlank()) {
            request.put("model", model.get());
        }
        String authorization = apiKey.filter(k -> !k.isBlank()).map(k -> "Bearer " + k).orElse(null);
        exchange.setProperty("backend", "vllm/" + request.path("model").asText("default"));
        return client.chat(authorization, request);
    }
}
