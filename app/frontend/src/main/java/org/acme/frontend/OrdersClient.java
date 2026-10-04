package org.acme.frontend;

import com.fasterxml.jackson.databind.JsonNode;
import jakarta.ws.rs.DELETE;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.PUT;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

@RegisterRestClient(configKey = "orders")
@Path("/api")
public interface OrdersClient {

    @GET @Path("/customers") JsonNode customers();
    @POST @Path("/customers") JsonNode createCustomer(JsonNode customer);
    @PUT @Path("/customers/{id}") JsonNode updateCustomer(@PathParam("id") int id, JsonNode customer);
    @POST @Path("/orders") JsonNode createOrder(JsonNode order);
    @DELETE @Path("/orders/{id}") void deleteOrder(@PathParam("id") int id);
}
