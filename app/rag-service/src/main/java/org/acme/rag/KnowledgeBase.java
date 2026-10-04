package org.acme.rag;

import io.opentelemetry.instrumentation.annotations.SpanAttribute;
import io.opentelemetry.instrumentation.annotations.WithSpan;
import io.quarkus.runtime.Startup;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import org.jboss.logging.Logger;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Small in-memory knowledge base over the markdown files in src/main/resources/docs.
 *
 * Retrieval is lexical (BM25) on purpose: the demo then needs no embedding model and no vector
 * database. For semantic search swap this class for a LangChain4j EmbeddingStoreContentRetriever
 * (pgvector + an embedding model served through MaaS); the RAG flow stays the same.
 */
@Startup
@ApplicationScoped
public class KnowledgeBase {

    private static final Logger LOG = Logger.getLogger(KnowledgeBase.class);
    private static final Set<String> STOP = Set.of("the", "a", "an", "and", "or", "of", "to", "in", "is", "it",
            "for", "on", "with", "as", "by", "be", "are", "this", "that", "what", "how", "why", "do", "does",
            "can", "i", "you", "we", "my", "our", "from", "at", "which", "when", "who");
    private static final double K1 = 1.4;
    private static final double B = 0.75;

    public record Chunk(String title, String text, List<String> terms) {}
    public record Hit(String title, String text, double score) {}

    private final List<Chunk> chunks = new ArrayList<>();
    private final Map<String, Integer> documentFrequency = new HashMap<>();
    private double averageLength;

    @PostConstruct
    void load() {
        for (String file : readResource("docs/index.txt").lines().map(String::strip).filter(l -> !l.isEmpty()).toList()) {
            String markdown = readResource("docs/" + file);
            String title = markdown.lines().filter(l -> l.startsWith("# ")).findFirst()
                    .map(l -> l.substring(2).strip()).orElse(file);
            for (String paragraph : split(markdown)) {
                chunks.add(new Chunk(title, paragraph, tokenize(paragraph)));
            }
        }
        chunks.forEach(c -> c.terms().stream().distinct().forEach(t -> documentFrequency.merge(t, 1, Integer::sum)));
        averageLength = chunks.stream().mapToInt(c -> c.terms().size()).average().orElse(1);
        LOG.infof("knowledge base loaded: %d chunks, %d distinct terms", chunks.size(), documentFrequency.size());
    }

    @WithSpan("rag.retrieve")
    public List<Hit> search(@SpanAttribute("rag.query") String query, @SpanAttribute("rag.top_k") int topK) {
        List<String> queryTerms = tokenize(query);
        return chunks.stream()
                .map(c -> new Hit(c.title(), c.text(), bm25(queryTerms, c)))
                .filter(h -> h.score() > 0)
                .sorted(Comparator.comparingDouble(Hit::score).reversed())
                .limit(topK)
                .toList();
    }

    public int size() {
        return chunks.size();
    }

    private double bm25(List<String> queryTerms, Chunk chunk) {
        Map<String, Long> tf = new HashMap<>();
        chunk.terms().forEach(t -> tf.merge(t, 1L, Long::sum));
        double score = 0;
        for (String term : queryTerms) {
            long f = tf.getOrDefault(term, 0L);
            if (f == 0) {
                continue;
            }
            int df = documentFrequency.getOrDefault(term, 0);
            double idf = Math.log(1 + (chunks.size() - df + 0.5) / (df + 0.5));
            score += idf * (f * (K1 + 1)) / (f + K1 * (1 - B + B * chunk.terms().size() / averageLength));
        }
        return score;
    }

    /** Paragraph based chunks of roughly 300 to 700 characters, headings stay with their text. */
    static List<String> split(String markdown) {
        List<String> result = new ArrayList<>();
        StringBuilder current = new StringBuilder();
        for (String block : markdown.split("\\n\\s*\\n")) {
            String b = block.strip();
            if (b.isEmpty() || b.startsWith("# ")) {
                continue;
            }
            if (current.length() + b.length() > 700 && current.length() > 300) {
                result.add(current.toString().strip());
                current.setLength(0);
            }
            current.append(b).append("\n\n");
        }
        if (!current.isEmpty()) {
            result.add(current.toString().strip());
        }
        return result;
    }

    static List<String> tokenize(String text) {
        return Arrays.stream(text.toLowerCase(Locale.ROOT).split("[^a-z0-9]+"))
                .filter(t -> t.length() > 1 && !STOP.contains(t))
                .toList();
    }

    private static String readResource(String path) {
        try (InputStream in = Thread.currentThread().getContextClassLoader().getResourceAsStream(path)) {
            if (in == null) {
                throw new IllegalStateException("missing resource " + path);
            }
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("cannot read " + path, e);
        }
    }
}
