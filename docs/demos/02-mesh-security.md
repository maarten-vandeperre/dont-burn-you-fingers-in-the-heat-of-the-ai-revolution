# Demo 2: Mesh security

**The story:** every call between services is encrypted and authenticated, and access is granted
per workload identity (its service account), not per IP address. The internet-facing frontend may
call the business services, but not the models and not the database: even if it were compromised,
it could not reach them.

**Duration:** 15 minutes (5 demo UI, 5 Kiali and console, 5 IntelliJ). Each part also works on its own.

To make the edits yourself, with every field and the `oc apply`: [Service mesh manifests](service-mesh.md), section 1.

**Who may call whom:**
```
ai-demo-gateway (ingress) -> frontend -> rag-service -> model-router -> models
                                      -> orders-service
                                      -> projection-service -> mongodb
everything else: denied (deny-all policy + STRICT mTLS)
```

Every step below has three parts: **Do** (what you click or open), **You see** (what appears),
**Say** (the point to make).

---

## Before you start

1. In a terminal in the repository folder:
   ```bash
   ./deploy.sh app probe     # five lines, all starting with OK
   ./deploy.sh urls          # Kiali and console URLs
   ./deploy.sh app urls      # demo UI URL
   ```
2. Open these browser tabs, signed in:
   * **Demo UI**, tab **Mesh access**
   * **Kiali** (URL "Kiali" from `./deploy.sh urls`, sign in with your OpenShift account)
   * **OpenShift console**
3. Open **IntelliJ** on the repository folder; **Shift twice** opens a file by name.
4. Generate some traffic so Kiali has something to draw: demo UI > **Traffic patterns** >
   **Send traffic**, and one question in **Ask (RAG)**.

---

## Part A: prove the rules in the demo UI (5 minutes)

**A1. The intended rules.**
* **Do:** Demo UI > **Mesh access**. Look at the card **Who may call whom**.
* **You see:** five rows: gateway to frontend; frontend to rag-service, orders-service and
  projection-service; rag-service to model-router; projection-service to mongodb; everyone else: nothing.
* **Say:** "This is the intended design. Now let's test it, from inside the frontend pod, with the
  frontend's own identity."

**A2. Test them.**
* **Do:** in the card **Probe from the frontend pod**, click **Run probe**.
* **You see:** a table with columns target, call, expected, result. Every row says **as expected**:
  * rag-service, orders-service, projection-service: expected **allow**, `HTTP 200`
  * model-router: expected **deny**, `403 RBAC: access denied`
  * mongodb: expected **deny**, the TCP connection is closed by the mesh
* **Say:** "The frontend got a 403 from the model router: only the rag-service may call it. And it
  cannot even open a connection to MongoDB. Nobody wrote a firewall rule or a network policy for
  this: the mesh decides based on who is calling."

---

## Part B: see it in Kiali and the OpenShift console (5 minutes)

**B1. Every connection is encrypted.**
* **Do:** Kiali > left menu **Traffic Graph**. In the **Namespace** dropdown at the top select
  **ai-demo**. Time range **Last 5m**. In the **Display** dropdown tick **Security**.
* **You see:** the services as a graph (gateway, frontend, rag-service v1 and v2, model-router,
  orders, projection, mongodb) with a **lock icon** on the edges.
* **Do:** click the edge **rag-service > model-router**.
* **You see:** the side panel with the request rate, the response codes and **mTLS enabled**.
* **Say:** "Every arrow is mutual TLS: both sides prove who they are with a certificate the mesh
  issues and rotates. No application code does any of that."

**B2. The denied calls are visible.**
* **Do:** Kiali > left menu **Workloads** > namespace **ai-demo** > **model-router** > tab
  **Inbound Metrics**. In **Metrics Settings** group by **Response code** (and source workload).
* **You see:** after A2, requests with response code **403** coming from **frontend**.
* **Say:** "Denials are not silent: operations sees exactly who tried to call what."

**B3. The rules are configuration, and they are validated.**
* **Do:** Kiali > left menu **Istio Config** > namespace **ai-demo**.
* **You see:** the PeerAuthentication `default` and the AuthorizationPolicies (`deny-all`,
  `frontend-from-gateway`, `rag-from-frontend`, `model-router-from-rag`, `mongodb-from-projection`, ...),
  each with a green check (valid). Click **model-router-from-rag** to see its YAML.
* **Say:** "Ten small policies describe the whole application's security. Kiali checks them for
  mistakes, for example a policy that points at a workload that does not exist."

