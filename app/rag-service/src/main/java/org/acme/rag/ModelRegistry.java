package org.acme.rag;

import dev.langchain4j.model.chat.ChatModel;
import io.quarkiverse.langchain4j.ModelName;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import java.util.Locale;

/**
 * One LangChain4j ChatModel per alias (see quarkus.langchain4j.openai.<alias>.* in
 * application.properties). All four point at the model-router; Camel decides the real backend.
 */
@ApplicationScoped
public class ModelRegistry {

    @Inject @ModelName("gemma") ChatModel gemma;
    @Inject @ModelName("qwen") ChatModel qwen;
    @Inject @ModelName("openai") ChatModel openai;
    @Inject @ModelName("auto") ChatModel auto;

    public String normalize(String alias) {
        String a = alias == null ? "auto" : alias.toLowerCase(Locale.ROOT);
        return switch (a) {
            case "gemma", "qwen", "openai", "auto" -> a;
            default -> "auto";
        };
    }

    public ChatModel get(String alias) {
        return switch (normalize(alias)) {
            case "gemma" -> gemma;
            case "qwen" -> qwen;
            case "openai" -> openai;
            default -> auto;
        };
    }
}
