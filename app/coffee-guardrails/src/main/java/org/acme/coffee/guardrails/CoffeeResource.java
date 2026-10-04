package org.acme.coffee.guardrails;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * The coffee order assistant. Every message goes to the guardrails server, never directly to a
 * model: input rails, then the model (Qwen on Podman AI Lab or OpenAI), then output rails.
 * The response says which rails ran and which one stopped the message.
 */
@Path("/api")
public class CoffeeResource {

    private static final Logger LOG = Logger.getLogger(CoffeeResource.class);

    /** Human readable names of the rails in guardrails/config/coffee/config.yaml. */
    static final Map<String, String> LABELS = Map.of(
            "regex check input", "Prompt injection patterns (TrustyAI regex)",
            "check input length", "Input max 200 characters",
            "mask sensitive data on input", "Personal data masked (Presidio)",
            "check cappuccino time", "No cappuccino after noon",
            "self check input", "Coffee only (LLM judge)",
            "generate user intent", "Model call",
            "check cappuccino output", "No cappuccino after noon (answer)",
            "limit output length", "Answer max 200 characters");

    public record Turn(String role, String content) {}
    public record ChatRequest(String message, List<Turn> history, String provider) {}
    public record Rail(String name, String label, String type, boolean stopped, long ms) {}
    public record ChatResponse(String provider, String providerLabel, String model, String answer, List<Rail> rails,
                               String blockedBy, boolean modelCalled, String shopTime, long elapsedMs) {}
    public record ClockRequest(ShopClock.Mode mode) {}

    @Inject Providers providers;
    @Inject ShopClock clock;
    @Inject ObjectMapper json;

    @ConfigProperty(name = "guardrails.config-id") String configId;
    @ConfigProperty(name = "coffee.system-prompt") String systemPrompt;

    @GET
    @Path("/status")
    public Map<String, Object> status() {
        List<Map<String, Object>> list = new ArrayList<>();
        for (Providers.Provider p : providers.all()) {
            String state;
            try {
                state = p.guardrails().configs().toString().contains(configId) ? "ready" : "config '" + configId + "' missing";
            } catch (RuntimeException e) {
                state = "guardrails server unreachable";
            }
            list.add(Map.of("id", p.id(), "label", p.label(), "model", p.model(), "guardrails", state));
        }
        return Map.of("providers", list, "defaultProvider", providers.defaultProvider(), "configId", configId,
                "shopTime", clock.time(), "clockMode", clock.mode().name());
    }

    /** Called by the guardrail action check_cappuccino_time (SHOP_CLOCK_URL). */
    @GET
    @Path("/clock")
    public Map<String, String> clock() {
        return Map.of("time", clock.time(), "mode", clock.mode().name());
    }

    @POST
    @Path("/clock")
    public Map<String, String> setClock(ClockRequest request) {
        clock.set(request == null ? null : request.mode());
        LOG.infof("shop clock set to %s (%s)", clock.mode(), clock.time());
        return clock();
    }

    @POST
    @Path("/chat")
    public ChatResponse chat(ChatRequest request) {
        String message = request == null || request.message() == null ? "" : request.message().strip();
        if (message.isEmpty() || message.length() > 1000) {
            // the 200 character rule is a guardrail; this is only a sanity limit
            throw problem(400, "Please type a message (at most 1000 characters).");
        }
        Providers.Provider provider = providers.get(request.provider());
        ObjectNode body = json.createObjectNode().put("model", provider.model());
        ArrayNode messages = body.putArray("messages");
        messages.addObject().put("role", "system").put("content", systemPrompt);
        // Context from earlier turns: ONLY the assistant's answers. Input rails check the newest
        // user message only, so resending earlier user messages would let a blocked prompt
        // injection or unmasked personal data reach the model after all. The answers passed the
        // output rails and never contained the raw personal data.
        List<Turn> history = request.history() == null ? List.of() : request.history();
        history.stream().filter(t -> "assistant".equals(t.role()) && t.content() != null)
                .skip(Math.max(0, history.stream().filter(t -> "assistant".equals(t.role())).count() - 3))
                .forEach(t -> messages.addObject().put("role", "assistant").put("content", t.content()));
        messages.addObject().put("role", "user").put("content", message);
        body.putObject("guardrails").put("config_id", configId)
                .putObject("options").putObject("log").put("activated_rails", true);

        long start = System.nanoTime();
        JsonNode response;
        try {
            response = provider.guardrails().chat(body);
        } catch (RuntimeException e) {
            LOG.warnf("guardrails call (%s) failed: %s", provider.id(), e.getMessage());
            throw problem(502, "The " + provider.label() + " guardrails server did not answer: "
                    + "podman compose logs guardrails-" + provider.id()
                    + ("openai".equals(provider.id()) ? " (is OPENAI_API_KEY set in .env?)" : " (is the AI Lab service running?)"));
        }
        long elapsed = (System.nanoTime() - start) / 1_000_000;

        // OpenAI shape (current NeMo / TrustyAI server); older servers answer {"messages": [...]}
        String answer = response.path("choices").path(0).path("message").path("content")
                .asText(response.path("messages").path(0).path("content").asText(""));
        JsonNode log = response.path("guardrails").path("log");
        if (log.isMissingNode()) {
            log = response.path("log");
        }
        List<Rail> rails = new ArrayList<>();
        String blockedBy = null;
        boolean modelCalled = false;
        for (JsonNode r : log.path("activated_rails")) {
            String name = r.path("name").asText();
            boolean stopped = r.path("stop").asBoolean(false);
            rails.add(new Rail(name, LABELS.getOrDefault(name, name), r.path("type").asText(), stopped,
                    Math.round(r.path("duration").asDouble(0) * 1000)));
            if (stopped && blockedBy == null) {
                blockedBy = LABELS.getOrDefault(name, name);
            }
            modelCalled |= "generate user intent".equals(name) || "generation".equals(r.path("type").asText());
        }
        LOG.infof("chat via %s: %d chars in, %d out, blocked by %s, %d ms", provider.id(), message.length(),
                answer.length(), blockedBy, elapsed);
        return new ChatResponse(provider.id(), provider.label(), provider.model(), answer, rails, blockedBy,
                modelCalled, clock.time(), elapsed);
    }

    /** Check a message against the input rails without calling the model (TrustyAI endpoint). */
    @POST
    @Path("/check")
    public JsonNode check(ChatRequest request) {
        String message = request == null || request.message() == null ? "" : request.message().strip();
        Providers.Provider provider = providers.get(request == null ? null : request.provider());
        ObjectNode body = json.createObjectNode().put("model", provider.model());
        body.putArray("messages").addObject().put("role", "user").put("content", message);
        body.putObject("guardrails").put("config_id", configId);
        try {
            return provider.guardrails().checks(body);
        } catch (WebApplicationException e) {
            if (e.getResponse() != null && e.getResponse().getStatus() == 404) {
                return json.createObjectNode().put("status", "unavailable")
                        .put("detail", "This guardrails server has no /v1/guardrail/checks endpoint: it is a TrustyAI addition. Use the TrustyAI image (default in compose.yaml).");
            }
            throw problem(502, "Check failed: " + e.getMessage());
        }
    }

    private static WebApplicationException problem(int status, String message) {
        return new WebApplicationException(Response.status(status).entity(Map.of("error", message)).build());
    }
}
