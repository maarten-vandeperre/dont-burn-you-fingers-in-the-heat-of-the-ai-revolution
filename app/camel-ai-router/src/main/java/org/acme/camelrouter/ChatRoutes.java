package org.acme.camelrouter;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.apache.camel.Exchange;
import org.apache.camel.LoggingLevel;
import org.apache.camel.builder.RouteBuilder;
import org.eclipse.microprofile.config.Config;

/**
 * The OpenAI-compatible endpoint and the routing/resilience rules around it.
 *
 * <pre>
 *   POST /v1/chat/completions   {"messages": [...], "provider": "openai"|"anthropic"|"vllm"|"local"|"auto"?, ...}
 *   GET  /v1/models             which providers exist and whether each is configured
 *   GET  /v1/router/status      live circuit breaker state per online provider
 * </pre>
 *
 * {@link RoutingDecision#resolve} decides the target provider (steering, default policy, the
 * "forced to local" override) and sets it as the exchange property {@code provider}; this class
 * only wires the Camel EIPs around that decision:
 * <ul>
 *   <li><b>Content-based router</b> ({@code choice()}) to the chosen backend</li>
 *   <li><b>Circuit Breaker</b> ({@code circuitBreaker()}, MicroProfile Fault Tolerance) around
 *       every online provider: a timeout, and -- within a rolling window of
 *       {@code router.breaker.<provider>.failure-threshold} calls -- opens once all of them
 *       failed, staying open for {@code router.breaker.<provider>.open-minutes}</li>
 *   <li><b>Fallback</b> ({@code onFallback()}): any failure of an online provider, immediate or
 *       because the breaker is open, retries on the local model when one is configured; without
 *       one the error propagates</li>
 * </ul>
 * {@link ProviderHealthTracker} adds the time-windowed version of the same policy ("x failures in
 * y minutes") on top, so that the very next request is sent straight to local -- see its Javadoc.
 */
@ApplicationScoped
public class ChatRoutes extends RouteBuilder {

    @Inject
    Config config;

    @Override
    public void configure() {

        // --- the OpenAI-compatible endpoint ------------------------------------------------------
        // The error handlers below are scoped to THIS route only (declared right after from()),
        // not globally: onException() declared at the top of configure() would otherwise be
        // inherited by every from("direct:...") route in this class too -- including the ones
        // wrapped by circuitBreaker() -- which would "handle" the failure right there and the
        // circuit breaker would never see an exception to fall back on. The inner direct: routes
        // deliberately have no error handler of their own, so their exceptions propagate up to
        // whichever circuitBreaker() wraps them (or, for "local", straight here).
        //
        // consumes=application/json (+ the platform-http component's serverRequestValidation,
        // which defaults to true) makes Vert.x reject any request whose Content-Type is not
        // application/json with a clean 415, before Camel ever sees it. Without this, a request
        // sent without that header (e.g. "curl -d '{...}'" without -H, which defaults to
        // application/x-www-form-urlencoded) would be auto-parsed by platform-http as HTML form
        // data: the entire JSON body becomes a single form field name, which both corrupts the
        // message body (an unparsable Map, not the JSON text) and -- worse -- gets copied into a
        // response header literally named after that JSON text, which then crashes Vert.x when
        // writing the HTTP response ("a header name cannot contain some prohibited characters").
        from("platform-http:/v1/chat/completions?httpMethodRestrict=POST&consumes=application/json")
                .routeId("chat-completions")
                .onException(IllegalArgumentException.class) // unknown ?provider=
                    .handled(true)
                    .setHeader(Exchange.HTTP_RESPONSE_CODE, constant(400))
                    .setHeader(Exchange.CONTENT_TYPE, constant("application/json"))
                    .bean("usageRecorder", "failure")
                    .bean("usageRecorder", "errorBody")
                .end()
                .onException(IllegalStateException.class) // steered to / defaulted to a provider that is not configured
                    .handled(true)
                    .setHeader(Exchange.HTTP_RESPONSE_CODE, constant(503))
                    .setHeader(Exchange.CONTENT_TYPE, constant("application/json"))
                    .bean("usageRecorder", "failure")
                    .bean("usageRecorder", "errorBody")
                .end()
                .onException(Exception.class) // the provider call failed and no fallback was possible (or it failed too)
                    .handled(true)
                    .log(LoggingLevel.ERROR, "chat completion failed for provider ${exchangeProperty.provider}: ${exception.message}")
                    .setHeader(Exchange.HTTP_RESPONSE_CODE, constant(502))
                    .setHeader(Exchange.CONTENT_TYPE, constant("application/json"))
                    .bean("usageRecorder", "failure")
                    .bean("usageRecorder", "errorBody")
                .end()
                .convertBodyTo(String.class)
                // Stashed before routingDecision strips the "provider" field and before any
                // gateway can mutate it, so the admin page's call log (CallLogStore, via
                // UsageRecorder) always shows exactly what the caller sent, on both success and
                // failure -- including failures raised from inside resolve() itself.
                .setProperty("rawRequestBody", simple("${body}"))
                .bean("routingDecision", "resolve")
                .log("chat completion: provider=${exchangeProperty.provider} requested=${exchangeProperty.requestedProvider}")
                .choice()
                    .when(exchangeProperty("provider").isEqualTo(ProviderRegistry.LOCAL)).to("direct:local")
                    .when(exchangeProperty("provider").isEqualTo(ProviderRegistry.OPENAI)).to("direct:openai-guarded")
                    .when(exchangeProperty("provider").isEqualTo(ProviderRegistry.ANTHROPIC)).to("direct:anthropic-guarded")
                    .when(exchangeProperty("provider").isEqualTo(ProviderRegistry.VLLM)).to("direct:vllm-guarded")
                .end()
                .bean("usageRecorder", "success")
                .setHeader(Exchange.CONTENT_TYPE, constant("application/json"))
                .setHeader("X-Router-Provider", exchangeProperty("provider"))
                .setHeader("X-Router-Backend", exchangeProperty("backend"));

        // --- one direct route per backend, called by the guarded routes below and directly for local
        from("direct:local").routeId("local").bean("localGateway", "chat");
        from("direct:openai").routeId("openai").bean("openAiGateway", "chat");
        from("direct:anthropic").routeId("anthropic").bean("anthropicGateway", "chat");
        from("direct:vllm").routeId("vllm").bean("vllmGateway", "chat");

        guarded(ProviderRegistry.OPENAI, "direct:openai");
        guarded(ProviderRegistry.ANTHROPIC, "direct:anthropic");
        guarded(ProviderRegistry.VLLM, "direct:vllm");

        // --- introspection -----------------------------------------------------------------------
        from("platform-http:/v1/models?httpMethodRestrict=GET")
                .routeId("models")
                .bean("routingDecision", "listModels")
                .setHeader(Exchange.CONTENT_TYPE, constant("application/json"));

        from("platform-http:/v1/router/status?httpMethodRestrict=GET")
                .routeId("router-status")
                .bean("routerStatus", "report")
                .setHeader(Exchange.CONTENT_TYPE, constant("application/json"));
    }

