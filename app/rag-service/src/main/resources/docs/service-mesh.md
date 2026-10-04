# Service mesh, mTLS and authorization

OpenShift Service Mesh 3 is based on Istio and managed by the Sail operator. Every pod in the ai-demo namespace gets an Envoy sidecar. The sidecars encrypt all traffic between services with mutual TLS. A PeerAuthentication in STRICT mode rejects any plaintext connection, so a pod outside the mesh cannot call the demo services directly.

Mutual TLS also gives every workload a cryptographic identity based on its service account, for example cluster.local/ns/ai-demo/sa/frontend. AuthorizationPolicies use those identities to decide who can access who.

The namespace starts with a deny-all policy. Explicit ALLOW policies then open the paths that are needed: the ingress gateway may call the frontend, the frontend may call the rag-service, the orders-service and the projection-service, the rag-service may call the model-router, and only the projection-service may connect to MongoDB. The frontend calling the model-router directly is denied with HTTP 403 RBAC: access denied.

Kiali visualizes the mesh: the traffic graph, the mTLS lock icons, request rates, error rates and the configuration validation of VirtualServices and DestinationRules.
