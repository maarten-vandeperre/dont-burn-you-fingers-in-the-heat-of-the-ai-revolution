# Deployment patterns with the service mesh

The rag-service runs in two versions, v1 and v2, behind one Kubernetes service. A DestinationRule defines the subsets v1 and v2 based on the version label, and a VirtualService decides how traffic is split.

Canary release: most traffic goes to the stable version and a small share, for example 10 percent, goes to the new version. The weight is increased step by step while error rates and latency are watched. Argo Rollouts automates the steps for the model-router: 20 percent, pause, 50 percent, pause, 100 percent.

A/B testing: the request decides the version. Requests with the header x-variant set to b go to v2, all other requests go to v1. This compares two prompt styles with real users.

Blue-green deployment: two complete versions run side by side, blue and green. All traffic goes to one of them and the switch is a single change of the VirtualService, with an instant rollback by switching back.

Traffic mirroring, also called shadowing: all requests are served by v1, and a copy of every request is sent to v2 in fire-and-forget mode. Responses of v2 are discarded, so a new version can be tested with production traffic without any user impact.