    /**
     * Builds {@code direct:<provider>-guarded}: Circuit Breaker EIP around {@code targetUri},
     * falling back to the local model on any failure (configured local model required), and
     * feeding {@link ProviderHealthTracker} for the "x failures in y minutes" policy.
     */
    private void guarded(String provider, String targetUri) {
        int failureThreshold = intProperty(provider, "failure-threshold", 5); // x
        int openMinutes = intProperty(provider, "open-minutes", 5);           // z
        int timeoutMs = intProperty(provider, "timeout-ms", 60_000);
        // y (router.breaker.<provider>.window-minutes) is enforced by ProviderHealthTracker, not
        // by MicroProfile Fault Tolerance: its circuit breaker only supports a count-based rolling
        // window (requestVolumeThreshold calls), not a time-based one.

        from("direct:" + provider + "-guarded")
                .routeId(provider + "-guarded")
                .circuitBreaker()
                    .faultToleranceConfiguration()
                        .timeoutEnabled(true).timeoutDuration(timeoutMs)
                        .requestVolumeThreshold(failureThreshold).failureRatio(100).delay(openMinutes * 60_000L)
                    .end()
                    .to(targetUri)
                .onFallback()
                    .log(LoggingLevel.WARN, provider + " call failed, considering local fallback: ${exception.message}")
                    .bean("providerHealthTracker", "recordFailure('" + provider + "')")
                    .choice()
                        .when(method("providerRegistry", "isLocalConfigured"))
                            .setProperty("originalProvider", exchangeProperty("provider"))
                            .setProperty("provider", constant(ProviderRegistry.LOCAL))
                            .setProperty("fallback", constant(true))
                            .log(LoggingLevel.WARN, provider + " failed, falling back to local")
                            .to("direct:local")
                        .otherwise()
                            .process(exchange -> {
                                Throwable cause = exchange.getProperty(Exchange.EXCEPTION_CAUGHT, Throwable.class);
                                String message = cause == null
                                        ? provider + " call failed and no local fallback is configured"
                                        : cause.getMessage();
                                throw new RuntimeException(message, cause);
                            })
                    .end()
                .end();
    }

    private int intProperty(String provider, String key, int fallback) {
        return config.getOptionalValue("router.breaker." + provider + "." + key, Integer.class)
                .or(() -> config.getOptionalValue("router.breaker." + key, Integer.class))
                .orElse(fallback);
    }
}
