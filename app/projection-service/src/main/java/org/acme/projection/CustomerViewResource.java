package org.acme.projection;

import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import org.bson.Document;

import java.util.List;

@Path("/api/customer-views")
public class CustomerViewResource {

    @Inject
    CustomerViewRepository views;

    @GET
    public List<Document> list() {
        return views.all();
    }
}
