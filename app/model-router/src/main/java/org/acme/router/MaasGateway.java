package org.acme.router;

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

/** Calls a model published through OpenShift AI Models-as-a-Service (local vLLM). */
@ApplicationScoped
@Named("maasGateway")
public class MaasGateway {

    @Inject
    @RestClient
    MaasClient client;

    @ConfigProperty(name = "router.maas.api-key")
    Optional<String> apiKey;

    @ConfigProperty(name = "router.maas.namespace", defaultValue = "maas-models")
    String namespace;

    @ConfigProperty(name = "router.maas.models.gemma", defaultValue = "gemma-3-270m-it")
    String gemmaModel;

    @ConfigProperty(name = "router.maas.models.qwen", defaultValue = "qwen3-0-6b")
    String qwenModel;

    public JsonNode chat(@Body ObjectNode request, @ExchangeProperty("alias") String alias, Exchange exchange) {
        String key = apiKey.filter(k -> !k.isBlank())
                .orElseThrow(() -> new IllegalStateException("MAAS_API_KEY is not configured"));
        String model = "gemma".equals(alias) ? gemmaModel : qwenModel;
        request.put("model", model);
        if (model.startsWith("qwen3")) {
            // Qwen3 "thinks" out loud by default; RAG answers should be direct
            request.putObject("chat_template_kwargs").put("enable_thinking", false);
        }
        exchange.setProperty("backend", "maas/" + model);
        return client.chat(namespace, model, "Bearer " + key, request);
    }
}
