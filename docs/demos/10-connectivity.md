# Demo 10: Connectivity — Service Interconnect, Service Mesh, Connectivity Link

**The story:** three different connectivity problems, three different Red Hat technologies, each
solving the one the others don't:

* **Red Hat Service Interconnect** (Skupper) connects a service that lives *outside* this cluster —
  a "legacy" database in its own isolated network, no VPN, no public endpoint, no firewall hole for
  the database port itself — to a workload running *inside* it.
* **Service Mesh** (demo 2, not repeated here) controls access *between services already on this
  cluster*, by workload identity, with mutual TLS.
* **Red Hat Connectivity Link** (Kuadrant) controls access *from outside this cluster, by API
  consumer* — and gives platform engineering a Developer Portal with self-service signup, approval
  and plan-tiered rate limits, independent of how the Gateway or the mesh were built.

Put together: a partner developer can get access to a read-only API backed by a service that is
itself *also* talking to a database that was never deployed on this cluster, all without a VPN,
without the platform team hand-issuing credentials, and without the API owner needing platform-admin
rights to set their own rate limit tiers.

**Duration:** 20 minutes (8 Part A, 2 Part B, 10 Part C). Each part also works on its own.

```
Part A: legacy-datacenter namespace (isolated)          Part C: ai-demo namespace (the mesh)
  NetworkPolicy (deny-all except Skupper's own ports)      partner-gateway (Gateway API, istio class)
  PostgreSQL "legacy-inventory-db" + seed data                -> HTTPRoute partner-orders-api
  Skupper Site (linkAccess: default)                              -> orders-service (existing, STRICT mTLS)
    -> Connector legacy-inventory-db                        AuthPolicy: API key per caller
                      |                                      PlanPolicy: trial (20/day) / partner (1000/day)
                      | Skupper Link (mTLS, AccessGrant/Token)  APIProduct: Dev Portal catalog entry
                      v                                      APIKeyRequest/APIKeyApproval: the persona workflow
connectivity-demo namespace (platform site)
  Skupper Site -> Listener legacy-inventory-db (local proxy Service, same name, same port)
```

| Piece | Real or mocked |
|---|---|
| The "legacy" database, its isolation, and the Skupper link crossing it | **real**: a separate namespace with its own `NetworkPolicy` deny-all, a real PostgreSQL pod, a real Skupper `Site`/`Connector`/`Listener`/`Link` |
| "No VPN, no public endpoint" | **real**: proven negatively too — a Pod given the database's actual pod IP cannot reach it; only the Skupper-provided Service name can |
| The partner Gateway, HTTPRoute, AuthPolicy, PlanPolicy, APIProduct | **real**: live Gateway API + Kuadrant objects on this cluster, reconciled by the Connectivity Link (Kuadrant) operator |
| The self-service signup / approval workflow | **real**: `devportal.kuadrant.io` `APIKeyRequest`/`APIKeyApproval`/`APIKey` CRDs |
| Plan-tiered rate limiting (trial vs. partner) | **configured, not live-enforced on this cluster** — see "If something goes wrong" |

---

## Before you start

1. Needs the platform stack and the demo app already deployed (`orders-service` is the API this
   demo exposes to partners):
   ```bash
   ./deploy.sh stack          # if not already done
   ./deploy.sh app deploy     # if not already done
   ```
2. Install Service Interconnect and turn on Connectivity Link's Developer Portal component (both
   one-time, idempotent):
   ```bash
   ./deploy.sh connectivity setup
   ```
3. Build the legacy site, link it to the platform, and expose the partner API:
   ```bash
   ./deploy.sh connectivity legacy          # namespace, NetworkPolicies, PostgreSQL, seed data, Skupper Site
   ./deploy.sh connectivity link            # platform site + Skupper Link between the two
   ./deploy.sh connectivity psql-check      # proves it, both ways (see Part A)
   ./deploy.sh connectivity partner-api deploy
   ./deploy.sh connectivity urls
   ```
4. Browser tabs: **OpenShift console** (Networking > NetworkPolicies in `legacy-datacenter`;
   Workloads > Secrets in `ai-demo` for Part C); **Kiali** (namespace `ai-demo`, this demo adds one
   more edge into the mesh — `partner-gateway` calling `orders-service`).
5. Start clean before a live run: `./deploy.sh connectivity partner-api reset` (removes any
   previous signups/approvals; the Gateway and policies stay).

---

