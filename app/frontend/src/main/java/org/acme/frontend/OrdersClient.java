package org.acme.frontend;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.ws.rs.DELETE;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.PUT;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.rest.client.annotation.ClientExceptionMapper;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@RegisterRestClient(configKey = "orders")
@Path("/api")
public interface OrdersClient {

    /** Pass orders-service errors through, including "Duplicate email: …" on 409. */
    @ClientExceptionMapper
    static RuntimeException toException(Response response) {
        if (response.getStatus() < 400) {
            return null;
        }
        String body = response.hasEntity() ? response.readEntity(String.class) : "";
        if (body == null || body.isBlank()) {
            body = response.getStatusInfo().getReasonPhrase();
        }
        return new WebApplicationException(Response.status(response.getStatus())
                .type(MediaType.TEXT_PLAIN)
                .entity(body)
                .build());
    }

    @GET @Path("/customers") JsonNode customers();
    @POST @Path("/customers") JsonNode createCustomer(JsonNode customer);
    @PUT @Path("/customers/{id}") JsonNode updateCustomer(@PathParam("id") int id, JsonNode customer);
    @POST @Path("/orders") JsonNode createOrder(JsonNode order);
    @DELETE @Path("/orders/{id}") void deleteOrder(@PathParam("id") int id);
}
