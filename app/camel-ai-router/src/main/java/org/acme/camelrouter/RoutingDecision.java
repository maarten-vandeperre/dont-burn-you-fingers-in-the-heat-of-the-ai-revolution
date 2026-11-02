package org.acme.camelrouter;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.inject.Named;
import org.apache.camel.Body;
import org.apache.camel.Exchange;
import org.apache.camel.Header;

import java.util.List;
import java.util.Locale;

/**
 * Decides, for every incoming request, which backend actually serves it. This is where the
 * routing rules the demo asks for live, in plain Java (easier to read and test than nesting them
 * all in the route DSL); {@link ChatRoutes} only acts on the {@code provider} exchange property
 * this sets.
 *
 * <h2>How the target is chosen</h2>
 * <ol>
 *   <li><b>Steering.</b> The caller may pick the backend explicitly, with the query parameter
 *       {@code ?provider=...} or the body field {@code "provider": "..."} (query param wins if
 *       both are present): one of {@code local}, {@code openai}, {@code anthropic}, {@code vllm}.
 *       The {@code provider} field is stripped from the body before it is forwarded: it is not
 *       part of the OpenAI wire format and some providers reject unknown fields.</li>
 *   <li><b>Default policy ({@code auto}, i.e. no steering).</b> OpenAI if configured; otherwise
 *       the local model if configured; otherwise the request is rejected with a clear error.
 *       Anthropic and vLLM are only used when explicitly steered to.</li>
 *   <li><b>Forced-local override.</b> If the chosen backend is an online one that has just
 *       tripped {@link ProviderHealthTracker} (too many failures in the configured window) and a
 *       local model is configured, the request goes to the local model directly, without even
 *       attempting the online call. See {@link ProviderHealthTracker}.</li>
 * </ol>
 * The per-request, reactive fallback (an online call fails right now -> retry on local) is handled
 * by the {@code circuitBreaker().onFallback()} EIP in {@link ChatRoutes}, not here.
 */
@ApplicationScoped
@Named("routingDecision")
public class RoutingDecision {

    @Inject
    ObjectMapper mapper;

    @Inject
    ProviderRegistry registry;

    @Inject
    ProviderHealthTracker healthTracker;

    public ObjectNode resolve(@Body String json, @Header(Exchange.HTTP_QUERY) String query, Exchange exchange)
            throws Exception {
        ObjectNode request = (ObjectNode) mapper.readTree(json);

        String steering = queryParam(query, "provider");
        if (steering == null) {
            steering = exchange.getIn().getHeader("provider", String.class); // in case it was mapped as a header too
        }
        if (steering == null && request.hasNonNull("provider")) {
            steering = request.path("provider").asText(null);
        }
        request.remove("provider"); // not OpenAI wire format; never forwarded downstream

        // Whether the CALLER asked for a specific model, as opposed to a gateway filling in its
        // own configured default. Exposed as an exchange property (not re-derived from the body)
        // because on fallback the same body flows to a different gateway: without this, the
        // first gateway's default (e.g. OpenAI's "gpt-4o-mini") would look like a caller choice
        // and leak into the local model's request, which almost certainly does not serve it.
        boolean modelProvided = request.hasNonNull("model") && !request.path("model").asText().isBlank();
        exchange.setProperty("modelProvided", modelProvided);

        String requestedProvider;
        String target;
        if (steering != null && !steering.isBlank() && !"auto".equalsIgnoreCase(steering)) {
            target = steering.trim().toLowerCase(Locale.ROOT);
            if (!registry.isKnown(target)) {
                throw new IllegalArgumentException(
                        "unknown provider '" + target + "': use one of " + ProviderRegistry.ALL_PROVIDERS);
            }
            if (!registry.isConfigured(target)) {
                throw new IllegalStateException("provider '" + target + "' is not configured (see README.md)");
            }
            requestedProvider = target;
        } else {
            requestedProvider = "auto";
            if (registry.isConfigured(ProviderRegistry.OPENAI)) {
                target = ProviderRegistry.OPENAI;
            } else if (registry.isConfigured(ProviderRegistry.LOCAL)) {
                target = ProviderRegistry.LOCAL;
            } else {
                throw new IllegalStateException(
                        "no provider is configured: set OPENAI_API_KEY or LOCAL_BASE_URL (see README.md)");
            }
        }

        boolean forcedLocal = false;
        if (registry.isOnline(target) && healthTracker.isForcedLocal(target) && registry.isConfigured(ProviderRegistry.LOCAL)) {
            exchange.setProperty("originalProvider", target);
            target = ProviderRegistry.LOCAL;
            forcedLocal = true;
        }

        exchange.setProperty("provider", target);
        exchange.setProperty("requestedProvider", requestedProvider);
        exchange.setProperty("forcedLocal", forcedLocal);
        exchange.setProperty("startNanos", System.nanoTime());
        return request;
    }

    /** Minimal query string lookup; avoids depending on how the HTTP engine maps params to headers. */
    static String queryParam(String query, String name) {
        if (query == null || query.isBlank()) {
            return null;
        }
        for (String pair : query.split("&")) {
            int eq = pair.indexOf('=');
            String key = eq >= 0 ? pair.substring(0, eq) : pair;
            if (key.equals(name)) {
                String value = eq >= 0 ? pair.substring(eq + 1) : "";
                return java.net.URLDecoder.decode(value, java.nio.charset.StandardCharsets.UTF_8);
            }
        }
        return null;
    }

    public String listModels() throws Exception {
        List<String> configured = registry.configuredProviders();
        ObjectNode root = mapper.createObjectNode().put("object", "list");
        var data = root.putArray("data");
        for (String provider : ProviderRegistry.ALL_PROVIDERS) {
            data.addObject().put("id", provider).put("object", "model").put("owned_by", "camel-ai-router")
                    .put("configured", configured.contains(provider));
        }
        return mapper.writeValueAsString(root);
    }
}