**B4. Every pod has a sidecar.**
* **Do:** OpenShift console > **Workloads** > **Pods**, project **ai-demo**.
* **You see:** every pod **Ready 2/2**. Click a frontend pod > **Details**: containers **app** and
  **istio-proxy**.
* **Say:** "The second container is the Envoy proxy. The mesh adds it automatically because the
  namespace is labelled for injection. Developers keep writing plain HTTP."

---

## Part C: the configuration in IntelliJ (5 minutes)

**C1. Encryption is mandatory.**
* **Do:** open `app/deploy/mesh/peer-authentication.yaml`.
* **Point at:** `mode: STRICT`.
* **Say:** "One line: in this namespace, a call without a mesh certificate is refused. Plain text is
  not possible, not even by mistake."

**C2. Deny everything, then allow per identity.**
* **Do:** open `app/deploy/mesh/authorization-policies.yaml`.
* **Point at:**
  * the diagram in the comment at the top
  * **`deny-all`**: an empty spec, which means nothing is allowed
  * **`model-router-from-rag`**: `principals` `cluster.local/ns/ai-demo/sa/rag-service` (and the
    coffee shop), `paths: ["/v1/*"]`
  * **`mongodb-from-projection`**: a TCP rule on the MongoDB port, only for the projection-service
* **Say:** "Identities, not IP addresses: `sa/rag-service` is the service account of the rag-service
  pods. Scale it, move it, restart it: the rule keeps working."

**C3. How pods join the mesh.**
* **Do:** open `app/deploy/base/namespace.yaml`.
* **Point at:** the labels `istio-discovery: enabled` and `istio-injection: enabled`.

**C4. What the probe actually does.**
* **Do:** open `MeshProbe.java` (app/frontend).
* **Point at:** the five probes: three `httpProbe(..., true)`, `httpProbe("model-router", ..., false)`
  and `tcpProbe("mongodb", ..., false)`.
* **Say:** "Ordinary Java HTTP and socket calls. The application does nothing special; the sidecar
  enforces the rules."

**C5. Change a rule live (the strongest moment of this demo).**
* **Do:** in `authorization-policies.yaml`, in **`model-router-from-rag`**, add a third principal
  directly below the `sa/coffee-shop` line, with the same indentation:
  ```yaml
              - "cluster.local/ns/ai-demo/sa/frontend"
  ```
  Save, then in the IntelliJ terminal:
  ```bash
  oc apply -f app/deploy/mesh/authorization-policies.yaml -n ai-demo
  ```
  Demo UI > **Mesh access** > **Run probe**.
* **You see:** the model-router row now says **unexpected** (amber) with `HTTP 200`: the frontend
  is allowed now.
* **Say:** "Security as code: a reviewed change in git, applied in seconds, effective without a
  restart."
* **Do (revert):** remove the line, save, run the same `oc apply`, **Run probe** again: all rows are
  back to **as expected**.

The same file is where every other allow is edited. `principals` is the caller's service account
(`cluster.local/ns/ai-demo/sa/<name>` from `app/deploy/base/serviceaccounts.yaml`). `paths` on
`rag-from-frontend` is what the frontend may request (`/api/rag/*`). `mode: STRICT` in
`peer-authentication.yaml` is the certificate requirement. Section 1 of
[service-mesh.md](service-mesh.md) walks through each of those edits, the apply command, and how
to put the file back.

---

## Part D: prove it from the terminal (optional)

```bash
./deploy.sh app mtls
```
Expected: frontend, rag-service and model-router each `rejected (plaintext not allowed, STRICT mTLS)`.
The calls come from a pod outside the mesh, so they have no certificate.

```bash
./deploy.sh app probe
```
Expected: five lines, all `OK`; model-router `403 RBAC: access denied`.

Break and repair:
```bash
oc delete authorizationpolicy rag-from-frontend -n ai-demo   # Ask (RAG) in the UI now fails
./deploy.sh app deploy                                       # restores every policy
```

## Reset

```bash
./deploy.sh app deploy     # re-applies the policies exactly as in git
./deploy.sh app probe      # all OK
```

## If something goes wrong

* **Probe shows "unexpected" before you changed anything:** someone edited a policy: `./deploy.sh app deploy`.
* **Kiali graph is empty:** no traffic in the selected time range; send traffic (Traffic patterns tab)
  and pick **Last 5m**.
* **No lock icons:** tick **Security** in the **Display** dropdown.
* **Pods show 1/1:** they started before the namespace had the injection label; restart them:
  `oc rollout restart deploy -n ai-demo`.
