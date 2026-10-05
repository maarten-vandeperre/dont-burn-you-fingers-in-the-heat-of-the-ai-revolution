# Service mesh: change the manifests yourself

Demos [2](02-mesh-security.md), [3](03-deployment-patterns.md) and the menu parts of
[7](07-coffee-shop.md) all change the same objects in namespace `ai-demo`. The helper commands
(`./deploy.sh app probe`, `app pattern`, `app menu`) only apply a YAML file. This page is those
demos with the file, the field and the `oc apply` written out, so you can make each change
yourself.

Work from the repository root. You need `oc` logged in to the cluster where `./deploy.sh app deploy`
has already run.

```bash
oc project ai-demo
./deploy.sh app probe          # five lines, each starting with OK
./deploy.sh app pattern reset  # rag-service on v1
./deploy.sh app menu reset     # coffee menu on v1, no faults
```

Every change below is live as soon as `oc apply` returns. No image build, no pod restart: the
Envoy sidecar next to each app reads the new object.

## Where each decision lives

A call inside `ai-demo` is decided by four files. Read them in this order; that is also the order
the mesh evaluates them.

| Question | File | Object | Field you edit |
|---|---|---|---|
| Is this namespace in the mesh? | `app/deploy/base/namespace.yaml` | Namespace `ai-demo` | labels `istio-discovery`, `istio-injection` |
| Does the caller have a mesh certificate? | `app/deploy/mesh/peer-authentication.yaml` | PeerAuthentication `default` | `spec.mtls.mode` |
| Which service account may call this workload? | `app/deploy/mesh/authorization-policies.yaml` | one AuthorizationPolicy per arrow | `principals`, `methods`, `paths`, `ports` |
| Which version, header or fault applies? | `app/deploy/patterns/*.yaml` | VirtualService `rag-service` or `coffee-menu` | `route`, `weight`, `match`, `mirror`, `fault` |

The version label that a route points at is declared once, in two places that have to agree:

| Piece | File | What it says |
|---|---|---|
| Pods of version v2 | `app/deploy/base/rag-service.yaml` (and `coffee-menu.yaml`) | Deployment `rag-service-v2`, label `version: v2`, env `APP_VERSION=v2` |
| Subset name `v2` | `app/deploy/mesh/destination-rules.yaml` | `subsets[].labels.version: v2` on host `rag-service` |
| Traffic to that subset | `app/deploy/patterns/canary.yaml` (or blue, green, ab, mirror, reset) | `destination.subset: v2` |

The Kubernetes Service `rag-service` selects every pod with `app: rag-service`, v1 and v2 together.
The VirtualService is what splits them. The same shape is used for `coffee-menu`.

Identities are service accounts, listed in `app/deploy/base/serviceaccounts.yaml`. A principal in
a policy is that name written as:

```text
cluster.local/ns/ai-demo/sa/<service-account-name>
```

`sa/rag-service` stays valid when the pods are rescheduled. The mesh reads the name from the
certificate it put in the sidecar.

## How to apply a file

Mesh files under `app/deploy/mesh/` have no `namespace` of their own (Kustomize adds `ai-demo`
when the whole folder is applied). Pass the namespace on the command:

```bash
oc apply -f app/deploy/mesh/authorization-policies.yaml -n ai-demo
oc apply -f app/deploy/mesh/peer-authentication.yaml -n ai-demo
```

Pattern files already contain `namespace: ai-demo`, so this is enough:

```bash
oc apply -f app/deploy/patterns/canary.yaml
```

`oc apply` updates the object whose `metadata.name` is already in the cluster. Keep that name.
A second VirtualService named anything else leaves `rag-service` in place, and the sidecars keep
using it.

Applying a file updates the objects that are still in the file. Deleting a YAML document and
applying again leaves the old object in the cluster. Remove one object with:

```bash
oc delete authorizationpolicy rag-from-frontend -n ai-demo
```

Put a change back by restoring the file and applying it again. These three commands restore the
demo baseline from git:

```bash
git checkout -- app/deploy/mesh/authorization-policies.yaml app/deploy/mesh/peer-authentication.yaml
oc apply -f app/deploy/mesh/authorization-policies.yaml -n ai-demo
oc apply -f app/deploy/mesh/peer-authentication.yaml -n ai-demo
oc apply -f app/deploy/patterns/reset.yaml
oc apply -f app/deploy/patterns/menu-reset.yaml
```

`./deploy.sh app deploy` reapplies every mesh object. `./deploy.sh app pattern reset` and
`./deploy.sh app menu reset` reapply only the two VirtualServices.

If you created the Argo CD app (`./deploy.sh app gitops`), it self-heals from git. It leaves
`VirtualService/rag-service` routes alone, and it puts AuthorizationPolicies and
`VirtualService/coffee-menu` back within a minute. For the exercises on those objects, turn
self-heal off and on again afterwards:

```bash
oc patch application ai-demo -n openshift-gitops --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
# ...exercises...
oc patch application ai-demo -n openshift-gitops --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}'
```

Skip the patch when `oc get application ai-demo -n openshift-gitops` says NotFound.

---

## 1. Who may call whom

Open `app/deploy/mesh/authorization-policies.yaml`. The comment at the top is the diagram. Each
`---` block is one policy. The `selector` is the workload that **receives** the call. `principals`
is the service account that **sends** it.

| Policy name | Selector (callee) | Allowed caller | Limited to |
|---|---|---|---|
| `deny-all` | every pod in `ai-demo` | nobody | empty `spec`: an allow policy with no rules allows nothing, so every other policy is an exception |
| `gateway-from-router` | `istio: ai-demo-gateway` | anyone who can reach the gateway pod | the OpenShift router, after edge TLS |
| `frontend-from-gateway` | `app: frontend` | `sa/ai-demo-gateway` | |
| `rag-from-frontend` | `app: rag-service` | `sa/frontend` | `GET` and `POST` on `/api/rag/*` |
| `model-router-from-rag` | `app: model-router` | `sa/rag-service`, `sa/coffee-shop` | paths `/v1/*` |
| `orders-from-frontend` | `app: orders-service` | `sa/frontend` | |
| `projection-from-frontend` | `app: projection-service` | `sa/frontend`, `sa/coffee-shop` | method `GET` |
| `mongodb-from-projection` | `app: mongodb` | `sa/projection-service` | TCP port `27017` |
| `coffee-shop-from-gateway` | `app: coffee-shop` | `sa/ai-demo-gateway` | |
| `coffee-menu-from-coffee-shop` | `app: coffee-menu` | `sa/coffee-shop` | `GET` on `/api/menu` and `/api/menu/*` |

`deny-all` is the whole security model: add a caller by adding a principal, remove a caller by
deleting that line. There is no IP address in the file.

Confirm the cluster matches the file:

```bash
oc get peerauthentication,authorizationpolicy,destinationrule,virtualservice -n ai-demo
```

### 1a. Allow the frontend to call the model router

The probe calls `GET http://model-router:8080/v1/models` with the frontend identity. The policy
`model-router-from-rag` does not list `sa/frontend`, so the sidecar answers `403 RBAC: access denied`.

In `model-router-from-rag`, the `principals` list is:

```yaml
            principals:
              - "cluster.local/ns/ai-demo/sa/rag-service"
              - "cluster.local/ns/ai-demo/sa/coffee-shop"
```

Add a third item, indented the same way as the `sa/coffee-shop` line:

```yaml
            principals:
              - "cluster.local/ns/ai-demo/sa/rag-service"
              - "cluster.local/ns/ai-demo/sa/coffee-shop"
              - "cluster.local/ns/ai-demo/sa/frontend"
```

Leave `paths: ["/v1/*"]` as it is: the probe URL sits under `/v1/`. Apply the whole file (every
policy is in it; apply updates them all):

```bash
oc apply -f app/deploy/mesh/authorization-policies.yaml -n ai-demo
./deploy.sh app probe
```

