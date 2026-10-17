# Demo 12: build a custom Developer Hub plugin, step by step

**The story:** every other demo in this repository wires up a plugin Red Hat (or the Backstage
community) already built. This one builds one from nothing: a small backend that lists pod name +
status for a namespace, straight from the OpenShift API with its own scoped credentials, and a
frontend card that shows it on a catalog entity's page — then packages both as the **dynamic
plugins** Developer Hub actually loads at runtime, the same mechanism every OCI plugin in
`stack/developer-hub/dynamic-plugins.yaml` already uses.

The finished source is checked in at [`backstage-plugins/`](../../backstage-plugins/) so you can
compare your own run of these steps against a known-working result, or skip straight to "Step 5:
export as dynamic plugins" if you only want the packaging half.

**Duration:** 45-60 minutes, once, on a laptop with Node.js 20+ and Yarn (no OpenShift cluster
needed until Step 4). Entirely a development exercise — there is no "click through a UI" demo
until the very end (Step 7), and even that is five minutes.

```
Step 1-2: a throwaway Backstage dev app (npx @backstage/create-app), for fast local iteration
Step 3: backend plugin   -- lists pods for a namespace, calls the Kubernetes API directly
Step 4: frontend plugin  -- EntityPodStatusContent card, reads backstage.io/kubernetes-namespace
Step 5: RBAC on the real cluster (ServiceAccount + ClusterRole), run both plugins against it
Step 6: export + package as dynamic plugins (@red-hat-developer-hub/cli), push an OCI image
Step 7: wire dynamic-plugins.yaml, restart Developer Hub, see the card on a real entity
```

| Piece | Real or illustrative |
|---|---|
| The backend's call to the Kubernetes API | **real**: one `fetch()`, a Bearer token, `GET /api/v1/namespaces/<ns>/pods` |
| The ServiceAccount/RBAC | **real**: `backstage-plugins/pod-status-backend/deploy/rbac.yaml`, applied to this cluster |
| The dynamic plugin packaging (`@red-hat-developer-hub/cli`) | **real**: the exact, current (RHDH 1.10+) tool and commands Red Hat's own docs use |
| The dev app you build the plugin in | **throwaway**: a scratch Backstage app, not this repository's Developer Hub — RHDH's own container image has no plugin source to develop against |

---

## Before you start

* Node.js 20+, Yarn (Backstage's own prerequisite — `node -v`, `corepack enable` if `yarn` is
  missing)