## Part A: Red Hat Service Interconnect — the legacy database (8 minutes)

**A1. The problem.**
* **Say:** "`legacy-inventory-db` lives in its own namespace with a deny-all `NetworkPolicy` —
  think of it as a database in a data center, or another cloud, that nobody is going to open a
  VPN tunnel or a public load balancer for, just so one cluster can read it."
* **Do:** OpenShift console > **Networking > NetworkPolicies**, project `legacy-datacenter`.
* **You see:** three policies — `deny-all-ingress` (blocks everything by default),
  `allow-skupper-router-ports-only` (opens only the two ports Skupper's own router needs:
  55671 inter-router, 45671 edge), `allow-postgres-from-same-namespace` (Postgres only answers
  pods already inside this namespace — the Skupper router and the seed Job, nothing from outside).
* **Say:** "Nothing about this NetworkPolicy knows or cares that Skupper exists specifically — it's
  a completely ordinary, narrow firewall. Skupper's own mutual TLS is what makes the one hole we
  did open safe to leave open."

**A2. The link, and the virtual service it creates.**
* **Do:**
  ```bash
  oc get site -n legacy-datacenter; oc get site -n connectivity-demo
  oc get link -n connectivity-demo
  oc get connector -n legacy-datacenter
  oc get listener -n connectivity-demo
  ```
* **You see:** two `Ready` Sites (one per namespace), a `Ready` `Link` between them, a `Connector`
  on the legacy side pointing at the real `legacy-inventory-db` Pod (`selector: app=legacy-inventory-db`),
  and a `Listener` on the platform side with the exact same name and port — which is what actually
  creates a local ClusterIP Service called `legacy-inventory-db` in `connectivity-demo`.
* **Say:** "A `Connector` and a `Listener` agree on a `routingKey`, not a namespace or a cluster.
  Any pod in `connectivity-demo` that resolves `legacy-inventory-db:5432` is actually talking
  through an mTLS tunnel to the real Postgres pod over in the isolated namespace — the DNS name
  is identical on both sides on purpose, so nothing in a real application would need to change."

**A3. Prove it — both ways.**
* **Do:**
  ```bash
  ./deploy.sh connectivity psql-check
  ```
* **You see:** first, a `SELECT * FROM parts` run from a Pod in `connectivity-demo` succeeds —
  2 rows, `widget-7` and `bracket-12` — through the Skupper virtual service. Then, the *same*
  database's actual pod IP is tried directly from the same namespace, and it times out.
* **Say:** "Same namespace, same intent — reach the database — two different results, because one
  path goes through the Skupper link and the other tries to bypass it. That's the NetworkPolicy
  working exactly as designed: Skupper gets in, nothing else does."

---

## Part B: Service Mesh (2 minutes — pointer, not a new demo)

* **Say:** "This demo adds two new ways *into* and *across* the platform — a cross-network link and
  a partner-facing Gateway. Neither one touches what's already true *inside* the mesh: STRICT mTLS
  and per-identity `AuthorizationPolicy` rules, which is demo 2 in full
  ([`02-mesh-security.md`](02-mesh-security.md), manifests in [`service-mesh.md`](service-mesh.md))."
* **Do:** Kiali > **Traffic Graph** > namespace `ai-demo`, after running Part C below.
* **You see:** a new edge, `partner-gateway -> orders-service`, with the same lock icon (mTLS) as
  every other edge in the graph — the partner Gateway is just one more mesh-aware identity, exactly
  like `ai-demo-gateway` or `frontend`.
* **Say:** "The mesh doesn't know or care that Connectivity Link exists further out. The new Gateway
  still needed an explicit `AuthorizationPolicy` grant to call `orders-service` — same deny-all
  model as everything else in demo 2, just one more identity added to it
  ([`mesh-authorization.yaml`](../../stack/connectivity/partner-api/mesh-authorization.yaml))."

---

## Part C: Red Hat Connectivity Link — personas, access and rate limits (10 minutes)