The model-router line flips from `OK` / `expected=deny` / `403 RBAC: access denied` to `??` and
`HTTP 200`. In the demo UI, **Mesh access** > **Run probe** shows that row as **unexpected**.
The other four rows stay `OK`: you added one principal on one policy.

In Kiali: **Istio Config** > namespace `ai-demo` > `model-router-from-rag`. The YAML on screen is
the object you just applied. **Workloads** > `model-router` > **Inbound Metrics**, grouped by
response code, shows the new calls as 200 from `frontend` instead of 403.

Revert: delete the `sa/frontend` line, save, and apply the same file again. `./deploy.sh app probe`
returns to five `OK` lines.

### 1b. Narrow an allow to one path

`rag-from-frontend` allows every path under `/api/rag/`. The probe calls
`GET /api/rag/version`. Change only the `paths` list of that policy:

```yaml
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/api/rag/ask"]
```

```bash
oc apply -f app/deploy/mesh/authorization-policies.yaml -n ai-demo
./deploy.sh app probe
```

The rag-service line is now `??` with `403`. `/api/rag/ask` would still be allowed; the probe
does not call it. Put `paths: ["/api/rag/*"]` back and apply again.

### 1c. Require certificates

`app/deploy/mesh/peer-authentication.yaml` applies to the whole namespace (it has no selector):

```yaml
spec:
  mtls:
    mode: STRICT
```

`STRICT` refuses a connection that arrives without a mesh certificate. Check it from a pod that
is outside the mesh:

```bash
./deploy.sh app mtls
```

Each of frontend, rag-service and model-router prints
`rejected (plaintext not allowed, STRICT mTLS)`.

To see the field take effect, set `mode: PERMISSIVE`, apply, and run the check again:

```bash
oc apply -f app/deploy/mesh/peer-authentication.yaml -n ai-demo
./deploy.sh app mtls
```

The same calls now print `HTTP 403`. The connection is accepted, and `deny-all` plus the allow
policies still refuse a caller that has no service-account certificate. Set `mode: STRICT` again
and apply. `./deploy.sh app mtls` goes back to rejected plaintext.

---

## 2. Release rag-service by editing the VirtualService

Two Deployments run the same image. v1 answers in a short paragraph (`RAG_TOP_K=3`). v2 answers
in bullet points with citations (`RAG_TOP_K=5`). Both are already up. Editing a Deployment is
how you ship a new pod; editing the VirtualService is how you send users to it.

`app/deploy/mesh/destination-rules.yaml` names the subsets. You normally leave it alone:

```yaml
spec:
  host: rag-service
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

`subset: v2` in a VirtualService means "pods with label `version: v2`". That label is on the pod
template in `app/deploy/base/rag-service.yaml`. If the two strings differ, the subset is empty and
traffic to it fails.

The live route is a single object, `VirtualService/rag-service`. Each file in
`app/deploy/patterns/` is a complete copy of that object. Apply one file and it replaces
`spec.http`. Watch the result with:

```bash
oc get virtualservice rag-service -n ai-demo -o yaml
./deploy.sh app traffic 200          # no header
./deploy.sh app traffic 50 b         # sends header x-variant: b
```

The traffic command prints how many responses came from `rag v1` and `rag v2`. In the demo UI,
tab **Traffic patterns** > **Send traffic** shows the same split. In Kiali, graph type
**Versioned app graph**, namespace `ai-demo`, **Display** > **Traffic Distribution**.

`./deploy.sh app pattern <name>` applies these files for you. `pattern canary 25` rewrites the
weights and applies the result. The sections below are that command, done by hand.

### 2a. Canary: two weights

Open `app/deploy/patterns/canary.yaml`. The whole route is:

```yaml
  http:
    - route:
        - destination: {host: rag-service, subset: v1}
          weight: 90
        - destination: {host: rag-service, subset: v2}
          weight: 10
