package org.acme.camelrouter;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.inject.Named;
import org.apache.camel.Exchange;

import java.time.Instant;
import java.util.ArrayDeque;
import java.util.Comparator;
import java.util.Deque;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Bounded in-memory history of every call the router has handled: which backend actually served
 * it (or tried to, before falling back), how long it took, and the exact prompt/response bodies.
 * Backs the admin page ({@code GET /admin}, {@link AdminRoutes}): the table is {@link #listJson},
 * clicking a row fetches {@link #callJson}.
 * <p>
 * Deliberately a simple capped ring buffer in a CDI singleton -- this is demo/operator visibility
 * ("what just happened"), not an audit log or metrics system (that is what Micrometer / Prometheus,
 * wired up in {@link UsageRecorder}, are for). It is lost on restart and never persisted anywhere.
 */
@ApplicationScoped
@Named("callLogStore")
public class CallLogStore {

    static final int CAPACITY = 200;

    private final Deque<CallLogEntry> entries = new ArrayDeque<>(CAPACITY);
    private final ReentrantLock lock = new ReentrantLock();
    private final AtomicLong sequence = new AtomicLong();

    @Inject
    ObjectMapper mapper;

    public CallLogEntry record(String category, String provider, String requestedProvider, String backend,
            boolean forcedLocal, boolean fallback, boolean success, int httpStatus, long durationMs,
            String prompt, String response) {
        CallLogEntry entry = new CallLogEntry(sequence.incrementAndGet(), Instant.now(), category, provider,
                requestedProvider, backend, forcedLocal, fallback, success, httpStatus, durationMs, prompt,
                response);
        lock.lock();
        try {
            if (entries.size() >= CAPACITY) {
                entries.removeFirst();
            }
            entries.addLast(entry);
        } finally {
            lock.unlock();
        }
        return entry;
    }

    /** Newest first. */
    public List<CallLogEntry> recent() {
        lock.lock();
        try {
            return entries.stream().sorted(Comparator.comparingLong(CallLogEntry::id).reversed()).toList();
        } finally {
            lock.unlock();
        }
    }

    public CallLogEntry find(long id) {
        lock.lock();
        try {
            return entries.stream().filter(e -> e.id() == id).findFirst().orElse(null);
        } finally {
            lock.unlock();
        }
    }

    /** The admin page's table: everything except the (potentially large) prompt/response bodies. */
    public String listJson() throws Exception {
        var array = mapper.createArrayNode();
        for (CallLogEntry e : recent()) {
            array.addObject()
                    .put("id", e.id())
                    .put("timestamp", e.timestamp().toString())
                    .put("category", e.category())
                    .put("provider", e.provider())
                    .put("requestedProvider", e.requestedProvider())
                    .put("backend", e.backend())
                    .put("forcedLocal", e.forcedLocal())
                    .put("fallback", e.fallback())
                    .put("success", e.success())
                    .put("httpStatus", e.httpStatus())
                    .put("durationMs", e.durationMs());
        }
        return mapper.writeValueAsString(array);
    }

    /** Full detail for one call (including the prompt/response bodies) -- a clicked admin page row. */
    public String callJson(Exchange exchange) throws Exception {
        String idParam = exchange.getIn().getHeader("id", String.class);
        long id;
        try {
            id = Long.parseLong(idParam);
        } catch (NumberFormatException | NullPointerException ex) {
            throw new IllegalArgumentException("invalid call id: " + idParam);
        }
        CallLogEntry e = find(id);
        if (e == null) {
            throw new NoSuchElementException("no call logged with id " + id + " (it may have scrolled out of the "
                    + "last " + CAPACITY + " calls, or the app restarted)");
        }
        return mapper.writeValueAsString(mapper.createObjectNode()
                .put("id", e.id())
                .put("timestamp", e.timestamp().toString())
                .put("category", e.category())
                .put("provider", e.provider())
                .put("requestedProvider", e.requestedProvider())
                .put("backend", e.backend())
                .put("forcedLocal", e.forcedLocal())
                .put("fallback", e.fallback())
                .put("success", e.success())
                .put("httpStatus", e.httpStatus())
                .put("durationMs", e.durationMs())
                .put("prompt", e.prompt())
                .put("response", e.response()));
    }
}
