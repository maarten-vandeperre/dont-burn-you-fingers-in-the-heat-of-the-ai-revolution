package org.acme.camelrouter;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Named;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.util.List;
import java.util.Optional;

/**
 * Knows which backends are usable, i.e. "configured". A backend without the required
 * credentials/URL simply does not exist for routing purposes: {@link RoutingDecision} never
 * sends a request there, and reports a clear error instead of letting the REST client fail with
 * a confusing connection error.
 *
 * <ul>
 *   <li><b>openai</b>: configured when {@code OPENAI_API_KEY} is set (the base URL is fixed:
 *       api.openai.com, or override with {@code OPENAI_BASE_URL} for an OpenAI-compatible proxy)</li>
 *   <li><b>anthropic</b>: configured when {@code ANTHROPIC_API_KEY} is set</li>
 *   <li><b>vllm</b>: configured when {@code VLLM_BASE_URL} is set (e.g. a vLLM runtime served
 *       through OpenShift AI Models-as-a-Service); the API key is optional (gateway dependent)</li>
 *   <li><b>local</b>: configured when {@code LOCAL_BASE_URL} is set (any OpenAI-compatible local
 *       server: Ollama, llama.cpp, vLLM, Podman AI Lab, ...); the API key is optional</li>
 * </ul>
 */
@ApplicationScoped
@Named("providerRegistry")
public class ProviderRegistry {

    public static final String OPENAI = "openai";
    public static final String ANTHROPIC = "anthropic";
    public static final String VLLM = "vllm";
    public static final String LOCAL = "local";
    public static final List<String> ONLINE_PROVIDERS = List.of(OPENAI, ANTHROPIC, VLLM);
    public static final List<String> ALL_PROVIDERS = List.of(OPENAI, ANTHROPIC, VLLM, LOCAL);

    @ConfigProperty(name = "router.openai.api-key")
    Optional<String> openAiApiKey;

    @ConfigProperty(name = "router.anthropic.api-key")
    Optional<String> anthropicApiKey;

    @ConfigProperty(name = "router.vllm.base-url")
    Optional<String> vllmBaseUrl;

    @ConfigProperty(name = "router.local.base-url")
    Optional<String> localBaseUrl;

    /** Convenience for the circuit breaker fallback predicate in {@code ChatRoutes}. */
    public boolean isLocalConfigured() {
        return isConfigured(LOCAL);
    }

    public boolean isConfigured(String provider) {
        return switch (provider) {
            case OPENAI -> present(openAiApiKey);
            case ANTHROPIC -> present(anthropicApiKey);
            case VLLM -> present(vllmBaseUrl);
            case LOCAL -> present(localBaseUrl);
            default -> false;
        };
    }

    public boolean isKnown(String provider) {
        return ALL_PROVIDERS.contains(provider);
    }

    public boolean isOnline(String provider) {
        return ONLINE_PROVIDERS.contains(provider);
    }

    public List<String> configuredProviders() {
        return ALL_PROVIDERS.stream().filter(this::isConfigured).toList();
    }

    /**
     * The kind of backend a provider is, for the admin page's call log: {@code local} (your own
     * box), {@code maas} (vLLM via OpenShift AI Models-as-a-Service, or any OpenAI-compatible
     * endpoint reached that way), or {@code foundation-model} (a hosted frontier model API:
     * OpenAI or Anthropic).
     */
    public static String category(String provider) {
        return switch (provider) {
            case LOCAL -> "local";
            case VLLM -> "maas";
            case OPENAI, ANTHROPIC -> "foundation-model";
            default -> "unknown";
        };
    }

    private static boolean present(Optional<String> value) {
        return value.filter(v -> !v.isBlank()).isPresent();
    }
}
