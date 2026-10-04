package org.acme.router;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.inject.Named;
import org.apache.camel.Body;
import org.apache.camel.Exchange;

import java.util.List;
import java.util.Locale;

@ApplicationScoped
@Named("modelAliases")
public class ModelAliases {

    static final List<String> ALIASES = List.of("gemma", "qwen", "openai", "auto");

    @Inject
    ObjectMapper mapper;

    /** Parses the OpenAI request, normalises the alias and stores it as exchange property "alias". */
    public ObjectNode resolve(@Body String json, Exchange exchange) throws Exception {
        ObjectNode request = (ObjectNode) mapper.readTree(json);
        String alias = request.path("model").asText("auto").toLowerCase(Locale.ROOT);
        if (!ALIASES.contains(alias)) {
            alias = "auto";
        }
        exchange.setProperty("alias", alias);
        exchange.setProperty("requestedAlias", alias);
        exchange.setProperty("startNanos", System.nanoTime());
        return request;
    }

    public String list() throws Exception {
        ObjectNode root = mapper.createObjectNode().put("object", "list");
        ArrayNode data = root.putArray("data");
        ALIASES.forEach(a -> data.addObject().put("id", a).put("object", "model").put("owned_by", "model-router"));
        return mapper.writeValueAsString(root);
    }
}
