package org.acme.orders;

import io.micrometer.core.instrument.MeterRegistry;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import jakarta.ws.rs.DELETE;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.PUT;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.WebApplicationException;
import jakarta.ws.rs.core.Response;
import org.jboss.logging.Logger;

import java.util.List;

/**
 * Every write here becomes a Debezium change event in Kafka a moment later, and ends up as a
 * formatted document in MongoDB through the projection-service.
 */
@Path("/api")
public class OrdersResource {

    private static final Logger LOG = Logger.getLogger(OrdersResource.class);

    public record CustomerInput(String firstName, String lastName, String email) {}
    public record OrderInput(Integer customerId, String product, Integer quantity) {}

    @Inject
    MeterRegistry registry;

    @GET
    @Path("/customers")
    public List<Customer> customers() {
        return Customer.listAll();
    }

    @POST
    @Path("/customers")
    @Transactional
    public Customer createCustomer(CustomerInput input) {
        if (input == null || blank(input.firstName()) || blank(input.lastName()) || blank(input.email())) {
            throw new WebApplicationException("firstName, lastName and email are required", Response.Status.BAD_REQUEST);
        }
        if (Customer.count("email", input.email()) > 0) {
            throw new WebApplicationException("email already exists", Response.Status.CONFLICT);
        }
        Customer c = new Customer();
        c.firstName = input.firstName().strip();
        c.lastName = input.lastName().strip();
        c.email = input.email().strip().toLowerCase();
        c.persist();
        written("customers", "insert");
        LOG.infof("customer %d created", c.id);
        return c;
    }

    @PUT
    @Path("/customers/{id}")
    @Transactional
    public Customer updateCustomer(@PathParam("id") Integer id, CustomerInput input) {
        Customer c = Customer.<Customer>findByIdOptional(id).orElseThrow(NotFoundException::new);
        if (input != null) {
            if (!blank(input.firstName())) c.firstName = input.firstName().strip();
            if (!blank(input.lastName())) c.lastName = input.lastName().strip();
            if (!blank(input.email())) c.email = input.email().strip().toLowerCase();
        }
        written("customers", "update");
        return c;
    }

    @GET
    @Path("/orders")
    public List<PurchaseOrder> orders(@QueryParam("customerId") Integer customerId) {
        return customerId == null ? PurchaseOrder.listAll() : PurchaseOrder.list("customerId", customerId);
    }

    @POST
    @Path("/orders")
    @Transactional
    public PurchaseOrder createOrder(OrderInput input) {
        if (input == null || input.customerId() == null || blank(input.product())) {
            throw new WebApplicationException("customerId and product are required", Response.Status.BAD_REQUEST);
        }
        if (Customer.findById(input.customerId()) == null) {
            throw new WebApplicationException("unknown customer " + input.customerId(), Response.Status.BAD_REQUEST);
        }
        PurchaseOrder o = new PurchaseOrder();
        o.customerId = input.customerId();
        o.product = input.product().strip();
        o.quantity = input.quantity() == null || input.quantity() < 1 ? 1 : input.quantity();
        o.persist();
        written("orders", "insert");
        LOG.infof("order %d created for customer %d", o.id, o.customerId);
        return o;
    }

    @DELETE
    @Path("/orders/{id}")
    @Transactional
    public Response deleteOrder(@PathParam("id") Integer id) {
        if (!PurchaseOrder.deleteById(id)) {
            throw new NotFoundException();
        }
        written("orders", "delete");
        return Response.noContent().build();
    }

    private void written(String table, String op) {
        registry.counter("orders.writes", "table", table, "op", op).increment();
    }

    private static boolean blank(String s) {
        return s == null || s.isBlank();
    }
}