**C1. Four personas, one API.**
* **Say:** "`orders-service` already exists — it's the same backend demo 2 and the coffee shop use
  internally. The platform engineering story here is about the four different people (or teams)
  who each own one piece of exposing it externally, and never need each other's permissions to do
  their part:"

  | Persona | Owns | Object(s) |
  |---|---|---|
  | **Platform engineer** | the Gateway itself, TLS, the Route, the mesh grant letting the Gateway reach `orders-service` | [`gateway.yaml`](../../stack/connectivity/partner-api/gateway.yaml), [`route.yaml`](../../stack/connectivity/partner-api/route.yaml), [`mesh-authorization.yaml`](../../stack/connectivity/partner-api/mesh-authorization.yaml) |
  | **API/app team** (owns `orders-service`) | the HTTPRoute, the auth scheme, the plan tiers and their limits | [`httproute.yaml`](../../stack/connectivity/partner-api/httproute.yaml), [`auth-policy.yaml`](../../stack/connectivity/partner-api/auth-policy.yaml), [`plan-policy.yaml`](../../stack/connectivity/partner-api/plan-policy.yaml) |
  | **Partner developer** (external consumer) | asking for a key, at a tier, for a reason | `APIKeyRequest` (self-service, created by `connectivity.sh partner_api_signup`) |
  | **Approver** ("platform-team" in this demo — could be the API owner, could be a separate access-review role) | deciding yes/no, and at what tier | `APIKeyApproval`, and the Dev Portal catalog entry both sides see: [`api-product.yaml`](../../stack/connectivity/partner-api/api-product.yaml) |

**C2. Deploy the API, test it with no key.**
* **Do:**
  ```bash
  ./deploy.sh connectivity partner-api deploy
  ./deploy.sh connectivity status
  ./deploy.sh connectivity partner-api test
  ```
* **You see:** `status` shows the Gateway `Programmed`, the `AuthPolicy` and `APIProduct`
  `Enforced`/`Ready` (give it a minute after `deploy` if not yet); `test` with no key returns
  **401**.
* **Say:** "The API owner's `AuthPolicy` targets the HTTPRoute, not the Gateway — it only applies
  to this one API, not to anything else that might share this Gateway later. Right now, nothing
  is allowed in: no key has been issued yet."

**C3. The partner developer: self-service signup.**
* **Do:**
  ```bash
  ./deploy.sh connectivity partner-api signup trial alice alice@partner.example.com
  ```
* **You see:** an `APIKeyRequest` created, status `Pending`; the printed API key does not work yet
  (`./deploy.sh connectivity partner-api test <that key>` still returns 401).
* **Say:** "This is the Dev Portal persona workflow, not a Kubernetes RBAC request — Alice doesn't
  need, and never gets, any access to this cluster. She asked for the `trial` tier; the `APIProduct`
  (`api-product.yaml`) is what the Dev Portal would show her as the catalog entry she signed up
  against."

**C4. The approver: review and grant.**
* **Do:**
  ```bash
  ./deploy.sh connectivity partner-api approve partner-request-xxxxxx   # name printed by signup
  ./deploy.sh connectivity partner-api test <the key printed>
  ```
* **You see:** the approval step labels the key's Secret as a valid credential for this API's
  `AuthPolicy`; `test` now returns **200** with real order data from `orders-service`.
* **Say:** "The approver's decision — tier and all — rides entirely on a Kubernetes object anyone
  with the right RBAC can create; no code change, no redeploy, nothing the platform engineer or
  the API owner has to do per-request."
* **Do (optional — show the other outcome):**
  ```bash
  ./deploy.sh connectivity partner-api signup trial bob bob@partner.example.com
  ./deploy.sh connectivity partner-api deny partner-request-yyyyyy
  ./deploy.sh connectivity partner-api test <bob's key>     # still 401, forever
  ```

**C5. Plan tiers and rate limits — configured by the API owner, not the platform team.**
* **Do:**
  ```bash
  cat stack/connectivity/partner-api/plan-policy.yaml
  oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.limits}' | python3 -m json.tool
  ```
  (the file: [`plan-policy.yaml`](../../stack/connectivity/partner-api/plan-policy.yaml))
* **You see:** the `PlanPolicy`'s two tiers (`trial`: 20/day; `partner`: 1000/day), each a plain
  CEL predicate reading the `secret.kuadrant.io/plan-id` annotation the
  approval step sets; and Limitador's own config shows both limits registered under
  `ai-demo/partner-orders-api`, independent of anything in `platform/10-kuadrant` (the MaaS limits
  live right next to these, untouched).
* **Say:** "The person who decided '20 requests a day for trial, 1000 for partner' is whoever owns
  `orders-service` — not whoever runs the Gateway, and not whoever installed Connectivity Link.
  That's the platform engineering point: self-service infrastructure, but business policy stays
  with the business owner." See "If something goes wrong" for why a live 429 doesn't currently
  fire on this cluster even though the policy is correctly configured and `Enforced`.

