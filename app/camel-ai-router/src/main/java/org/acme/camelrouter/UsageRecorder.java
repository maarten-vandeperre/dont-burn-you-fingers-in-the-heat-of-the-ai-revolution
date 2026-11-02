package org.acme.camelrouter;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
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
 * Metrics and the OpenAI-shaped error body: {@code ai_router_requests_total} (by provider,
 * outcome), {@code ai_router_tokens_total}, {@code ai_router_fallbacks_total},
 * {@code ai_router_latency_seconds}.
 */
@ApplicationScoped
@Named("usageRecorder")
public class UsageRecorder {

    private static final Logger LOG = Logger.getLogger(UsageRecorder.class);

    @Inject
    MeterRegistry registry;

    @Inject
    ObjectMapper mapper;

    @Inject
    CallLogStore callLog;

    public String success(@Body JsonNode response, Exchange exchange) throws Exception {
        String provider = exchange.getProperty("provider", "unknown", String.class);
        String requested = exchange.getProperty("requestedProvider", "unknown", String.class);
        String backend = exchange.getProperty("backend", provider, String.class);
        boolean forcedLocal = Boolean.TRUE.equals(exchange.getProperty("forcedLocal", Boolean.class));
        boolean fallback = Boolean.TRUE.equals(exchange.getProperty("fallback", Boolean.class));
        JsonNode usage = response.path("usage");
        long prompt = usage.path("prompt_tokens").asLong(0);
        long completion = usage.path("completion_tokens").asLong(0);

        count(provider, "success");
        Counter.builder("ai.router.tokens").tag("provider", provider).tag("type", "prompt")
                .register(registry).increment(prompt);
        Counter.builder("ai.router.tokens").tag("provider", provider).tag("type", "completion")
                .register(registry).increment(completion);
        if (forcedLocal || fallback) {
            Counter.builder("ai.router.fallbacks")
                    .tag("requested", exchange.getProperty("originalProvider", requested, String.class))
                    .tag("reason", forcedLocal ? "forced-local" : "failure")
                    .register(registry).increment();
        }
        Duration took = took(exchange);
        Timer.builder("ai.router.latency").tag("provider", provider).tag("backend", backend)
                .publishPercentileHistogram().register(registry).record(took);
        LOG.infof("provider=%s requested=%s backend=%s forced_local=%b prompt_tokens=%d completion_tokens=%d took_ms=%d",
                provider, requested, backend, forcedLocal, prompt, completion, took.toMillis());
        String responseJson = mapper.writeValueAsString(response);
        callLog.record(ProviderRegistry.category(provider), provider, requested, backend, forcedLocal, fallback,
                true, 200, took.toMillis(), rawRequestBody(exchange), responseJson);
        return responseJson;
    }

    public void failure(Exchange exchange) {
        String provider = exchange.getProperty("provider", "unknown", String.class);
        count(provider, "error");
        Throwable cause = exchange.getProperty(Exchange.EXCEPTION_CAUGHT, Throwable.class);
        LOG.errorf(cause, "provider=%s request failed: %s", provider, cause == null ? "unknown error" : cause.getMessage());
    }

    public String errorBody(Exchange exchange) throws Exception {
        Throwable cause = exchange.getProperty(Exchange.EXCEPTION_CAUGHT, Throwable.class);
        String provider = exchange.getProperty("provider", (String) null, String.class);
        ObjectNode error = mapper.createObjectNode();
        ObjectNode body = error.putObject("error");
        body.put("type", cause == null ? "router_error" : cause.getClass().getSimpleName());
        body.put("message", cause == null ? "unknown error" : String.valueOf(cause.getMessage()));
        if (provider != null) {
            body.put("provider", provider);
        }
        String errorJson = mapper.writeValueAsString(error);
        Integer status = exchange.getIn().getHeader(Exchange.HTTP_RESPONSE_CODE, 500, Integer.class);
        String requested = exchange.getProperty("requestedProvider", provider, String.class);
        String backend = exchange.getProperty("backend", provider, String.class);
        boolean forcedLocal = Boolean.TRUE.equals(exchange.getProperty("forcedLocal", Boolean.class));
        boolean fallback = Boolean.TRUE.equals(exchange.getProperty("fallback", Boolean.class));
        callLog.record(provider == null ? "unknown" : ProviderRegistry.category(provider), provider, requested,
                backend, forcedLocal, fallback, false, status, took(exchange).toMillis(), rawRequestBody(exchange),
                errorJson);
        return errorJson;
    }

    private static String rawRequestBody(Exchange exchange) {
        return exchange.getProperty("rawRequestBody", "(request body unavailable)", String.class);
    }

    private void count(String provider, String outcome) {
        Counter.builder("ai.router.requests").tag("provider", provider).tag("outcome", outcome)
                .register(registry).increment();
    }

    private static Duration took(Exchange exchange) {
        Long start = exchange.getProperty("startNanos", Long.class);
        return start == null ? Duration.ZERO : Duration.ofNanos(System.nanoTime() - start);
    }
}
