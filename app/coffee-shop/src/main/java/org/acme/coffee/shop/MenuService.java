package org.acme.coffee.shop;

import io.micrometer.core.instrument.MeterRegistry;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.eclipse.microprofile.faulttolerance.CircuitBreaker;
import org.eclipse.microprofile.faulttolerance.Fallback;
import org.eclipse.microprofile.faulttolerance.Retry;
import org.eclipse.microprofile.faulttolerance.Timeout;
import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.jboss.logging.Logger;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * The menu the shop prices with. Resilient on purpose, so the chaos demo has something to show:
 * a slow or failing coffee-menu (mesh fault injection) is retried, cut off after 1.5 s, and
 * answered from the last known menu. The UI shows where the menu came from.
 */
@ApplicationScoped
public class MenuService {

    private static final Logger LOG = Logger.getLogger(MenuService.class);

    public record LiveMenu(String source, String version, String pod, List<MenuClient.MenuItem> items, long elapsedMs) {}
    public record ProbeResult(int requests, Map<String, Integer> versions, Map<String, Integer> errors,
                              long p50Ms, long p95Ms, long maxMs) {}

    private static final List<MenuClient.MenuItem> DEFAULT_MENU = List.of(
            new MenuClient.MenuItem("espresso", 250, false, false),
            new MenuClient.MenuItem("americano", 300, false, false),
            new MenuClient.MenuItem("cappuccino", 380, true, false),
            new MenuClient.MenuItem("latte", 400, true, false),
            new MenuClient.MenuItem("flat white", 400, true, false));

    @Inject @RestClient MenuClient client;
    @Inject MeterRegistry registry;

    private volatile MenuClient.Menu lastKnown;

    @Timeout(1500)
    @Retry(maxRetries = 2, delay = 100)
    @CircuitBreaker(requestVolumeThreshold = 10, failureRatio = 0.5, delay = 10_000)
    @Fallback(fallbackMethod = "cached")
    public LiveMenu current() {
        long start = System.nanoTime();
        MenuClient.Menu menu = client.menu();
        lastKnown = menu;
        registry.counter("coffee.menu.lookups", "source", "live", "version", menu.version()).increment();
        return new LiveMenu("live", menu.version(), menu.pod(), menu.items(), (System.nanoTime() - start) / 1_000_000);
    }

    public LiveMenu cached() {
        MenuClient.Menu menu = lastKnown;
        String source = menu == null ? "built-in default" : "cache";
        registry.counter("coffee.menu.lookups", "source", source.replace(' ', '-'), "version",
                menu == null ? "none" : menu.version()).increment();
        LOG.warnf("coffee-menu unavailable or too slow, using the %s menu", source);
        return menu == null
                ? new LiveMenu(source, "default", "-", DEFAULT_MENU, 0)
                : new LiveMenu(source, menu.version(), menu.pod(), menu.items(), 0);
    }

    /** Raw calls without fault tolerance: shows the mesh behaviour as is (versions, errors, latency). */
    public ProbeResult probe(int n) {
        Map<String, Integer> versions = new TreeMap<>();
        Map<String, Integer> errors = new TreeMap<>();
        List<Long> latencies = new ArrayList<>();
        for (int i = 0; i < n; i++) {
            long start = System.nanoTime();
            try {
                MenuClient.Menu menu = client.menu();
                versions.merge(menu.version(), 1, Integer::sum);
            } catch (RuntimeException e) {
                errors.merge(errorName(e), 1, Integer::sum);
            }
            latencies.add((System.nanoTime() - start) / 1_000_000);
        }
        latencies.sort(Long::compare);
        return new ProbeResult(n, versions, errors, percentile(latencies, 50), percentile(latencies, 95),
                latencies.isEmpty() ? 0 : latencies.get(latencies.size() - 1));
    }

    private static String errorName(Throwable e) {
        for (Throwable t = e; t != null; t = t.getCause()) {
            if (t instanceof jakarta.ws.rs.WebApplicationException w && w.getResponse() != null) {
                return "HTTP " + w.getResponse().getStatus();
            }
            if (t instanceof java.util.concurrent.TimeoutException || t.getClass().getSimpleName().contains("Timeout")) {
                return "timeout";
            }
        }
        return e.getClass().getSimpleName();
    }

    private static long percentile(List<Long> sorted, int p) {
        if (sorted.isEmpty()) {
            return 0;
        }
        int index = (int) Math.ceil(p / 100.0 * sorted.size()) - 1;
        return sorted.get(Math.max(0, Math.min(index, sorted.size() - 1)));
    }
}
