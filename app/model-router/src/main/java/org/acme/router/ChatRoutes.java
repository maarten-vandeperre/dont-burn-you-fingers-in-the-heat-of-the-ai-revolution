package org.acme.router;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.apache.camel.Exchange;
import org.apache.camel.LoggingLevel;
import org.apache.camel.builder.RouteBuilder;

import java.util.Map;

/**
 * The model abstraction. Callers (rag-service via LangChain4j) only know one OpenAI-compatible
 * endpoint and a model alias; this route decides where the request really goes:
 *
 * <pre>
 *   POST /v1/chat/completions {"model": "gemma" | "qwen" | "openai" | "auto", ...}
 *     gemma / qwen  -> Models-as-a-Service gateway (local vLLM, API key, token quota)
 *     openai        -> api.openai.com
 *     auto          -> qwen behind a circuit breaker, fallback to OpenAI
 * </pre>
 *
 * Every hop is traced (camel-opentelemetry + REST clients) and counted (Micrometer).
 */
@ApplicationScoped
public class ChatRoutes extends RouteBuilder {

    @Inject
    ObjectMapper mapper;

    @Override
    public void configure() {
        onException(Exception.class)
                .handled(true)
                .log(LoggingLevel.ERROR, "model call failed for alias ${exchangeProperty.alias}: ${exception.message}")
                .bean("usageRecorder", "failure")
                .setHeader(Exchange.HTTP_RESPONSE_CODE, constant(502))
                .setHeader(Exchange.CONTENT_TYPE, constant("application/json"))
                .process(e -> {
                    Exception cause = e.getProperty(Exchange.EXCEPTION_CAUGHT, Exception.class);
                    e.getMessage().setBody(mapper.writeValueAsString(Map.of("error", Map.of(
                            "type", "model_router_error",
                            "message", cause == null ? "unknown error" : String.valueOf(cause.getMessage())))));
                });

        from("platform-http:/v1/chat/completions?httpMethodRestrict=POST")
                .routeId("chat-completions")
                .convertBodyTo(String.class)
                .bean("modelAliases", "resolve")
                .log("chat completion for alias '${exchangeProperty.alias}'")
                .choice()
                    .when(exchangeProperty("alias").isEqualTo("openai")).to("direct:openai")
                    .when(exchangeProperty("alias").isEqualTo("auto")).to("direct:auto")
                    .otherwise().to("direct:maas")
                .end()
                .bean("usageRecorder", "success")
                .setHeader(Exchange.CONTENT_TYPE, constant("application/json"))
                .setHeader("x-model-backend", exchangeProperty("backend"));

        // auto: prefer the local model, fall back to OpenAI when it is slow, failing or the circuit is open
        from("direct:auto")
                .routeId("auto-with-fallback")
                .setProperty("alias", constant("qwen"))
                .circuitBreaker()
                    .faultToleranceConfiguration()
                        .timeoutEnabled(true).timeoutDuration(90_000)
                        .requestVolumeThreshold(4).failureRatio(50).delay(30_000)
                    .end()
                    .to("direct:maas")
                .onFallback()
                    .log(LoggingLevel.WARN, "local model unavailable, falling back to OpenAI")
                    .setProperty("alias", constant("openai"))
                    .setProperty("fallback", constant(true))
                    .to("direct:openai")
                .end();

        from("direct:maas").routeId("maas").bean("maasGateway", "chat");
        from("direct:openai").routeId("openai").bean("openAiGateway", "chat");

        // the aliases this router offers, in OpenAI /v1/models format
        from("platform-http:/v1/models?httpMethodRestrict=GET")
                .routeId("models")
                .bean("modelAliases", "list")
                .setHeader(Exchange.CONTENT_TYPE, constant("application/json"));
    }
}