* `oc` logged in to the platform cluster (only needed from Step 5 onward)
* A container tool for Step 6: `podman` (default) or Docker, plus somewhere to push an image
  (quay.io, an internal registry — anything Developer Hub's pod can later pull from)

---

## Step 1: a throwaway Backstage app to develop in

Red Hat Developer Hub ships as a container image with no plugin *source* inside it — you always
develop a custom plugin in an ordinary Backstage app first, then export the result as a dynamic
plugin for Developer Hub to load. This step creates that scratch app; it is not part of what gets
deployed anywhere.

```bash
npx @backstage/create-app@latest --path /tmp/plugin-dev
cd /tmp/plugin-dev
yarn install
```

**You see:** a standard `packages/app` + `packages/backend` Backstage monorepo. You will add two
new packages to it (`plugins/pod-status-backend`, `plugins/pod-status`) and never touch
`packages/app`/`packages/backend` themselves except to mount the new plugin for local testing.

---

## Step 2: scaffold the backend plugin

```bash
yarn new --select backend-plugin
# id: pod-status
```

**You see:** a new `plugins/pod-status-backend/` package with a starter `src/plugin.ts`,
`src/router.ts` and `src/service/`. Replace its contents with
[`backstage-plugins/pod-status-backend/src/`](../../backstage-plugins/pod-status-backend/src) from
this repository:

* **`src/service/podStatusClient.ts`** — the only file that talks to Kubernetes. One `fetch()`
  call against `GET {clusterUrl}/api/v1/namespaces/{namespace}/pods`, a Bearer token from
  `app-config.yaml`'s `podStatus.token`, and a map from the API's `status.phase` /
  `status.containerStatuses` down to the five fields the frontend table shows
  (`name`, `status`, `ready`, `restarts`, `node`).
* **`src/router.ts`** — one route, `GET /:namespace`. The line
  `await httpAuth.credentials(req, { allow: ['user', 'service'] })` is what turns this from an
  open proxy to your cluster into an actual Backstage-authenticated endpoint — only a signed-in
  user or another plugin's service-to-service call gets past it.
* **`src/plugin.ts`** — `createBackendPlugin`, injects `logger`, `rootConfig` and `httpAuth` via
  `coreServices`, registers the router on `httpRouter`. This shape (`register` → `registerInit` →
  `deps`/`init`) is the "new backend system" every current Backstage/RHDH backend plugin uses.

Add the config block to `/tmp/plugin-dev/app-config.yaml`:

```yaml
podStatus:
  clusterUrl: https://api.<your-cluster-domain>:6443   # or https://kubernetes.default.svc in-cluster
  token: ${POD_STATUS_TOKEN}
  skipTLSVerify: true   # demo only
```

---

## Step 3: wire it into the dev backend and run it

```ts
// packages/backend/src/index.ts
backend.add(import('@internal/plugin-pod-status-backend'));
```

```bash
export POD_STATUS_TOKEN=$(oc whoami -t)      # your own session, just for this local test
yarn start-backend
curl -H "Authorization: Bearer $(curl -s localhost:7007/api/auth/guest/refresh | jq -r .backstageIdentity.token)" \
  http://localhost:7007/api/pod-status/openshift-console
```

**You see:** `{"namespace":"openshift-console","pods":[{"name":"console-...","status":"Running", ...}]}`.
If you get a 502, the error message is the Kubernetes API's own response — almost always a token
or `clusterUrl` problem, not a bug in the 30 lines of `podStatusClient.ts`.

---

## Step 4: scaffold the frontend plugin

```bash
yarn new --select plugin
# id: pod-status
```

Replace the generated `plugins/pod-status/src/` with
[`backstage-plugins/pod-status/src/`](../../backstage-plugins/pod-status/src):

* **`src/components/PodStatusCard/PodStatusCard.tsx`** — `useEntity()` reads the
  `backstage.io/kubernetes-namespace` annotation (the *same* annotation the built-in Kubernetes
  plugin already uses throughout this repository's catalog — reusing it instead of inventing a
  second one is the main design choice here); `useApi(discoveryApiRef)` finds the backend plugin
  by its id (`pod-status`, matching `pluginId` in both `package.json`s) without a hardcoded URL;
  `useInterval(retry, 10_000)` polls every 10 seconds.
* **`src/plugin.ts`** — `createPlugin` + `createComponentExtension` exporting
  `EntityPodStatusContent`. This is the classic Backstage frontend-plugin shape, the same one the
  community plugins already in `dynamic-plugins.yaml` (e.g. the Argo CD plugin) use.

Mount it on an entity page for local testing:

```tsx
// packages/app/src/components/catalog/EntityPage.tsx
import { EntityPodStatusContent } from '@internal/plugin-pod-status';
// inside serviceEntityPage's <EntityLayout>:
<EntityLayout.Route path="/pods" title="Pods">
  <EntityPodStatusContent />
</EntityLayout.Route>
```

```bash
yarn start
```

**You see:** open any catalog entity with a `backstage.io/kubernetes-namespace` annotation in the
dev app's catalog (or add one temporarily) → a **Pods** tab → the table, refreshing every 10s.

---

## Step 5: point it at the real cluster, with its own least-privilege identity

```bash
oc apply -f backstage-plugins/pod-status-backend/deploy/rbac.yaml
```

**Point at:** the file itself — a `ServiceAccount` (`pod-status-reader`) + a `ClusterRole` granting
only `get/list/watch` on `pods` (not `pods/log`, not `pods/exec`) + a `RoleBinding` per namespace
you want visible (`ai-demo`, `ansible-demo`, `rollouts-demo` as examples — add your own). This is
the same "one scoped identity per integration" habit as `rhdh-kubernetes` and
`rhdh-platform-actions` (`stack/developer-hub/rbac.yaml`) and `ansible-postgres-admin`
(`stack/ansible/rbac.yaml`): nothing on this platform shares a single broad credential across
unrelated plugins.

```bash
export POD_STATUS_TOKEN=$(oc get secret pod-status-reader-token -n rhdh -o jsonpath='{.data.token}' | base64 -d)
# update clusterUrl in app-config.yaml to the real API server (or https://kubernetes.default.svc
# once this runs inside the cluster, from Step 7 onward), restart yarn start-backend
```

**You see:** the same **Pods** tab, now showing real pods from your OpenShift cluster, with the
scoped token instead of your own `oc whoami -t` session.

---

## Step 6: export and package as dynamic plugins

Red Hat Developer Hub only loads **dynamic plugins** at runtime — a derived build of your plugin
packaged as an OCI image (or a `.tgz` on a plugin registry). `@red-hat-developer-hub/cli` (the
current tool; it replaced `@janus-idp/cli`'s `export-dynamic-plugin`/`package-dynamic-plugins`
with `plugin export`/`plugin package`) does both steps.

```bash
cd plugins/pod-status-backend
npx @red-hat-developer-hub/cli@latest plugin export
npx @red-hat-developer-hub/cli@latest plugin package --tag quay.io/<you>/pod-status-backend:0.1.0
podman push quay.io/<you>/pod-status-backend:0.1.0

cd ../pod-status
npx @red-hat-developer-hub/cli@latest plugin export
npx @red-hat-developer-hub/cli@latest plugin package --tag quay.io/<you>/pod-status:0.1.0
podman push quay.io/<you>/pod-status:0.1.0
```

**You see:** `plugin export` creates a `dist-dynamic/` folder next to `dist/` in each plugin
package; `plugin package --tag` prints the exact `oci://` reference (with the plugin's package
name after `!`) to put in `dynamic-plugins.yaml` — copy it verbatim, it already matches the
`pluginPackages` declared in `package.json`'s `backstage` block.

---

## Step 7: wire Developer Hub and see it live

Add to `stack/developer-hub/dynamic-plugins.yaml` (same hand-maintained pattern as the Ansible
block added for demo 11 — see that file's comments on why `./deploy.sh rhdh` will not generate
this for you):

```yaml
  - package: 'oci://quay.io/<you>/pod-status-backend:0.1.0!pod-status-backend'
    disabled: false
    pluginConfig:
      podStatus:
        clusterUrl: https://kubernetes.default.svc
        token: ${POD_STATUS_TOKEN}
        skipTLSVerify: true
  - package: 'oci://quay.io/<you>/pod-status:0.1.0!pod-status'
    disabled: false
    pluginConfig:
      dynamicPlugins:
        frontend:
          internal.plugin-pod-status:
            entityTabs:
              - path: /pods
                title: Pods
                mountPoint: entity.page.pods
            mountPoints:
              - mountPoint: entity.page.pods/cards
                importName: EntityPodStatusContent
```

Add `POD_STATUS_TOKEN` to `rhdh-secrets` (same pattern `configure_rhdh()` already uses for
`ANSIBLE_TOKEN`/`ARGOCD_PASSWORD` in `deploy.sh`) from the token created in Step 5, then:

```bash
oc apply -k stack/developer-hub
oc rollout restart deployment/backstage-developer-hub -n rhdh
```

* **Do:** Developer Hub > **Catalog** > any component with a
  `backstage.io/kubernetes-namespace` annotation (e.g. `rag-service`, system `ai-demo`) > the new
  **Pods** tab.
* **You see:** the same table as Step 5's dev app, now served by the actual dynamic plugin running
  inside this Developer Hub instance.
* **Say:** "Every step between here and 'nothing' was ordinary Backstage plugin development — the
  only Developer-Hub-specific part was the last mile: exporting and packaging for dynamic loading."

---

## If something goes wrong

* **`plugin export` fails with a missing `backstage.role`:** both `package.json`s in
  `backstage-plugins/` already set `backstage.role` (`backend-plugin` / `frontend-plugin`) and
  `pluginId` — copy those exact fields if you scaffolded fresh ones that lack them.
* **Backend returns 403 from the Kubernetes API:** check
  `oc auth can-i list pods -n <namespace> --as=system:serviceaccount:rhdh:pod-status-reader` — a
  namespace missing from `deploy/rbac.yaml`'s `RoleBinding`s has no access by design; add a
  `RoleBinding` for it and re-apply.
* **The Pods tab never appears, no error anywhere:** same failure mode as demo 9/11's Argo
  CD/Ansible entries — check
  `oc logs -n rhdh deploy/backstage-developer-hub -c install-dynamic-plugins | grep -A3
  pod-status` for "Merging plugin-specific configuration"; a missing `pluginConfig.dynamicPlugins.
  frontend` block for a custom plugin is the single most common cause.
* **`httpAuth.credentials` throws "Unauthorized" when called from `curl` directly:** expected —
  Step 3's `curl` example first fetches a guest token precisely because the backend refuses
  unauthenticated requests by design (`router.ts`'s whole point).
* **Card shows "No backstage.io/kubernetes-namespace annotation":** that annotation lives on the
  Component, not the System — pick an entity like `rag-service`
  (`stack/developer-hub/catalog-templates/ai-demo.yaml`), not `ai-demo` itself.
