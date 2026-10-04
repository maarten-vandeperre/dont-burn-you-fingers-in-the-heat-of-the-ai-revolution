# Models-as-a-Service

Models-as-a-Service (MaaS) in OpenShift AI publishes self hosted models behind one gateway. Clients authenticate with MaaS API keys and every key belongs to a subscription that defines a token rate limit per model, for example 5000 tokens per minute on the free subscription and 100000 tokens per minute on the premium subscription.

The gateway is built on Red Hat Connectivity Link (Kuadrant). Authorino validates the API key and Limitador enforces the token quota. Token usage is counted per model and per subscription and shows up in the OpenShift AI observability dashboard.

Two small models are published in this demo: gemma-3-270m-it, the smallest Gemma 3 model with 270 million parameters, and qwen3-0-6b, the smallest Qwen3 model with 0.6 billion parameters. Both run on vLLM on CPU, which is enough for demos but slow compared to a GPU.

The models are reached with path based routing: https://maas.apps-domain/maas-models/model-name/v1/chat/completions, using the OpenAI chat completions API.
