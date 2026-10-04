package org.acme.coffee.guardrails;

import io.quarkus.rest.client.reactive.QuarkusRestClientBuilder;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.net.URI;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * The model providers. Each one has its own guardrails server with the SAME rules
 * (guardrails/config/coffee); only the model behind it differs.
 */
@ApplicationScoped
public class Providers {

    public record Provider(String id, String label, String model, String url, GuardrailsApi guardrails) {}

    private final Map<String, Provider> providers = new LinkedHashMap<>();
    private final String defaultProvider;

    @Inject
    Providers(@ConfigProperty(name = "providers.qwen.url") String qwenUrl,
              @ConfigProperty(name = "providers.qwen.model") String qwenModel,
              @ConfigProperty(name = "providers.openai.url") String openaiUrl,
              @ConfigProperty(name = "providers.openai.model") String openaiModel,
              @ConfigProperty(name = "providers.default", defaultValue = "qwen") String defaultProvider) {
        add("qwen", "Qwen on Podman Desktop AI Lab", qwenModel, qwenUrl);
        add("openai", "OpenAI", openaiModel, openaiUrl);
        this.defaultProvider = providers.containsKey(defaultProvider) ? defaultProvider : "qwen";
    }

    private void add(String id, String label, String model, String url) {
        GuardrailsApi client = QuarkusRestClientBuilder.newBuilder()
                .baseUri(URI.create(url))
                .connectTimeout(5, TimeUnit.SECONDS)
                .readTimeout(120, TimeUnit.SECONDS)
                .build(GuardrailsApi.class);
        providers.put(id, new Provider(id, label, model, url, client));
    }

    public Provider get(String id) {
        Provider provider = providers.get(id == null || id.isBlank() ? defaultProvider : id);
        if (provider == null) {
            throw new WebApplicationException(Response.status(400)
                    .entity(Map.of("error", "Unknown provider '" + id + "': use " + providers.keySet())).build());
        }
        return provider;
    }

    public Iterable<Provider> all() {
        return providers.values();
    }

    public String defaultProvider() {
        return defaultProvider;
    }
}
