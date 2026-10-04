package ${{ values.packageName }};

import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.Map;

@Path("/api")
public class AskResource {

    private static final Logger LOG = Logger.getLogger(AskResource.class);

    public record Question(String question) {}
    public record Answer(String answer, String useCase, int maxChars, long elapsedMs) {}
    public record Config(String name, String description, String useCase, String size, int maxChars) {}

    @Inject
    Assistant assistant;

    @ConfigProperty(name = "app.use-case")
    UseCase useCase;

    @ConfigProperty(name = "app.size")
    String size;

    @ConfigProperty(name = "app.max-input-chars")
    int maxChars;

    @ConfigProperty(name = "app.description", defaultValue = "")
    String description;

    @ConfigProperty(name = "quarkus.application.name")
    String name;

    @GET
    @Path("/config")
    public Config config() {
        return new Config(name, description, useCase.label(), size, maxChars);
    }

    @POST
    @Path("/ask")
    public Answer ask(Question input) {
        String question = input == null || input.question() == null ? "" : input.question().strip();
        if (question.isEmpty()) {
            throw problem(400, "Please enter a question.");
        }
        if (question.length() > maxChars) {
            throw problem(400, "This application accepts at most " + maxChars + " characters ("
                    + size + "). Your text has " + question.length() + ".");
        }
        long start = System.nanoTime();
        try {
            String answer = assistant.answer(useCase.instructions(), question);
            return new Answer(answer, useCase.label(), maxChars, (System.nanoTime() - start) / 1_000_000);
        } catch (RuntimeException e) {
            LOG.warnf("model call failed: %s", e.getMessage());
            throw problem(502, "The model did not answer. Check LLM_API_KEY / LLM_BASE_URL, or try again.");
        }
    }

    private static WebApplicationException problem(int status, String message) {
        return new WebApplicationException(Response.status(status).entity(Map.of("error", message)).build());
    }
}