---

## Part D: how it is built

**Service Interconnect (Part A)** — everything under
[`stack/connectivity/legacy-site/`](../../stack/connectivity/legacy-site/) and
[`stack/connectivity/platform-site/`](../../stack/connectivity/platform-site/):

* [`legacy-site/network-policies.yaml`](../../stack/connectivity/legacy-site/network-policies.yaml):
  the three-rule "firewall" from A1 — `deny-all-ingress`, `allow-skupper-router-ports-only` (no
  `from:` filter, safe only because these two ports only ever speak Skupper's own mutual TLS), and
  `allow-postgres-from-same-namespace` (the actual boundary: Postgres itself stays unreachable
  from outside this namespace, including from the platform side of the link).
* [`legacy-site/site.yaml`](../../stack/connectivity/legacy-site/site.yaml): the Skupper `Site` on
  the legacy side, `linkAccess: default` (lets `connectivity.sh link` mint an `AccessGrant`/
  `AccessToken` pair for the other side to join with).
* [`legacy-site/connector.yaml`](../../stack/connectivity/legacy-site/connector.yaml): binds the
  real `legacy-inventory-db` Pod (`selector: app=legacy-inventory-db`, `port: 5432`) to a
  `routingKey` — the only thing the platform side's `Listener` needs to match to create the
  virtual service.
* [`legacy-site/postgres.yaml`](../../stack/connectivity/legacy-site/postgres.yaml) and
  [`seed-job.yaml`](../../stack/connectivity/legacy-site/seed-job.yaml): the actual database
  (Deployment + Service + Secret) and the one-shot Job that creates the `parts` table and its two
  rows — note `seed-job.yaml`'s explicit `PGPASSWORD` env (see "If something goes wrong" for why).
* [`platform-site/site.yaml`](../../stack/connectivity/platform-site/site.yaml): the Skupper `Site`
  on the platform side, in the `connectivity-demo` namespace `connectivity.sh` creates for it.
* [`platform-site/listener.yaml`](../../stack/connectivity/platform-site/listener.yaml): same
  `routingKey` as the Connector, same name/port as the real database — this is what actually
  materializes the local `legacy-inventory-db` ClusterIP Service that `psql-check` queries.

**Connectivity Link (Part C)** — everything under
[`stack/connectivity/partner-api/`](../../stack/connectivity/partner-api/):

* [`gateway.yaml`](../../stack/connectivity/partner-api/gateway.yaml): a second Gateway API
  `Gateway` in `ai-demo`, `gatewayClassName: istio` (the same Service Mesh 3 control plane as every
  other sidecar in the namespace — needed so its certificate is one the mesh's STRICT mTLS
  `PeerAuthentication` accepts) and `allowedRoutes.from: Same` (only HTTPRoutes in `ai-demo` may
  attach, keeping ownership split along the persona table above).
* [`route.yaml`](../../stack/connectivity/partner-api/route.yaml): the OpenShift `Route` that
  exposes the Gateway's listener externally (`ClusterIP` + `networking.istio.io/service-type`
  annotation on the Gateway, no `LoadBalancer` needed).
* [`mesh-authorization.yaml`](../../stack/connectivity/partner-api/mesh-authorization.yaml): the
  explicit mesh `AuthorizationPolicy` grant letting `partner-gateway`'s identity call
  `orders-service` — same deny-all-by-default model as every other identity in demo 2, one more
  entry added to it.
* [`httproute.yaml`](../../stack/connectivity/partner-api/httproute.yaml): the API/app team's
  route from the Gateway's listener to `orders-service`, the thing every policy below targets.
* [`auth-policy.yaml`](../../stack/connectivity/partner-api/auth-policy.yaml): API-key
  authentication, `allNamespaces: true` (Authorino is cluster-wide but compiles `AuthConfig`s into
  its own namespace by default — without this it never finds keys created in `ai-demo`), and the
  `kuadrant.io/apikeys-by` label selector that only matches Secrets the approval step has labelled.
* [`plan-policy.yaml`](../../stack/connectivity/partner-api/plan-policy.yaml): the two tiers from
  C5, each a CEL `predicate` reading `secret.kuadrant.io/plan-id` off the authenticated identity.
