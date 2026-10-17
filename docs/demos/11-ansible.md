# Demo 11: Ansible in Developer Hub

**The story:** two Backstage/Developer Hub plugins working together. The **default Ansible
plugin** (`ansible-plugin-backstage-rhaap`, the same one Red Hat ships for Ansible Automation
Platform) gives every developer a read-only "Ansible" view of job templates and runs. A
**software template** is the self-service front door on top of it: a developer clicks **Create**,
fills in nothing, and a real Ansible workflow installs a PostgreSQL database on the cluster — and
if one already exists, the workflow does not just overwrite it: it pauses and asks a human to
approve the delete first. A second, standalone workflow does only the delete, with the same
approval gate. This demo runs a real, in-cluster **Ansible Automation Platform (AAP) 2.6**
instance (Controller only — Hub and EDA are disabled, this demo doesn't need them) — it needs a
valid AAP subscription (registry.redhat.io entitlement), see "Before you start" below.

**Duration:** 20 minutes (5 Part A plugin, 10 Part B the two workflows, 5 Part C how it is built).

```
Developer Hub                         AAP Controller (stack/ansible, ./deploy.sh ansible setup)
  "Ansible" tab (plugin 1)  <--read--    Job Templates: check-postgres, install-postgres,
                                         delete-postgres
  Create > "Ansible: install            Workflow Job Templates:
    PostgreSQL" (plugin 2,                install-postgres-safe:
    rhaap:launch-job-template)              check-postgres --(absent)--> install-postgres
  Create > "Ansible: delete                            \--(exists)--> [Approval] --> delete-postgres --> install-postgres
    PostgreSQL" (same action,             delete-postgres:
    different workflow)                     [Approval] --> delete-postgres
                                                 |
                                            ansible-demo namespace: Deployment/Service/PVC/Secret
                                            (ansible/playbooks/*.yml, kubernetes.core collection)
```

| Piece | Real or mocked |
|---|---|
| AAP, the Project (synced from this repo's GitLab mirror), the Job/Workflow Job Templates | **real**: live AAP Controller instance behind the Platform Gateway, `stack/ansible/ansible.sh bootstrap` configures it over the Controller REST API |
| The PostgreSQL install/delete | **real**: `kubernetes.core.k8s` tasks against this cluster, namespace `ansible-demo` |
| The manual approval | **real**: AAP's native Workflow Approval node — the workflow job literally pauses until `approve`/`deny` is called |
| The Developer Hub "Ansible" tab | **real** if your RHDH entitlement/extensions catalog bundles `ansible-plugin-backstage-rhaap`; otherwise shown as a config walkthrough — see "If something goes wrong" |
| The two software templates | **real**: `rhaap:launch-job-template`, same scaffolder action Red Hat's own AAP docs use |

---

## Before you start

1. The platform stack and GitLab (the AAP Project syncs this repository from there):
   ```bash
   ./deploy.sh stack
   ```
2. A Red Hat Ansible Automation Platform subscription and its `registry.redhat.io` pull secret
   -- see [`ansible/README.md`](../../ansible/README.md) "Red Hat subscription and the image pull
   secret" for the one-time steps. Without this, `setup` below stops early with the exact command
   to run.
3. AAP, the demo namespace/credential, the Job/Workflow Templates:
   ```bash
   ./deploy.sh ansible setup
   ./deploy.sh ansible urls
   ```
4. Wire Developer Hub (catalog, the two new templates, and the Ansible plugin if this version
   offers it):
   ```bash
   ./deploy.sh rhdh
   ```
5. Browser tabs: **Developer Hub** (Catalog, system `ansible-demo`), **AAP** (Automation
   Execution > Templates, and Jobs for watching a run live).
6. Start clean: `./deploy.sh ansible reset` (removes the demo PostgreSQL directly, so the first
   run of the demo installs straight away with no pending approval left over from a previous run).

---

## Part A: the default Ansible plugin (5 minutes)

**A1. The catalog.**
* **Do:** Developer Hub > **Catalog**, filter **Kind: System**, open **ansible-demo**.
* **You see:** the System's links (AAP, the GitLab source, `ansible/README.md`) and three
  Resources: the demo database, and the two workflows.
* **Say:** "Same pattern as every other demo on this platform: one System, the objects it owns,
  wired with real links — nothing here is a screenshot."

**A2. The Ansible tab.**
* **Do:** open the **Ansible** item in Developer Hub's left nav (or a Component's **Ansible**
  tab, if your RHDH's catalog sync module for AAP is also enabled).
* **You see:** the Job Templates and Workflow Job Templates from AAP Controller, each one a
  Template entity the plugin's catalog-backend module can auto-generate
  `scaffolder.backstage.io/v1beta3` wrappers for.
* **Say:** "This is the stock Ansible plugin, unmodified, talking to a real AAP Controller through
  the Platform Gateway — exactly how you'd point it at any AAP instance, in-cluster or not."

---

## Part B: the two workflows (10 minutes)

**B1. Install onto a clean namespace.**
* **Do:** Developer Hub > **Create** > **Ansible: install PostgreSQL** > **Create**.
* **You see:** the template's output: a workflow job ID and status; `./deploy.sh ansible status`
  shows the `postgres-demo` Deployment/Service/PVC coming up in `ansible-demo`.
* **Say:** "`check-postgres` ran first, found nothing, and the workflow went straight to
  `install-postgres` — no approval needed when there is nothing to lose."

**B2. Run it again — now it already exists.**
* **Do:** Developer Hub > **Create** > **Ansible: install PostgreSQL** > **Create** (same template,
  again).
* **You see:** `./deploy.sh ansible status` shows a **pending approval**; in AAP, open
  **Automation Execution > Jobs** > this workflow run — it is paused on the `Approve PostgreSQL
  deletion` node, `delete-postgres` and the second `install-postgres` are greyed out, not started.
* **Say:** "`check-postgres` failed on purpose this time — the Deployment already existed — and a
  failure is exactly the edge that leads to the approval node, not to `install-postgres` again."
* **Do:** `./deploy.sh ansible approve` (or AAP: the paused node > **Approve**).
* **You see:** the workflow continues — `delete-postgres` then `install-postgres` both run; status
  shows a fresh Deployment (new `creationTimestamp`, same name).
* **Say:** "One click, in AAP or from the CLI, and only that click lets the delete happen. Deny it
  instead next time and the database is never touched — the workflow just ends."

**B3. The standalone delete.**
* **Do:** `./deploy.sh ansible run install-postgres-safe` once more to have something to delete,
  wait for it to finish, then Developer Hub > **Create** > **Ansible: delete PostgreSQL** >
  **Create**.
* **You see:** a pending approval immediately — there is no "check" step here, this workflow's
  first and only node before the delete is the approval gate.
* **Do:** `./deploy.sh ansible approve`.
* **You see:** `./deploy.sh ansible status` shows the Deployment/Service/PVC gone.
* **Say:** "Two different entry points — 'install, but ask before replacing' and 'just delete' —
  are two different Workflow Job Templates sharing the exact same `delete-postgres` Job Template
  and the exact same approval mechanism. Nothing about the gate is duplicated."

---

## Part C: how it is built (IntelliJ, 5 minutes)

* [`ansible/playbooks/check_postgres.yml`](../../ansible/playbooks/check_postgres.yml) — point at
  the `ansible.builtin.fail` at the bottom: this is the entire branching mechanism, a deliberate
  non-zero exit code, not a custom AAP feature.
* [`ansible/workflows/install-postgres-safe.json`](../../ansible/workflows/install-postgres-safe.json)
  — the `nodes`/`edges` shape; point at `"state": "failure"` on the `check` → `approval` edge and
  `"type": "workflow_approval_template"` on the approval node.
* [`stack/ansible/ansible.sh`](../../stack/ansible/ansible.sh) `create_workflow()` — point at how
  it turns that JSON into Controller API calls (through the Platform Gateway, `/api/controller/v2/`):
  `create_approval_template` for the approval node, `success_nodes`/`failure_nodes` for the edges.
* [`stack/ansible/rbac.yaml`](../../stack/ansible/rbac.yaml) — the `ansible-postgres-admin`
  ServiceAccount's Role: only the object kinds the playbooks touch, only in `ansible-demo`. This
  becomes the AAP Credential the Job Templates run with.
* [`stack/ansible/aap.yaml`](../../stack/ansible/aap.yaml) — the `AnsibleAutomationPlatform`
  custom resource: Controller enabled, Hub/EDA disabled, and the `image_pull_secrets` reference
  that needs the Red Hat subscription secret from "Before you start".
* [`stack/developer-hub/catalog-templates/template-ansible-install-postgres.yaml`](../../stack/developer-hub/catalog-templates/template-ansible-install-postgres.yaml)
  — the `rhaap:launch-job-template` action and `values.template: install-postgres-safe` (the
  workflow's *name*, matched by the plugin against AAP, not an ID baked into the file).
  [`template-ansible-delete-postgres.yaml`](../../stack/developer-hub/catalog-templates/template-ansible-delete-postgres.yaml)
  is the same file shape with a different `values.template` — point at how little changes between
  "launch workflow A" and "launch workflow B".
* [`stack/developer-hub/dynamic-plugins.yaml`](../../stack/developer-hub/dynamic-plugins.yaml) —
  the `# --- Ansible ---` block: point at the comment explaining this is hand-maintained and
  dropped by every `./deploy.sh rhdh` regeneration, the same situation the Argo CD plugin's
  `pluginConfig` block further up is already in (see demo 9's "If something goes wrong").
* [`ansible/README.md`](../../ansible/README.md) — the maintenance doc: how to add a playbook, how
  to change a workflow's graph without the next `bootstrap` silently reverting it, credential
  rotation, what is deliberately not production-grade here.

---

## Prove it from the terminal

```bash
./deploy.sh ansible reset
./deploy.sh ansible run install-postgres-safe && sleep 20 && ./deploy.sh ansible status   # Deployment appears, no approval
./deploy.sh ansible run install-postgres-safe && sleep 10 && ./deploy.sh ansible status   # pending approval
./deploy.sh ansible approve && sleep 20 && ./deploy.sh ansible status                     # Deployment replaced
./deploy.sh ansible run delete-postgres && sleep 5 && ./deploy.sh ansible status          # pending approval
./deploy.sh ansible approve && sleep 10 && ./deploy.sh ansible status                     # gone
```

## Reset

```bash
./deploy.sh ansible reset     # removes the demo PostgreSQL objects directly (not through Ansible)
```

To remove the whole demo: `./deploy.sh ansible destroy` (namespaces only; the AAP operator
Subscription/CSV stay installed, same convention as every other optional layer in this repository).

## If something goes wrong

* **`./deploy.sh ansible setup` stops with "Secret 'aap-registry-pull-secret' not found":** you
  haven't created the registry.redhat.io pull secret yet — see `ansible/README.md` "Red Hat
  subscription and the image pull secret", then re-run.
* **`./deploy.sh ansible setup` times out waiting for the AAP operator:** check
  `oc get packagemanifest ansible-automation-platform-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}'`
  — the `channel: stable-2.6` in `stack/ansible/operator.yaml` has moved on some catalog
  snapshots; edit it to match and re-run.
* **AAP pods stuck `ImagePullBackOff`:** almost always the pull secret — confirm
  `oc get secret aap-registry-pull-secret -n aap` exists and that
  `oc get serviceaccount default -n aap -o jsonpath='{.imagePullSecrets}'` includes it; re-run
  `./deploy.sh ansible setup` to re-link it if not.
* **AAP pods stuck `Pending`:** the demo sizing in `stack/ansible/aap.yaml` is deliberately small;
  `oc describe pod -n aap` for the actual reason (usually PVC provisioning or node resources).
* **Project sync fails ("could not resolve host" / 403):** `./deploy.sh gitlab` must have already
  pushed this repository and created the automation token `bootstrap()` reads
  (`gitlab-automation-token` in namespace `gitlab`); re-run `./deploy.sh ansible bootstrap` after.
* **A Job Template run fails with a Kubernetes 403:** the `ansible-demo-cluster` Credential is
  scoped to exactly what `stack/ansible/rbac.yaml` grants; a new resource kind in a playbook needs
  a matching rule there first, then `oc apply -k stack/ansible` and
  `./deploy.sh ansible bootstrap` to refresh the Credential's token.
* **The "Ansible" tab never appears in Developer Hub, with no error:**
  `./deploy.sh rhdh-plugins ansible` — if it prints nothing, this RHDH version's extensions
  catalog / your `registry.redhat.io` entitlement does not bundle
  `ansible-plugin-backstage-rhaap` yet. Either accept Part A as a config walkthrough for now, or
  build the plugin yourself from the open-source
  [`ansible/ansible-backstage-plugins`](https://github.com/ansible/ansible-backstage-plugins) with
  `@red-hat-developer-hub/cli` — the exact same packaging steps as
  [demo 12](12-custom-plugin-pod-status.md) — and point `dynamic-plugins.yaml` at your own image
  instead of `registry.redhat.io`.
* **A software template fails with "Authorization token not provided":** `AAPTokenField` needs the
  `ansible-plugin-backstage-self-service` frontend plugin installed; without it, edit the template
  to a plain `ui:widget: password` field and paste the value from `./deploy.sh ansible token`.
* **Workflow launches but nothing happens, no approval, no error:** `values.template` must match
  the Workflow Job Template's exact name in AAP (`install-postgres-safe` / `delete-postgres`);
  confirm with `./deploy.sh ansible urls` then AAP > Automation Execution > Templates.
* **Re-ran `./deploy.sh ansible bootstrap` after editing `workflows/*.json`, but nothing changed:**
  `create_workflow()` only *creates* a workflow by name — it will not touch one that already
  exists. Delete that one Workflow Job Template in AAP first (see `ansible/README.md`
  "Changing a workflow"), then bootstrap again.
