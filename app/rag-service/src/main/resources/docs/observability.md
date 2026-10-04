# Logging, tracing and monitoring

Tracing: every service exports OpenTelemetry spans over OTLP to the collector in the tracing-system namespace, which stores them in Tempo. The Envoy sidecars and the vLLM model servers send spans to the same collector, so one trace shows the browser request, the frontend, the rag-service retrieval and generation, the model-router Camel route and the vLLM inference. Traces are visible in the OpenShift console under Observe, Traces, and in Kiali.

Monitoring: the services expose Prometheus metrics on /q/metrics. Istio merges them with the sidecar metrics and OpenShift user workload monitoring scrapes them. Important metrics are ai_router_tokens_total for token usage per model alias and backend, ai_router_requests_total, ai_router_fallbacks_total, rag_generation_seconds for the answer latency and cdc_events_total for the change data capture throughput. A dashboard in the OpenShift console shows them together with the Istio request rates per version.

Logging: all services log JSON to stdout, including the traceId and spanId of the current span, so log lines can be correlated with traces.
