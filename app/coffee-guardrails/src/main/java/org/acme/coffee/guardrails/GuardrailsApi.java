package org.acme.coffee.guardrails;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
/**
 * A NeMo Guardrails server (TrustyAI image locally and on OpenShift AI). One instance per model
 * provider, all with the same rules; clients are built in Providers.
 */
public interface GuardrailsApi {

    /** Input rails, model call, output rails. OpenAI shaped, plus a "guardrails" object. */
    @POST
    @Path("/v1/chat/completions")
    JsonNode chat(JsonNode request);

    /** TrustyAI addition: run the rails on a message without calling the model. */
    @POST
    @Path("/v1/guardrail/checks")
    JsonNode checks(JsonNode request);

    @GET
    @Path("/v1/rails/configs")
    JsonNode configs();
}
