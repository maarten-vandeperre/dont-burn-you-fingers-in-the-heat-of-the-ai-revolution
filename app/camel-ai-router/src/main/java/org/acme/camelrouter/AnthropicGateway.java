package org.acme.camelrouter;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
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
 * Calls Anthropic. Unlike OpenAI/local/vLLM, Anthropic's native Messages API is not
 * wire-compatible with {@code /v1/chat/completions}: this gateway translates the OpenAI-shaped
 * request into a Messages API request (system message pulled out, {@code max_tokens} required)
 * and translates the Messages API response back into the OpenAI shape, so the router stays
 * OpenAI-compatible end to end regardless of which backend actually answered.
 */
@ApplicationScoped
@Named("anthropicGateway")
public class AnthropicGateway {

    private static final String ANTHROPIC_VERSION = "2023-06-01";

    @Inject
    @RestClient
    AnthropicClient client;

    @Inject
    ObjectMapper mapper;

    @ConfigProperty(name = "router.anthropic.api-key")
    Optional<String> apiKey;

    @ConfigProperty(name = "router.anthropic.model", defaultValue = "claude-3-5-haiku-latest")
    String model;

    @ConfigProperty(name = "router.anthropic.max-tokens", defaultValue = "1024")
    int defaultMaxTokens;

    public JsonNode chat(@Body ObjectNode openAiRequest, @ExchangeProperty("modelProvided") boolean modelProvided,
                          Exchange exchange) {
        String key = apiKey.filter(k -> !k.isBlank())
                .orElseThrow(() -> new IllegalStateException("ANTHROPIC_API_KEY is not configured"));

        String targetModel = modelProvided ? openAiRequest.path("model").asText() : model;
        exchange.setProperty("backend", "anthropic/" + targetModel);

        ObjectNode anthropicRequest = toAnthropicRequest(openAiRequest, targetModel);
        JsonNode anthropicResponse = client.messages(key, ANTHROPIC_VERSION, anthropicRequest);
        return toOpenAiResponse(anthropicResponse, targetModel);
    }

    private ObjectNode toAnthropicRequest(ObjectNode openAiRequest, String targetModel) {
        ObjectNode out = mapper.createObjectNode();
        out.put("model", targetModel);
        out.put("max_tokens", openAiRequest.path("max_tokens").asInt(defaultMaxTokens));
        if (openAiRequest.hasNonNull("temperature")) {
            out.put("temperature", openAiRequest.path("temperature").asDouble());
        }

        StringBuilder system = new StringBuilder();
        ArrayNode messages = out.putArray("messages");
        for (JsonNode message : openAiRequest.path("messages")) {
            String role = message.path("role").asText("user");
            String content = message.path("content").asText("");
            if ("system".equals(role)) {
                if (!system.isEmpty()) {
                    system.append("\n\n");
                }
                system.append(content);
            } else {
                messages.addObject().put("role", "assistant".equals(role) ? "assistant" : "user").put("content", content);
            }
        }
        if (!system.isEmpty()) {
            out.put("system", system.toString());
        }
        return out;
    }

    private JsonNode toOpenAiResponse(JsonNode anthropicResponse, String targetModel) {
        if (anthropicResponse.has("error")) {
            // Anthropic returned 2xx with an error body (rare); surface it like any other failure.
            throw new RuntimeException("anthropic error: " + anthropicResponse.path("error").path("message")
                    .asText(anthropicResponse.toString()));
        }

        StringBuilder text = new StringBuilder();
        for (JsonNode block : anthropicResponse.path("content")) {
            if ("text".equals(block.path("type").asText())) {
                text.append(block.path("text").asText(""));
            }
        }

        long promptTokens = anthropicResponse.path("usage").path("input_tokens").asLong(0);
        long completionTokens = anthropicResponse.path("usage").path("output_tokens").asLong(0);

        ObjectNode out = mapper.createObjectNode();
        out.put("id", anthropicResponse.path("id").asText("anthropic-" + System.nanoTime()));
        out.put("object", "chat.completion");
        out.put("created", System.currentTimeMillis() / 1000);
        out.put("model", anthropicResponse.path("model").asText(targetModel));
        ArrayNode choices = out.putArray("choices");
        ObjectNode choice = choices.addObject();
        choice.put("index", 0);
        choice.putObject("message").put("role", "assistant").put("content", text.toString());
        choice.put("finish_reason", finishReason(anthropicResponse.path("stop_reason").asText("end_turn")));
        ObjectNode usage = out.putObject("usage");
        usage.put("prompt_tokens", promptTokens);
        usage.put("completion_tokens", completionTokens);
        usage.put("total_tokens", promptTokens + completionTokens);
        return out;
    }

    private static String finishReason(String anthropicStopReason) {
        return switch (anthropicStopReason) {
            case "max_tokens" -> "length";
            case "end_turn", "stop_sequence" -> "stop";
            case "tool_use" -> "tool_calls";
            default -> anthropicStopReason;
        };
    }
}