```

The two `weight` values are percentages of requests. They have to add up to 100. `subset` has to
be `v1` or `v2` as declared in the DestinationRule.

Apply the file as it is (90% v1, 10% v2):

```bash
oc apply -f app/deploy/patterns/canary.yaml
./deploy.sh app traffic 200
```

About 180 responses are `rag v1` and about 20 are `rag v2`. Weights are probabilities, so a short
run wobbles; 200 requests is enough to see the split.

For a 30% canary, change the two numbers in the file and apply again:

```yaml
        - destination: {host: rag-service, subset: v1}
          weight: 70
        - destination: {host: rag-service, subset: v2}
          weight: 30
```

```bash
oc apply -f app/deploy/patterns/canary.yaml
./deploy.sh app traffic 200
```

About 140 / 60. Put the file back to 90 and 10 when you are done (`git checkout -- app/deploy/patterns/canary.yaml`).
The helper `./deploy.sh app pattern canary <n>` looks for the literals `weight: 90` and
`weight: 10` in that file. After you have changed those numbers, either restore them or keep
using `oc apply` on the file you edited.

### 2b. A/B: a header match above the default route

Open `app/deploy/patterns/ab.yaml`. `spec.http` is a list. The sidecar uses the first entry that
matches.

```yaml
  http:
    - match:
        - headers:
            x-variant:
              exact: b
      route:
        - destination: {host: rag-service, subset: v2}
    - route:
        - destination: {host: rag-service, subset: v1}
```

The first entry sends requests with header `x-variant: b` to v2. The second entry has no
`match`, so it catches everyone else and sends them to v1. The header rule has to stay above the
default. Swap the two entries and every request, header or not, hits v1, because the default
matches first.

```bash
oc apply -f app/deploy/patterns/ab.yaml
./deploy.sh app traffic 50        # all rag v1
./deploy.sh app traffic 50 b      # all rag v2
```

In the demo UI, tab **Ask (RAG)**, tick **send x-variant: b**, then **Ask**. The answer is bullet
points with `[1]` citations and the badge `rag v2`.

To match a different header, change `x-variant` and `exact: b` together. The traffic command's
second argument only sends `x-variant`.

### 2c. Blue-green: one subset, switched in one apply

`app/deploy/patterns/blue.yaml` sends everyone to v1. `green.yaml` is the same object with
`subset: v2`. Blue also sets a response header so a client can see which side is live:

```yaml
    - route:
        - destination: {host: rag-service, subset: v1}
      headers:
        response:
          set:
            x-deployment-color: blue
```

In `green.yaml` the subset is `v2` and the header value is `green`.

```bash
oc apply -f app/deploy/patterns/blue.yaml
./deploy.sh app traffic 50        # rag v1: 50
oc apply -f app/deploy/patterns/green.yaml
./deploy.sh app traffic 50        # rag v2: 50
```

Both Deployments stay ready. The next apply is the rollback.

### 2d. Mirroring: the caller still hears v1

Open `app/deploy/patterns/mirror.yaml`:

```yaml
    - route:
        - destination: {host: rag-service, subset: v1}
          weight: 100
      mirror:
        host: rag-service
        subset: v2
      mirrorPercentage:
        value: 100.0
