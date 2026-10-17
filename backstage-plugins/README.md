# Custom Developer Hub plugins

Source for [demo 12](../docs/demos/12-custom-plugin-pod-status.md): a custom plugin pair (backend
+ frontend) that shows pod name + status for an entity's namespace, read straight from the
OpenShift API with their own narrowly-scoped ServiceAccount -- not a reuse of the built-in
Kubernetes plugin. The full, step-by-step "how do I build one of these at all" walkthrough lives in
the demo guide; this folder is the result, kept in the repository so you can diff your own attempt
against a known-working one.

```
backstage-plugins/
  pod-status-backend/    backend plugin: GET /api/pod-status/<namespace> -> [{name, status, ...}]
    deploy/rbac.yaml      the pod-status-reader ServiceAccount + ClusterRole + bindings
  pod-status/             frontend plugin: EntityPodStatusContent, an InfoCard with a pods table
```

Both are plain Backstage plugin packages (`backstage-cli package build`), not yet wired into any
larger Backstage/Developer Hub app workspace -- that wiring (dev app, then export as dynamic
plugins, then `dynamic-plugins.yaml`) is exactly what demo 12 walks through, step by step, because
that process *is* the lesson, not incidental setup.

Quick orientation if you are diffing your own copy:

* `pod-status-backend/src/service/podStatusClient.ts` -- the only file that talks to Kubernetes
  (one `fetch()` call, no SDK). Change this if you want more than name/status/ready/restarts/node.
* `pod-status-backend/src/router.ts` -- the one HTTP route, and the one line
  (`httpAuth.credentials`) that stops this from being an open proxy to your cluster.
* `pod-status/src/components/PodStatusCard/PodStatusCard.tsx` -- reads
  `backstage.io/kubernetes-namespace` off the entity (the same annotation the built-in Kubernetes
  plugin uses), calls the backend above through `discoveryApiRef`, polls every 10s.
* `pod-status-backend/deploy/rbac.yaml` -- apply this to any namespace you want the card to see
  (`oc apply -f backstage-plugins/pod-status-backend/deploy/rbac.yaml`); it is independent of the
  plugin code itself.
