package org.acme.router;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.inject.Named;
import org.apache.camel.Body;
import org.apache.camel.Exchange;
import org.jboss.logging.Logger;

import java.time.Duration;

/**
 * Token accounting per alias and backend, the numbers behind the "AI models" dashboard:
 * ai_router_requests_total, ai_router_tokens_total, ai_router_fallbacks_total, ai_router_latency_seconds.
 */
@ApplicationScoped
@Named("usageRecorder")
public class UsageRecorder {

    private static final Logger LOG = Logger.getLogger(UsageRecorder.class);

    @Inject
    MeterRegistry registry;

    @Inject
    ObjectMapper mapper;

    public String success(@Body JsonNode response, Exchange exchange) throws Exception {
        String alias = exchange.getProperty("alias", "unknown", String.class);
        String backend = exchange.getProperty("backend", "unknown", String.class);
        JsonNode usage = response.path("usage");
        long prompt = usage.path("prompt_tokens").asLong(0);
        long completion = usage.path("completion_tokens").asLong(0);

        count(alias, backend, "success");
        Counter.builder("ai.router.tokens").tag("alias", alias).tag("backend", backend).tag("type", "prompt")
                .register(registry).increment(prompt);
        Counter.builder("ai.router.tokens").tag("alias", alias).tag("backend", backend).tag("type", "completion")
                .register(registry).increment(completion);
        if (Boolean.TRUE.equals(exchange.getProperty("fallback", Boolean.class))) {
            Counter.builder("ai.router.fallbacks").tag("requested", exchange.getProperty("requestedAlias", String.class))
                    .register(registry).increment();
        }
        Duration took = took(exchange);
        Timer.builder("ai.router.latency").tag("alias", alias).tag("backend", backend)
                .publishPercentileHistogram().register(registry).record(took);
        LOG.infof("alias=%s backend=%s prompt_tokens=%d completion_tokens=%d took_ms=%d",
                alias, backend, prompt, completion, took.toMillis());
        return mapper.writeValueAsString(response);
    }

    public void failure(Exchange exchange) {
        count(exchange.getProperty("alias", "unknown", String.class),
                exchange.getProperty("backend", "none", String.class), "error");
    }

    private void count(String alias, String backend, String outcome) {
        Counter.builder("ai.router.requests").tag("alias", alias).tag("backend", backend).tag("outcome", outcome)
                .register(registry).increment();
    }

    private static Duration took(Exchange exchange) {
        Long start = exchange.getProperty("startNanos", Long.class);
        return start == null ? Duration.ZERO : Duration.ofNanos(System.nanoTime() - start);
    }
}
