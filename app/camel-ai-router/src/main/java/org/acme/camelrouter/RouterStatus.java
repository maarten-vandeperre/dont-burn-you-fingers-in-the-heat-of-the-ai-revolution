package org.acme.camelrouter;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.inject.Named;

/**
 * {@code GET /v1/router/status}: which providers are configured, which "auto" would pick right
 * now, and -- for the online ones -- the live state of the {@link ProviderHealthTracker} policy
 * (recent failures, whether it is currently forced to local, and until when). Handy to watch
 * while demoing the circuit breaker: fail the online provider a few times and see it flip.
 */
@ApplicationScoped
@Named("routerStatus")
public class RouterStatus {

    @Inject
    ObjectMapper mapper;

    @Inject
    ProviderRegistry registry;

    @Inject
    ProviderHealthTracker healthTracker;

    public String report() throws Exception {
        ObjectNode root = mapper.createObjectNode();
        String autoTarget = registry.isConfigured(ProviderRegistry.OPENAI) ? ProviderRegistry.OPENAI
                : registry.isConfigured(ProviderRegistry.LOCAL) ? ProviderRegistry.LOCAL
                : null;
        root.put("auto_would_use", autoTarget);

        ObjectNode providers = root.putObject("providers");
        for (String provider : ProviderRegistry.ALL_PROVIDERS) {
            ObjectNode node = providers.putObject(provider);
            boolean configured = registry.isConfigured(provider);
            node.put("configured", configured);
            if (registry.isOnline(provider)) {
                ProviderHealthTracker.Status status = healthTracker.status(provider);
                node.put("recent_failures", status.recentFailures());
                node.put("failure_threshold", status.failureThreshold());
                node.put("window_minutes", status.window().toMinutes());
                node.put("forced_local_minutes", status.openFor().toMinutes());
                node.put("forced_local_now", status.forcedLocal());
                node.put("forced_local_until", status.forcedUntil() == null ? null : status.forcedUntil().toString());
            }
        }
        return mapper.writeValueAsString(root);
    }
}
