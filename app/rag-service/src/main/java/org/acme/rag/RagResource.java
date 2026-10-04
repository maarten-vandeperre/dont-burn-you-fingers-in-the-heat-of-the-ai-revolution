package org.acme.rag;

import dev.langchain4j.data.message.SystemMessage;
import dev.langchain4j.data.message.UserMessage;
import dev.langchain4j.model.chat.response.ChatResponse;
import dev.langchain4j.model.input.PromptTemplate;
import dev.langchain4j.model.output.TokenUsage;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import java.util.stream.IntStream;

@Path("/api/rag")
public class RagResource {

    private static final Logger LOG = Logger.getLogger(RagResource.class);
    private static final Pattern THINK = Pattern.compile("(?s)<think>.*?</think>");

    // v1 and v2 run the same image; the version only changes retrieval depth and prompt style,
    // which is enough to compare them with canary / A-B / blue-green / mirroring.
    private static final PromptTemplate V1 = PromptTemplate.from("""
            Answer the question using only the context below. Answer in at most three sentences.
            If the context does not contain the answer, say you do not know.

            Context:
            {{context}}

            Question: {{question}}""");
    private static final PromptTemplate V2 = PromptTemplate.from("""
            You are a platform engineering assistant. Use only the numbered context passages below.
            Answer with short bullet points and cite the passages you used as [1], [2], ...
            If the context does not contain the answer, say you do not know.

            Context:
            {{context}}

            Question: {{question}}""");

    public record AskRequest(String question, String model) {}
    public record Source(int index, String title, String snippet, double score) {}
    public record AskResponse(String answer, List<Source> sources, String model, String version,
                              String pod, long retrievalMs, long generationMs,
                              Integer inputTokens, Integer outputTokens) {}
    public record VersionInfo(String service, String version, String pod, int chunks) {}

    @Inject KnowledgeBase knowledgeBase;
    @Inject ModelRegistry models;
    @Inject MeterRegistry registry;

    @ConfigProperty(name = "app.version", defaultValue = "v1")
    String version;

    @ConfigProperty(name = "rag.top-k", defaultValue = "3")
    int topK;

    @ConfigProperty(name = "HOSTNAME", defaultValue = "local")
    String pod;

    @POST
    @Path("/ask")
    public AskResponse ask(AskRequest request) {
        if (request == null || request.question() == null || request.question().isBlank()) {
            throw new WebApplicationException("question is required", Response.Status.BAD_REQUEST);
        }
        String alias = models.normalize(request.model());

        long t0 = System.nanoTime();
        List<KnowledgeBase.Hit> hits = knowledgeBase.search(request.question(), topK);
        long retrievalNanos = System.nanoTime() - t0;

        String context = IntStream.range(0, hits.size())
                .mapToObj(i -> "[" + (i + 1) + "] " + hits.get(i).title() + "\n" + hits.get(i).text())
                .reduce("", (a, b) -> a + b + "\n\n");
        PromptTemplate template = "v2".equals(version) ? V2 : V1;
        String prompt = template.apply(Map.<String, Object>of(
                "context", context.isBlank() ? "(no matching documents)" : context,
                "question", request.question())).text();

        long t1 = System.nanoTime();
        ChatResponse response;
        try {
            response = models.get(alias).chat(
                    SystemMessage.from("You answer questions about an OpenShift AI demo platform."),
                    UserMessage.from(prompt));
        } catch (RuntimeException e) {
            LOG.errorf("model call failed (alias=%s): %s", alias, e.getMessage());
            registry.counter("rag.requests", "model", alias, "version", version, "outcome", "error").increment();
            throw new WebApplicationException("model call failed: " + e.getMessage(), Response.Status.BAD_GATEWAY);
        }
        long generationNanos = System.nanoTime() - t1;

        Timer.builder("rag.retrieval").tag("version", version).publishPercentileHistogram()
                .register(registry).record(retrievalNanos, java.util.concurrent.TimeUnit.NANOSECONDS);
        Timer.builder("rag.generation").tag("model", alias).tag("version", version).publishPercentileHistogram()
                .register(registry).record(generationNanos, java.util.concurrent.TimeUnit.NANOSECONDS);
        registry.counter("rag.requests", "model", alias, "version", version, "outcome", "success").increment();

        String answer = THINK.matcher(response.aiMessage().text() == null ? "" : response.aiMessage().text())
                .replaceAll("").strip();
        TokenUsage usage = response.tokenUsage();
        List<Source> sources = IntStream.range(0, hits.size())
                .mapToObj(i -> new Source(i + 1, hits.get(i).title(), snippet(hits.get(i).text()), round(hits.get(i).score())))
                .toList();
        LOG.infof("rag answer version=%s model=%s sources=%d retrieval_ms=%d generation_ms=%d",
                version, alias, hits.size(), retrievalNanos / 1_000_000, generationNanos / 1_000_000);
        return new AskResponse(answer, sources, alias, version, pod,
                retrievalNanos / 1_000_000, generationNanos / 1_000_000,
                usage == null ? null : usage.inputTokenCount(), usage == null ? null : usage.outputTokenCount());
    }

    /** Cheap endpoint for the traffic view: shows which version (v1 / v2) served the request. */
    @GET
    @Path("/version")
    public VersionInfo version() {
        // one line per request, so mirrored (shadow) traffic is visible in the v2 logs
        LOG.infof("version request served by rag-service %s (pod %s)", version, pod);
        return new VersionInfo("rag-service", version, pod, knowledgeBase.size());
    }

    private static String snippet(String text) {
        String flat = text.replaceAll("\\s+", " ").strip();
        return flat.length() > 220 ? flat.substring(0, 217) + "..." : flat;
    }

    private static double round(double v) {
        return Math.round(v * 100) / 100.0;
    }
}