```

`route` is the answer the caller receives. `mirror` is a copy sent to v2; the mesh discards v2's
response. `mirrorPercentage.value` is how much of the traffic is copied (`100.0` means all of it).

```bash
oc apply -f app/deploy/patterns/mirror.yaml
./deploy.sh app traffic 30
oc logs deploy/rag-service-v2 -n ai-demo -c app --tail=20
```

The traffic summary is entirely `rag v1`. The v2 log contains
`version request served by rag-service v2` for the copies. In Kiali: **Workloads** >
`rag-service-v2` > **Inbound Metrics**.

### 2e. Back to a single version

`app/deploy/patterns/reset.yaml` and `app/deploy/mesh/rag-virtualservice.yaml` are the same route:
100% to subset v1. Either file restores the baseline.

```bash
oc apply -f app/deploy/patterns/reset.yaml
./deploy.sh app traffic 50        # rag v1: 50
```

---

## 3. Release and break the coffee menu the same way

`coffee-menu` is a second pair of Deployments behind one Service. The DestinationRule subsets are
the second document in `app/deploy/mesh/destination-rules.yaml`. The live route is
`VirtualService/coffee-menu`. Files are `app/deploy/patterns/menu-*.yaml`.

The coffee shop calls the menu through the mesh. It also has its own timeout, retry, circuit
breaker and cached menu (`MenuService.java`). The probe on the coffee shop skips that protection
and shows what the mesh actually did.

```bash
HOST=$(oc get route coffee -n ai-demo -o jsonpath='https://{.spec.host}')
curl -sk "$HOST/api/menu/probe?n=40" | jq '{versions, errors, p50Ms, p95Ms}'
```

Or, in the coffee shop UI, tab **Menu & resilience** > **Probe coffee-menu**.

### 3a. Canary, blue-green, mirror

Same fields as rag-service, on host `coffee-menu`.

| What you want | File | Fields |
|---|---|---|
| 80% v1, 20% v2 | `menu-canary.yaml` | `weight: 80` on subset v1, `weight: 20` on subset v2 |
| Everyone on v1 | `menu-blue.yaml` | `subset: v1`, response header `x-deployment-color: blue` |
| Everyone on v2 (new prices, mocha on the menu) | `menu-green.yaml` | `subset: v2`, header `green` |
| v1 answers, v2 receives a copy | `menu-mirror.yaml` | `mirror.subset: v2`, `mirrorPercentage.value: 100.0` |
| v1, no mirror, no fault | `menu-reset.yaml` | one destination, subset v1 |

Apply, then probe:

```bash
oc apply -f app/deploy/patterns/menu-canary.yaml
curl -sk "$HOST/api/menu/probe?n=40" | jq '{versions, errors, p95Ms}'
```

`versions` is about `{"v1": 32, "v2": 8}`. For a different split, edit the two weights so they
still add up to 100, and apply the same file. `./deploy.sh app menu canary <n>` rewrites the
literals `weight: 80` and `weight: 20` before it applies; restore those numbers if you want the
helper to keep working.

```bash
oc apply -f app/deploy/patterns/menu-green.yaml
```

The next order in the coffee shop is priced from menu v2 (the quote badge says `menu v2`).
`menu-blue.yaml` switches it back.

```bash
oc apply -f app/deploy/patterns/menu-mirror.yaml
curl -sk "$HOST/api/menu/probe?n=20" | jq .versions
oc logs deploy/coffee-menu-v2 -n ai-demo -c app --tail=10
```

The probe reports only v1. The v2 pod log shows the mirrored calls.

### 3b. Delay a percentage of calls

Open `app/deploy/patterns/menu-delay.yaml`. The fault sits on the same route that still goes to v1:

```yaml
  http:
    - fault:
        delay:
          fixedDelay: 3s
          percentage:
            value: 50.0
      route:
        - destination: {host: coffee-menu, subset: v1}
```

`fixedDelay` is how long the sidecar waits before forwarding. `percentage.value` is how many
requests wait (`50.0` is half). The shop itself gives up at 1.5 seconds and uses its cached menu,
which is why ordering still finishes.

```bash
oc apply -f app/deploy/patterns/menu-delay.yaml
curl -sk "$HOST/api/menu/probe?n=40" | jq '{versions, errors, p50Ms, p95Ms}'
```

`p95Ms` is around 3000. Errors stay empty: the calls succeed, they are slow. Change `value: 50.0`
to `value: 100.0` and apply again to delay every call. `fixedDelay: 3s` can be `1s`, `5s`, and
so on.

Place an order in the coffee shop while this is applied. The badge on the quote says `menu cache`
when the live call misses the 1.5 second timeout.

### 3c. Fail a percentage of calls

Open `app/deploy/patterns/menu-abort.yaml`:

```yaml
    - fault:
        abort:
          httpStatus: 503
          percentage:
            value: 30.0
      route:
        - destination: {host: coffee-menu, subset: v1}