* [`api-product.yaml`](../../stack/connectivity/partner-api/api-product.yaml): the Dev Portal
  catalog entry — `approvalMode: manual`, display name/description/contact a partner developer
  would actually see, and `status.conditions` that explain exactly which of AuthPolicy/PlanPolicy
  is still missing if the product never reaches `Ready`.
* [`envoyfilter-authorino-tls.yaml`](../../stack/connectivity/partner-api/envoyfilter-authorino-tls.yaml):
  the TLS fix for this cluster's Authorino (see "If something goes wrong") — scoped to
  `partner-gateway` only, so it never touches the MaaS Gateway's own equivalent fix.
* [`cluster-params.env`](../../stack/connectivity/partner-api/cluster-params.env) and
  [`kustomization.yaml`](../../stack/connectivity/partner-api/kustomization.yaml): the
  cluster-domain substitution (`REPLACED-BY-KUSTOMIZE` hostnames) and the file list that ties all
  of the above together for a single `oc apply -k`.
* [`operators/service-interconnect.yaml`](../../operators/service-interconnect.yaml): the Service
  Interconnect operator Subscription, added to [`operators/kustomization.yaml`](../../operators/kustomization.yaml).
* [`stack/connectivity/connectivity.sh`](../../stack/connectivity/connectivity.sh): every
  `./deploy.sh connectivity ...` subcommand used throughout this demo — `legacy`/`link`/
  `psql-check` for Part A, `partner_api_deploy`/`signup`/`approve`/`deny`/`test`/`reset` for Part C,
  including the two workarounds mentioned in "If something goes wrong" (the wasm-plugin-load retry
  and the devportal-controller-OOM label fallback).

---

## Part E: configuration reference — change it yourself

Every knob below is a few lines of YAML, applied with `oc apply -f` (or `-k` for a whole
directory) — the object name doesn't change, so this edits the running policy live.

**Add a third plan tier, or change the daily limits** —
[`plan-policy.yaml`](../../stack/connectivity/partner-api/plan-policy.yaml), `spec.plans`:
```yaml
plans:
  - tier: partner
    predicate: |
      has(auth.identity) && auth.identity.metadata.annotations["secret.kuadrant.io/plan-id"] == "partner"
    limits:
      daily: 1000          # <- raise/lower this partner tier's requests-per-day
  - tier: trial
    predicate: |
      has(auth.identity) && auth.identity.metadata.annotations["secret.kuadrant.io/plan-id"] == "trial"
    limits:
      daily: 20             # <- raise/lower this trial tier's requests-per-day
  # - tier: enterprise       # <- add a third tier: copy the shape above, change the plan-id value
  #   predicate: |
  #     has(auth.identity) && auth.identity.metadata.annotations["secret.kuadrant.io/plan-id"] == "enterprise"
  #   limits:
  #     daily: 10000
```
A new tier also needs a matching value wherever `connectivity.sh partner_api_signup` sets
`secret.kuadrant.io/plan-id` on the `APIKeyRequest`/Secret — search `connectivity.sh` for
`plan-id` to see exactly where.
```bash
oc apply -f stack/connectivity/partner-api/plan-policy.yaml
```

**Change the auth header/prefix the API expects** —
[`auth-policy.yaml`](../../stack/connectivity/partner-api/auth-policy.yaml), `spec.rules.authentication`:
```yaml
credentials:
  authorizationHeader:
    prefix: APIKEY        # <- e.g. "Bearer" to match a more conventional client expectation
```
```bash
oc apply -f stack/connectivity/partner-api/auth-policy.yaml
./deploy.sh connectivity partner-api test <key>   # update the curl's own header to match
```

**Switch the Dev Portal to auto-approve instead of manual review** —
[`api-product.yaml`](../../stack/connectivity/partner-api/api-product.yaml):
```yaml
spec:
  approvalMode: manual     # <- "auto": every signup gets a key immediately, no approve/deny step
```
```bash
oc apply -f stack/connectivity/partner-api/api-product.yaml
```

**Open an extra port through the legacy NetworkPolicy** (e.g. to add a second legacy service) —
[`network-policies.yaml`](../../stack/connectivity/legacy-site/network-policies.yaml),
`allow-postgres-from-same-namespace`'s sibling rule:
```yaml
- apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: allow-postgres-from-same-namespace
    namespace: legacy-datacenter
  spec:
    podSelector:
      matchLabels:
        app: legacy-inventory-db   # <- change to target a different/additional legacy Pod
    ingress:
      - from:
          - podSelector: {}
        ports:
          - protocol: TCP
            port: 5432             # <- the new service's port
```
```bash
oc apply -f stack/connectivity/legacy-site/network-policies.yaml
```

