package org.acme.projection;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

/**
 * A Debezium change event. Works with and without the JSON converter schema envelope.
 *
 * @param op     c = create, u = update, d = delete, r = snapshot read
 * @param before row before the change (only the key columns for deletes, unless REPLICA IDENTITY FULL)
 * @param after  row after the change (null for deletes)
 */
public record ChangeEvent(String table, String op, JsonNode before, JsonNode after, long sourceTsMs) {

    public static ChangeEvent parse(ObjectMapper mapper, String json) throws Exception {
        JsonNode root = mapper.readTree(json);
        JsonNode payload = root.has("payload") ? root.get("payload") : root;
        JsonNode source = payload.path("source");
        return new ChangeEvent(
                source.path("table").asText("unknown"),
                payload.path("op").asText("?"),
                nullable(payload.get("before")),
                nullable(payload.get("after")),
                source.path("ts_ms").asLong(0));
    }

    private static JsonNode nullable(JsonNode n) {
        return n == null || n.isNull() ? null : n;
    }

    public String operation() {
        return switch (op) {
            case "c" -> "created";
            case "u" -> "updated";
            case "d" -> "deleted";
            case "r" -> "snapshot";
            default -> op;
        };
    }
}