```

`httpStatus` is the status the sidecar returns. The request is not forwarded to the menu pod.
`percentage.value` is how often.

```bash
oc apply -f app/deploy/patterns/menu-abort.yaml
curl -sk "$HOST/api/menu/probe?n=40" | jq '{versions, errors, p95Ms}'
```

`errors` shows about 12 times `503` out of 40. In Kiali the edge to coffee-menu goes red on the
503s. The coffee shop retries and, when that is not enough, serves the cached menu, so
**Order** still returns a quote.

Set `value: 100.0` and apply to fail every call. Ordering keeps working from the cache, and the
probe is 100% `503`.

### 3d. Clear the fault

Faults live only on the VirtualService. Replacing it with the reset file removes them:

```bash
oc apply -f app/deploy/patterns/menu-reset.yaml
curl -sk "$HOST/api/menu/probe?n=20" | jq '{versions, errors, p95Ms}'
```

`versions` is all v1, `errors` is empty, `p95Ms` is well under a second.

---

## 4. What the helper commands apply

Use these when you want the shortcut. Each one is an `oc apply` of a file above.

| Command | File it applies |
|---|---|
| `./deploy.sh app pattern reset` | `app/deploy/patterns/reset.yaml` |
| `./deploy.sh app pattern canary 10` | `canary.yaml`, with the two weights rewritten to 90 and 10 |
| `./deploy.sh app pattern canary 25` | same file, weights rewritten to 75 and 25 |
| `./deploy.sh app pattern ab` | `ab.yaml` |
| `./deploy.sh app pattern blue` / `green` | `blue.yaml` / `green.yaml` |
| `./deploy.sh app pattern mirror` | `mirror.yaml` |
| `./deploy.sh app menu reset` | `menu-reset.yaml` |
| `./deploy.sh app menu canary 20` | `menu-canary.yaml`, weights rewritten to 80 and 20 |
| `./deploy.sh app menu blue` / `green` / `mirror` | `menu-blue.yaml` / `menu-green.yaml` / `menu-mirror.yaml` |
| `./deploy.sh app menu delay 50` | `menu-delay.yaml`, `percentage.value` rewritten to `50.0` |
| `./deploy.sh app menu abort 30` | `menu-abort.yaml`, `percentage.value` rewritten to `30.0` |
| `./deploy.sh app deploy` | the whole of `app/deploy/`, including `mesh/` (policies, DestinationRules, and the baseline VirtualServices) |

`pattern canary` and `menu canary` / `delay` / `abort` pass the edited YAML to `oc apply` on
stdin. They do not save the new numbers into the file.

---

## If a change seems to do nothing

* **Probe or traffic is unchanged after apply.** `oc get virtualservice rag-service -n ai-demo -o yaml`
  (or `coffee-menu`, or the AuthorizationPolicy you edited). If the file's contents are not there,
  the apply went to another namespace: run it again with `-n ai-demo`. If Argo CD is self-healing,
  see the patch at the top of this page.
* **Canary helper ignores your weights.** It only replaces `weight: 90` and `weight: 10` in
  `canary.yaml` (80 and 20 in `menu-canary.yaml`). Restore the file or apply it yourself.
* **All traffic stays on v1 after an A/B apply.** The header match has to be the first item under
  `spec.http`.
* **Subset gets no pods.** `oc get pods -n ai-demo -l app=rag-service --show-labels` and compare
  `version` with `subsets[].labels.version` in `destination-rules.yaml`.
* **Pods are 1/1, with no `istio-proxy`.** The namespace labels in `app/deploy/base/namespace.yaml`
  were missing when the pod started. `oc apply -f app/deploy/base/namespace.yaml` and
  `oc rollout restart deploy -n ai-demo`.
* **You want the demo exactly as in git.** `./deploy.sh app deploy`, then
  `./deploy.sh app pattern reset` and `./deploy.sh app menu reset`.
