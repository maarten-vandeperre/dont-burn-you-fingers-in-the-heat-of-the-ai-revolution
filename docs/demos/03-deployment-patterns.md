# Demo 3: Deployment patterns

**The story:** releasing is a routing decision in the mesh, not a redeployment. Two versions of
the rag-service run side by side; one small VirtualService decides who gets which version:
canary, A/B, blue-green or mirroring, changed in seconds and undone just as fast.

**Duration:** 15 minutes (8 UI, 5 IntelliJ, 2 automated canary). Each part also works on its own.

`./deploy.sh app pattern` applies one file under `app/deploy/patterns/`. To edit the weights,
the header match or the mirror block yourself and apply that file: [Service mesh manifests](service-mesh.md),
section 2.

**The versions:** rag-service **v1** (short answers, top 3 passages) and **v2** (bullet points with
citations, top 5 passages). Same image, behind one Kubernetes Service.

Every step below has three parts: **Do**, **You see**, **Say**.

---

## Before you start

1. Terminal in the repository folder:
   ```bash
   ./deploy.sh app pattern reset    # everything to v1
   ./deploy.sh app urls
   ```
2. Two browser windows side by side:
   * **Demo UI**, tab **Traffic patterns**
   * **Kiali** > **Traffic Graph**, namespace **ai-demo**, graph type **Versioned app graph**,
     **Display** dropdown: tick **Traffic Distribution**
3. **IntelliJ** on the repository folder.
4. A terminal window for the pattern commands (or Developer Hub > Create > "Mesh: switch
   rag-service traffic pattern", see demo 6).

---

## Part A: switch patterns and watch the traffic (8 minutes)

For every pattern: run the command, then in the demo UI set requests to **100** and click
**Send traffic**. The **Which version answers?** card shows how many requests each version served.
Kiali shows the same split on the edges into rag-service v1 and v2.

**A1. Baseline.**
* **Do:** `./deploy.sh app pattern reset`, **Send traffic**.
* **You see:** 100% v1.
* **Say:** "v2 is deployed and running, but gets no traffic. Deploying is not releasing."

**A2. Canary.**
* **Do:** `./deploy.sh app pattern canary 10`, **Send traffic**. Then `./deploy.sh app pattern canary 50`.
* **You see:** about 90/10, then about 50/50; Kiali edges show the percentages.
* **Say:** "A canary is one number in the VirtualService. If v2 misbehaves, we set it back to 0 in
  a second, without touching the pods."

**A3. A/B testing.**
* **Do:** `./deploy.sh app pattern ab`. **Send traffic** with **x-variant header** empty, then with **b**.
* **You see:** without the header 100% v1, with `x-variant: b` 100% v2.
* **Do (real answers):** tab **Ask (RAG)**, tick **send x-variant: b**, click **Ask**.
* **You see:** a v2 answer: bullet points with `[1]`, `[2]` citations and the badge `rag v2`.
* **Say:** "Selected users, for example a beta group with a header or cookie, get the new version;
  everyone else stays on the old one."

**A4. Blue-green.**
* **Do:** `./deploy.sh app pattern blue`, **Send traffic**; `./deploy.sh app pattern green`, **Send traffic**.
* **You see:** 100% v1, then instantly 100% v2.
* **Say:** "Switch everybody at once, and switch back at once if needed. Both versions stay warm."

**A5. Mirroring (shadow traffic).**
* **Do:** `./deploy.sh app pattern mirror`, **Send traffic**. Then:
  ```bash
  oc logs deploy/rag-service-v2 -n ai-demo -c app --tail=5
  ```
* **You see:** the demo UI reports 100% v1, yet the v2 log shows
  `version request served by rag-service v2` for the mirrored calls. In Kiali: Workloads >
  `rag-service-v2` > Inbound Metrics counts them.
* **Say:** "v2 receives a copy of real production traffic, but its answers are thrown away. You test
  a new version with real load and nobody notices."

**A6. Back to normal.**
* **Do:** `./deploy.sh app pattern reset`.

---

## Part B: the configuration in IntelliJ (5 minutes)

**B1. One Service, two versions.**
* **Do:** open `app/deploy/base/rag-service.yaml`.
* **Point at:** one Service `rag-service`, two Deployments `rag-service-v1` and `rag-service-v2`
  with label `version: v1` / `v2` and `APP_VERSION`.

**B2. The versions as subsets.**
* **Do:** open `app/deploy/mesh/destination-rules.yaml`.
* **Point at:** `subsets` v1 and v2, selected by the `version` label.

**B3. The patterns are just VirtualServices.**
* **Do:** open `app/deploy/patterns/canary.yaml`, `ab.yaml` and `mirror.yaml` side by side
  (right-click the tab > Split Right).
* **Point at:** the two `weight` values in canary; the `match` on header `x-variant` in ab; `mirror`
  and `mirrorPercentage` in mirror.
* **Say:** "Each release strategy is about ten lines of YAML. `./deploy.sh app pattern` only applies
  one of these files; in a GitOps setup it is a merge request."
* **Do (by hand):** edit the two `weight` values in `canary.yaml` so they add up to 100, then
  `oc apply -f app/deploy/patterns/canary.yaml`. The object name stays `rag-service`. The same
  apply works for `ab.yaml`, `blue.yaml`, `green.yaml`, `mirror.yaml` and `reset.yaml`. Field by
  field: [service-mesh.md](service-mesh.md), section 2.

**B4. How the version shows up.**
* **Do:** open `RagResource.java`, method **`version()`**.
* **Point at:** the log line `version request served by rag-service ...`: that is what you saw in A5.

**B5. Automated canary.**
* **Do:** open `app/deploy/overlays/rollouts/model-router-rollout.yaml`.
* **Point at:** `steps`: `setWeight: 20`, `pause 60s`, `setWeight: 50`, `pause 60s`, `setWeight: 100`,
  and the `trafficRouting` section that points Argo Rollouts at the Istio VirtualService.

---

## Part C: an automated canary with Argo Rollouts (2 minutes, optional)

Needs `./deploy.sh app deploy --rollouts` once.
* **Do:** `./deploy.sh app rollout`, or Developer Hub > Create > "Argo Rollouts: release the
  model-router" > Start.
* **You see:** `Progressing step 1 stable=80 canary=20`, then 50/50, then `Healthy`. In Developer Hub
  the `model-router` component's Kubernetes tab shows the Rollout and the VirtualService weights.
* **Say:** "Same mechanism, but Argo Rollouts turns the dial step by step and can abort automatically."

---

## Part D: prove it from the terminal (optional)

```bash
./deploy.sh app pattern canary 25 && ./deploy.sh app traffic 200
```
Expected: `requests: 200, errors: 0`, `rag v1` about 150, `rag v2` about 50.

```bash
./deploy.sh app pattern ab
./deploy.sh app traffic 50        # all v1
./deploy.sh app traffic 50 b      # all v2
```

## Reset

```bash
./deploy.sh app pattern reset
```

## If something goes wrong

* **Split is not exactly 10/90:** weights are probabilities; send 200 requests for a stable picture.
* **Kiali shows no version split:** pick graph type **Versioned app graph** and **Last 1m**.
* **`app rollout` says no Rollout:** deploy once with `./deploy.sh app deploy --rollouts`.