**After any edit above:** `oc apply -k stack/connectivity/partner-api` (or `legacy-site`/
`platform-site`) re-applies every file in that folder at once; `./deploy.sh connectivity
partner-api reset` only clears signups/approvals, never a YAML edit — `git checkout
stack/connectivity/<file>.yaml` reverts that.

---

## Prove it from the terminal

```bash
./deploy.sh connectivity setup
./deploy.sh connectivity legacy
./deploy.sh connectivity link
./deploy.sh connectivity psql-check          # query succeeds through Skupper; direct access times out
./deploy.sh connectivity partner-api deploy
./deploy.sh connectivity partner-api test                                    # 401, no key
./deploy.sh connectivity partner-api signup trial carol carol@partner.example.com
./deploy.sh connectivity partner-api test sk-partner-xxxxxx                   # 401, pending
./deploy.sh connectivity partner-api approve partner-request-xxxxxx
./deploy.sh connectivity partner-api test sk-partner-xxxxxx                   # 200, orders JSON
./deploy.sh connectivity partner-api reset
```

## Reset

```bash
./deploy.sh connectivity partner-api reset    # removes signups/requests/approvals only
./deploy.sh connectivity destroy              # removes both demo namespaces + the ai-demo additions
                                               # (operators stay installed)
```

## If something goes wrong

* **Seed Job hangs forever, `legacy-inventory-db:5432 - no response`:** the Job's own pod is not
  the Skupper router — if `allow-postgres-from-same-namespace` in
  [`network-policies.yaml`](../../stack/connectivity/legacy-site/network-policies.yaml) was
  narrowed back to `skupper.io/component: router` only, the seed Job (and anything else legitimate
  in that namespace) can no longer reach Postgres. The boundary this demo illustrates is
  namespace/network isolation, not intra-namespace lockdown.
* **Seed Job: `password authentication failed for user "legacy_app"`:** `psql` reads `PGPASSWORD`,
  not `POSTGRESQL_PASSWORD` — the Secret's `envFrom` only sets the latter. `seed-job.yaml` exports
  `PGPASSWORD` from it explicitly; a hand-written Job/Pod using the same Secret needs the same line.
* **AccessGrant/AccessToken link fails with `SSL Failure: unexpected eof while reading`:** this is
  what an overly-namespace-scoped `NetworkPolicy` on the Skupper router's ports looks like — the
  Route traffic for the link physically originates from the OpenShift router pods in
  `openshift-ingress`, not from the peer namespace directly. `allow-skupper-router-ports-only` is
  deliberately a port-only restriction (TCP 55671/45671, no `from:` namespace filter) — the ports
  are protected by the AccessGrant's own mutual TLS, not by network segmentation.
