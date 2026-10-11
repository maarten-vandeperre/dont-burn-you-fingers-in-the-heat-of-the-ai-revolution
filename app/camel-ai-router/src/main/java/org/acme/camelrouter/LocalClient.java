package org.acme.camelrouter;

import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

/** The local OpenAI-compatible server: Ollama, llama.cpp, vLLM, Podman Desktop AI Lab, ... */
@RegisterRestClient(configKey = "local")
public interface LocalClient extends OpenAiCompatibleClient {
}
