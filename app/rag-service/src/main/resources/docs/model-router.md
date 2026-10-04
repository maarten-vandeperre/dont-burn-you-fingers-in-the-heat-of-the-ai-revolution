# Model router with Apache Camel

The model-router is an OpenAI compatible endpoint built with Apache Camel on Quarkus. Applications only know one base URL and four model aliases: gemma, qwen, openai and auto.

A Camel content based router reads the alias and sends the request to the right backend: gemma and qwen go to the Models-as-a-Service gateway with the MaaS API key, openai goes to the OpenAI API. The alias auto prefers the local qwen model behind a circuit breaker and falls back to OpenAI when the local model is slow, failing or the circuit is open.

Because the API keys live only in the router, applications never handle credentials, and swapping a model or a provider is a change in one route instead of in every application. The router records token usage per alias and backend and adds the header x-model-backend to every response.
