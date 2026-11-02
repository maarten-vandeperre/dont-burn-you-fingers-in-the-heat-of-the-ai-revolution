package org.acme.camelrouter;

import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

/** OpenAI, or any OpenAI-compatible proxy sitting where OpenAI normally is (base URL overridable). */
@RegisterRestClient(configKey = "openai")
public interface OpenAiClient extends OpenAiCompatibleClient {
}
