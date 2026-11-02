package org.acme.camelrouter;

import jakarta.enterprise.context.ApplicationScoped;
import org.apache.camel.Exchange;
import org.apache.camel.builder.RouteBuilder;

import java.util.NoSuchElementException;

/**
 * The admin page: {@code GET /admin} is a small static HTML/JS page (served by {@link AdminPage})
 * that polls the two JSON routes below (backed by {@link CallLogStore}) to show a live table of
 * every {@code /v1/chat/completions} call -- which backend handled it, whether it fell back or
 * was forced to local, and how long it took -- and, when a row is clicked, the exact prompt and
 * response bodies for that call. The page also links out to Hawtio ({@code /hawtio}, wired up via
 * the {@code io.hawt:hawtio-quarkus} + {@code camel-quarkus-management} dependencies and
 * {@code quarkus.hawtio.*} config, not a Camel route) for a live view -- and limited editing -- of
 * the Camel route(s) themselves. See the README's "Admin page & Hawtio" section.
 */
@ApplicationScoped
public class AdminRoutes extends RouteBuilder {

    @Override
    public void configure() {
        from("platform-http:/admin?httpMethodRestrict=GET")
                .routeId("admin-page")
                .bean("adminPage", "page")
                .setHeader(Exchange.CONTENT_TYPE, constant("text/html; charset=utf-8"));

        from("platform-http:/admin/calls?httpMethodRestrict=GET")
                .routeId("admin-calls-list")
                .bean("callLogStore", "listJson")
                .setHeader(Exchange.CONTENT_TYPE, constant("application/json"));

        from("platform-http:/admin/calls/{id}?httpMethodRestrict=GET")
                .routeId("admin-calls-detail")
                .onException(IllegalArgumentException.class)
                    .handled(true)
                    .setHeader(Exchange.HTTP_RESPONSE_CODE, constant(400))
                    .setHeader(Exchange.CONTENT_TYPE, constant("application/json"))
                    .setBody(simple("{\"error\":\"${exception.message}\"}"))
                .end()
                .onException(NoSuchElementException.class)
                    .handled(true)
                    .setHeader(Exchange.HTTP_RESPONSE_CODE, constant(404))
                    .setHeader(Exchange.CONTENT_TYPE, constant("application/json"))
                    .setBody(simple("{\"error\":\"${exception.message}\"}"))
                .end()
                .bean("callLogStore", "callJson")
                .setHeader(Exchange.CONTENT_TYPE, constant("application/json"));
    }
}
