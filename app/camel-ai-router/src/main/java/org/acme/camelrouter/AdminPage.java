package org.acme.camelrouter;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Named;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

/**
 * Serves the single static HTML/CSS/JS file behind {@code GET /admin} (read once from the
 * classpath, kept in memory -- no templating engine needed for one page). See
 * {@code src/main/resources/admin/admin.html} for the page itself, and {@link AdminRoutes} for
 * the Camel routes it and its two small JSON APIs (backed by {@link CallLogStore}) are wired to.
 */
@ApplicationScoped
@Named("adminPage")
public class AdminPage {

    private final String html;

    public AdminPage() throws IOException {
        try (InputStream in = getClass().getClassLoader().getResourceAsStream("admin/admin.html")) {
            if (in == null) {
                throw new IOException("admin/admin.html not found on the classpath");
            }
            html = new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    public String page() {
        return html;
    }
}
