package org.acme.camelrouter;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.inject.Named;
import org.eclipse.microprofile.config.Config;
import org.jboss.logging.Logger;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedDeque;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The "x failures in y minutes -> z minutes forced to local" policy.
 * <p>
 * Independently per online provider (openai / anthropic / vllm), this keeps a sliding time
 * window of failure timestamps. Once {@code x} failures land inside the last {@code y} minutes,
 * the provider is marked "tripped": for the next {@code z} minutes, {@link RoutingDecision} sends
 * requests straight to the local model, without even attempting the online provider (and without
 * waiting for a request to fail first, which is what the per-call {@code circuitBreaker()} EIP in
 * {@link ChatRoutes} already does as a defense-in-depth safety net on top of this).
 * <p>
 * Configuration (global default, overridable per provider):
 * <pre>
 *   router.breaker.failure-threshold=5     # x: failures
 *   router.breaker.window-minutes=2        # y: minutes
 *   router.breaker.open-minutes=5          # z: minutes forced to local
 *   router.breaker.openai.failure-threshold=...     (same 3 keys, per provider, optional)
 *   router.breaker.anthropic.window-minutes=...
 *   router.breaker.vllm.open-minutes=...
 * </pre>
 */
@ApplicationScoped
@Named("providerHealthTracker")
public class ProviderHealthTracker {

    private static final Logger LOG = Logger.getLogger(ProviderHealthTracker.class);

    @Inject
    Config config;

    private final Map<String, ConcurrentLinkedDeque<Instant>> failures = new ConcurrentHashMap<>();
    private final Map<String, AtomicReference<Instant>> forcedLocalUntil = new ConcurrentHashMap<>();

    /** Records a failure of the given online provider; may trip it into "forced to local". */
    public void recordFailure(String provider) {
        Instant now = Instant.now();
        ConcurrentLinkedDeque<Instant> window = failures.computeIfAbsent(provider, p -> new ConcurrentLinkedDeque<>());
        window.addLast(now);
        prune(window, now, windowDuration(provider));

        int threshold = failureThreshold(provider);
        if (window.size() >= threshold) {
            Duration openFor = openDuration(provider);
            Instant until = now.plus(openFor);
            forcedLocalUntil.computeIfAbsent(provider, p -> new AtomicReference<>()).set(until);
            window.clear(); // a fresh window of failures is required to trip it again
            LOG.warnf("provider '%s': %d failures within %s, forcing local model for %s (until %s)",
                    provider, threshold, windowDuration(provider), openFor, until);
        }
    }

    /** True while the provider is "tripped": route to local directly, do not even try it. */
    public boolean isForcedLocal(String provider) {
        AtomicReference<Instant> ref = forcedLocalUntil.get(provider);
        return ref != null && ref.get() != null && Instant.now().isBefore(ref.get());
    }

    /** Diagnostics for the status endpoint: recent failure count, forced-local state and until when. */
    public Status status(String provider) {
        Instant now = Instant.now();
        ConcurrentLinkedDeque<Instant> window = failures.get(provider);
        Duration windowDuration = windowDuration(provider);
        int recent = 0;
        if (window != null) {
            prune(window, now, windowDuration);
            recent = window.size();
        }
        AtomicReference<Instant> ref = forcedLocalUntil.get(provider);
        boolean forced = isForcedLocal(provider);
        Instant until = forced && ref != null ? ref.get() : null;
        return new Status(recent, failureThreshold(provider), windowDuration, openDuration(provider), forced, until);
    }

    private static void prune(ConcurrentLinkedDeque<Instant> window, Instant now, Duration windowDuration) {
        Instant cutoff = now.minus(windowDuration);
        while (true) {
            Instant head = window.peekFirst();
            if (head == null || head.isAfter(cutoff)) {
                break;
            }
            window.pollFirst();
        }
    }

    private int failureThreshold(String provider) {
        return intProperty(provider, "failure-threshold", 5);
    }

    private Duration windowDuration(String provider) {
        return Duration.ofMinutes(intProperty(provider, "window-minutes", 2));
    }

    private Duration openDuration(String provider) {
        return Duration.ofMinutes(intProperty(provider, "open-minutes", 5));
    }

    private int intProperty(String provider, String key, int fallback) {
        return config.getOptionalValue("router.breaker." + provider + "." + key, Integer.class)
                .or(() -> config.getOptionalValue("router.breaker." + key, Integer.class))
                .orElse(fallback);
    }

    public record Status(int recentFailures, int failureThreshold, Duration window, Duration openFor,
                          boolean forcedLocal, Instant forcedUntil) {
    }
}
