package org.acme.camelrouter;

import java.time.Instant;

/**
 * One row in the admin page's call log ({@code GET /admin}, backed by {@link CallLogStore}):
 * which backend actually served (or tried to serve) a {@code /v1/chat/completions} request, how
 * long it took, and -- click the row -- the exact prompt and response bodies.
 */
public record CallLogEntry(
        long id,
        Instant timestamp,
        String category, // local | maas | foundation-model (see ProviderRegistry#category)
        String provider, // the backend that actually handled it: local | openai | anthropic | vllm
        String requestedProvider, // what the caller asked for: auto | local | openai | anthropic | vllm
        String backend, // e.g. "openai/gpt-4o-mini", "local/default"
        boolean forcedLocal, // ProviderHealthTracker had already tripped this provider
        boolean fallback, // the circuitBreaker().onFallback() EIP retried this call on local
        boolean success,
        int httpStatus,
        long durationMs,
        String prompt, // the original request body, exactly as the caller sent it
        String response // the response body (success) or the OpenAI-shaped error body (failure)
) {
}
