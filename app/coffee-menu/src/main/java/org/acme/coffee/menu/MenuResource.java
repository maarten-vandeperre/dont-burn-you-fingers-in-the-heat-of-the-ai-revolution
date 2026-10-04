package org.acme.coffee.menu;

import io.micrometer.core.instrument.MeterRegistry;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.NotFoundException;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.jboss.logging.Logger;

import java.util.List;

/**
 * v1: the classic menu. v2: new prices plus a mocha and a seasonal drink. Same image, the
 * version comes from APP_VERSION, which keeps the traffic patterns easy to see.
 */
@Path("/api/menu")
public class MenuResource {

    private static final Logger LOG = Logger.getLogger(MenuResource.class);

    public record MenuItem(String drink, int priceCents, boolean milk, boolean seasonal) {}
    public record Menu(String version, String pod, List<MenuItem> items) {}

    private static final List<MenuItem> V1 = List.of(
            new MenuItem("espresso", 250, false, false),
            new MenuItem("americano", 300, false, false),
            new MenuItem("cappuccino", 380, true, false),
            new MenuItem("latte", 400, true, false),
            new MenuItem("flat white", 400, true, false));

    private static final List<MenuItem> V2 = List.of(
            new MenuItem("espresso", 260, false, false),
            new MenuItem("americano", 310, false, false),
            new MenuItem("cappuccino", 390, true, false),
            new MenuItem("latte", 410, true, false),
            new MenuItem("flat white", 420, true, false),
            new MenuItem("mocha", 450, true, false),
            new MenuItem("pumpkin spice latte", 480, true, true));

    @ConfigProperty(name = "app.version", defaultValue = "v1")
    String version;

    @ConfigProperty(name = "HOSTNAME", defaultValue = "local")
    String pod;

    @Inject
    MeterRegistry registry;

    @GET
    public Menu menu() {
        registry.counter("coffee.menu.requests", "version", version).increment();
        // one line per request: mirrored (shadow) traffic shows up in the v2 log
        LOG.infof("menu served by coffee-menu %s (pod %s)", version, pod);
        return new Menu(version, pod, items());
    }

    @GET
    @Path("/{drink}")
    public MenuItem item(@PathParam("drink") String drink) {
        return items().stream().filter(i -> i.drink().equalsIgnoreCase(drink)).findFirst()
                .orElseThrow(NotFoundException::new);
    }

    private List<MenuItem> items() {
        return "v2".equals(version) ? V2 : V1;
    }
}