* **Partner API returns 500, and the Gateway's own Envoy log shows `wasm log kuadrant-wasm-shim:
  gRPC status code is not OK`:** Authorino's authorization gRPC service has TLS enabled on this
  cluster (`Authorino` CR: `spec.listener.tls.enabled: true`), but the kuadrant-operator's
  auto-generated `EnvoyFilter` for a plain Gateway API Gateway talks to it in plaintext. The MaaS
  Gateway doesn't hit this because `odh-model-controller` ships its own fix
  (`EnvoyFilter/maas-default-gateway-authn-ssl`) for its own integration only.
  [`envoyfilter-authorino-tls.yaml`](../../stack/connectivity/partner-api/envoyfilter-authorino-tls.yaml)
  is the same fix, scoped to `partner-gateway`. If a future kuadrant-operator release fixes this
  upstream, this file becomes redundant (check for a `transport_socket` on
  `oc get envoyfilter kuadrant-auth-partner-gateway -n ai-demo -o yaml`).
* **Every request to the partner API returns `503`, right after `partner-api deploy`, with no
  `AuthPolicy`/mesh error in sight:** a brand new `partner-gateway` Envoy pod occasionally loses the
  race fetching the Kuadrant wasm plugin binary from `kuadrant-operator-wasm` at startup —
  `oc logs -n ai-demo -l gateway.networking.k8s.io/gateway-name=partner-gateway` shows `Plugin
  kuadrant-wasm-shim failed to load` / `Plugin configured to fail closed failed to load`. It does
  not retry on its own; `connectivity.sh partner_api_deploy` already checks for this and restarts
  the pod once if the API isn't answering within 30 seconds. By hand:
  `oc delete pod -n ai-demo -l gateway.networking.k8s.io/gateway-name=partner-gateway`.
* **A signed-up, approved key still gets `401 the API Key provided is invalid`:** the Authorino
  instance backing this cluster's Kuadrant is cluster-wide, but it compiles every `AuthConfig` it
  generates into its own namespace (`kuadrant-system`) — by default it only looks for API key
  Secrets in that same namespace, never finding the Dev Portal's keys in `ai-demo`.
  [`auth-policy.yaml`](../../stack/connectivity/partner-api/auth-policy.yaml) sets
  `rules.authentication.api-key-authentication.apiKey.allNamespaces: true` to fix this; without it,
  `oc logs -n kuadrant-system -l authorino-resource=authorino` (with `Authorino.spec.logLevel:
  debug`) shows `"Namespace":"kuadrant-system"` in the identity config, instead of `ai-demo`.
* **A signed-up key stays invalid even with `allNamespaces: true`:** the Secret also needs the
  label `authorino.kuadrant.io/managed-by: authorino` (Authorino's `--secret-label-selector`
  bootstrap flag) *from the moment it's created* — without it, Authorino never watches that Secret
  individually, so the `kuadrant.io/apikeys-by` label the approval step adds later is invisible
  until something else happens to touch the `AuthConfig`. `connectivity.sh`'s `partner_api_signup`
  sets both labels up front for this reason.
* **`APIKeyApproval` rejected: `spec.reviewedAt: Required value`:** the CRD requires it even though
  it's easy to assume `approved`/`reviewedBy` are enough — `connectivity.sh` sets it to the current
  UTC time (`date -u +%Y-%m-%dT%H:%M:%SZ`).
* **`partner-api approve` always falls through to "devportal controller hasn't labelled ... yet":**
  this cluster's `kuadrant-operator-controller-manager` (the same process that reconciles the Dev
  Portal CRDs) has a 300Mi memory limit set by its own OLM `CSV` and periodically OOM-crash-loops
  under load (`oc get pods -n openshift-operators -l ... | grep kuadrant-operator` — check the
  restart count). This is a pre-existing cluster condition, not something this demo's manifests
  can fix (the Deployment spec is owned by the CSV; a direct `oc patch` on the memory limit gets
  silently reverted). `connectivity.sh partner_api_approve` works around it: if the controller
  hasn't labelled the Secret within 30 seconds, the script labels/annotates it directly and says so.
* **Plan-tiered rate limiting doesn't actually return 429, even past the configured daily limit,
  and the Gateway's Envoy log shows `wasm log kuadrant-wasm-shim: Failed to apply predicates:
  ... CelError::Resolve { NoSuchKey("kuadrant") }`:** this is a genuine upstream limitation of the
  `PlanPolicy` extension (`extensions.kuadrant.io/v1alpha1`, still alpha) on the kuadrant-operator
  version installed on this cluster: the rate-limit action's own auto-generated CEL predicate
  (`auth.kuadrant.plan == "partner" || auth.kuadrant.plan == "trial"`) is not guarded with a `has()`
  check, so when the expected dynamic metadata key isn't populated the wasm shim aborts evaluation
  for that request — and because every rate-limit service in the shim's config has
  `failureMode: allow`, an aborted check simply lets the request through uncounted, every time.
  (A near-identical class of bug — unguarded `auth.*` CEL expressions aborting the wasm shim — was
  fixed upstream in `opendatahub-io/models-as-a-service` for a different, static policy; `PlanPolicy`
  itself doesn't expose that generated predicate for us to add the guard ourselves.) The
  `PlanPolicy`/`RateLimitPolicy` both correctly show `status: Enforced`, and Limitador's own config
  (`oc get limitador limitador -n kuadrant-system -o jsonpath='{.spec.limits}'`) has both tiers'
  limits registered correctly under `ai-demo/partner-orders-api` — the *configuration* is exactly
  what the personas story in C5 describes, it just doesn't trip live on this cluster today. Treat
  C5 as "how an API owner configures tiers," not as a live 429 demo, until this is fixed upstream.
* **No Developer Hub catalog entry, no `./deploy.sh validate` checks for this demo:** both were
  deliberately left out of this first pass to keep scope manageable — unlike every other layer in
  this repository, this demo is `oc`-only and not covered by `./deploy.sh validate`.
