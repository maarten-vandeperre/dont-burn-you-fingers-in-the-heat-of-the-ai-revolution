package org.acme.coffee.shop;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

import java.util.List;

/** coffee-menu, reached through the mesh (VirtualService: versions, mirroring, faults). */
@RegisterRestClient(configKey = "coffee-menu")
@Path("/api/menu")
public interface MenuClient {

    record MenuItem(String drink, int priceCents, boolean milk, boolean seasonal) {}
    record Menu(String version, String pod, List<MenuItem> items) {}

    @GET
    Menu menu();
}
