package org.acme.camelrouter;

import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

/** vLLM served as "online" through OpenShift AI Models-as-a-Service (or any other OpenShift route). */
@RegisterRestClient(configKey = "vllm")
public interface VllmClient extends OpenAiCompatibleClient {
}
