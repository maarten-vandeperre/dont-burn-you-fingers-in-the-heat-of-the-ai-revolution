# Ansible on this platform: getting started, and how to maintain it

This folder is the whole Ansible side of [demo 11](../docs/demos/11-ansible.md): two playbooks
that install and delete a demo PostgreSQL on OpenShift, and two **Ansible Automation Platform
(AAP)** workflows that wrap them with a mandatory, human **Workflow Approval** before anything is
ever deleted. It is read by a real, in-cluster AAP Controller (`./deploy.sh ansible setup`, see
[`../stack/ansible`](../stack/ansible)) directly from this repository's GitLab mirror -- there is
nothing to build or package, editing a file here and re-syncing the AAP Project is the whole
deployment.

AAP 2.6 fronts Controller (and, if enabled, Hub and EDA) behind a single **Platform Gateway**:
one Route, one login, one token endpoint for everything. This demo only enables Controller
(`stack/ansible/aap.yaml`), and talks to it at `https://<gateway-route>/api/controller/v2/...`
-- same Organizations/Projects/Credentials/Job Templates/Workflow Job Templates/Workflow
Approvals, same Controller REST API shape you'd see documented for any AAP/Controller version,
just proxied through the gateway's host and `/api/controller/v2/` path instead of a bare
Controller host's `/api/v2/`. That gateway-proxied API is also exactly what the Developer Hub
**Ansible plugin** (`ansible.rhaap.*` in `app-config.yaml`) and the two "Ansible: ..." software
templates talk to.

```
ansible/
  ansible.cfg                  laptop-friendly defaults (AAP mostly ignores this -- see below)
  inventory/hosts.ini           one group "demo", host "localhost" -- for laptop runs only
  group_vars/demo.yml           shared defaults every playbook reads (image, sizing, names)
  collections/requirements.yml  kubernetes.core -- for laptop runs; AAP's default execution
                                 environment already bundles it (see the file's own comment)
  playbooks/
    check_postgres.yml           read-only: does the Deployment already exist? fails on purpose
                                  if it does -- that failure is what a workflow branches on
    install_postgres.yml         Secret (generated creds) + PVC + Deployment + Service, idempotent
    delete_postgres.yml          deletes all four, idempotent
  job-templates.json             the 3 AAP Job Templates, as data (name, playbook, description)
  workflows/
    install-postgres-safe.json    nodes + edges of the "safe install" workflow (see diagram below)
    delete-postgres.json          nodes + edges of the standalone delete workflow
```

`job-templates.json` and `workflows/*.json` are not just documentation: `stack/ansible/ansible.sh`
reads them with `jq` and creates the matching objects in AAP via its REST API
(`./deploy.sh ansible bootstrap`, idempotent). **They are the versioned source of truth** for what
exists in AAP -- the same relationship this repository already has between e.g.
`app/deploy/rollouts-demo/*.yaml` and the cluster. If you reconcile AAP by clicking in its UI
instead, the next `bootstrap` run will not know about your click and the two will drift; see
"Changing a workflow" below for the supported way to change one.

---

## Getting started

### 0. Prerequisites

* The platform stack and GitLab: `./deploy.sh stack` (AAP's Project is a Git-backed Project
  pointed at this repository's GitLab mirror, `ai-platform/platform` -- it needs to exist first)
* `oc`, `curl`, `jq` on your laptop (already required by the rest of this repository)
* A **Red Hat Ansible Automation Platform subscription** -- see the next section. Unlike most of
  this repository's add-ons, AAP's Controller/Gateway/PostgreSQL images are not freely pullable;
  without a valid subscription, `./deploy.sh ansible setup` stops with a clear error before it
  gets anywhere near a half-broken install.

### Red Hat subscription and the image pull secret

AAP's own component images (`automation-controller-*`, the gateway, its bundled PostgreSQL) live
on `registry.redhat.io` and need entitlement credentials, not just any OpenShift pull secret:

1. Get a token-based registry service account from
   <https://access.redhat.com/terms-based-registry/> for the "Ansible Automation Platform"
   repository (requires an active AAP subscription on your Red Hat account). Download its
   `.dockerconfigjson`.
2. Create the namespace and the secret once, before the first `setup` run:
   ```bash
   oc create namespace aap --dry-run=client -o yaml | oc apply -f -
   oc create secret generic aap-registry-pull-secret -n aap \
     --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=<downloaded-secret.json>
   ```
3. `./deploy.sh ansible setup` links that secret to the namespace's `default` ServiceAccount too
   (so the gateway and PostgreSQL pods, which don't go through `spec.controller.image_pull_secrets`,
   can pull as well) -- you only have to create the Secret itself, not wire it up everywhere.

If you skip this, the operator and CRDs still install fine (those come from
`registry.redhat.io` via the OperatorHub catalog image, already covered by any cluster pull
secret with Red Hat credentials), but the Controller/Gateway/PostgreSQL pods sit in
`ImagePullBackOff` forever. `./deploy.sh ansible setup` checks for the Secret before applying the
`AnsibleAutomationPlatform` custom resource and tells you exactly this if it's missing.

### 1. Install AAP and wire everything up

```bash
./deploy.sh ansible setup
```

This, in order:

1. Installs the `ansible-automation-platform-operator` (`redhat-operators` catalog, channel
   `stable-2.6`) into its own namespace, `aap` (Red Hat's own recommended name -- the operator
   refuses to run in `default`).
2. Checks for `aap-registry-pull-secret` (see above) and links it to the namespace's `default`
   ServiceAccount.
3. Creates the `AnsibleAutomationPlatform` custom resource (`stack/ansible/aap.yaml`): Controller
   enabled, Hub and EDA disabled (not needed for this demo), a shared PostgreSQL, a Platform
   Gateway Route. Waits for it to answer `/api/controller/v2/ping/` through the gateway.
4. Creates the `ansible-demo` namespace and the scoped `ServiceAccount`
   (`ansible-postgres-admin`) the playbooks run as -- `get/list/watch/create/update/patch/delete`
   on `Deployments`, `Services`, `PersistentVolumeClaims`, `Secrets`, `ConfigMaps` and `Pods`
   **in that one namespace only** (`stack/ansible/rbac.yaml`). The playbooks can never touch
   anything outside it.
5. Calls `bootstrap()` (see below), which configures Controller itself: the Project, the
   Credential, an Inventory, the 3 Job Templates and the 2 Workflow Job Templates.
6. Creates an AAP Platform Gateway token and stores it in Secret `rhdh-ansible-token` (namespace
   `aap`) -- `./deploy.sh rhdh` picks it up into `rhdh-secrets` as `ANSIBLE_TOKEN` for the
   Developer Hub Ansible plugin and the software templates.

Then wire Developer Hub (renders the catalog, the two new software templates, and tries to enable
the Ansible plugin if this Developer Hub version offers it):

```bash
./deploy.sh rhdh
```

### 2. Look around

```bash
./deploy.sh ansible urls      # AAP Platform Gateway URL + how to get the admin password
./deploy.sh ansible status    # the demo PostgreSQL (if any) + any pending approvals
```

Sign in to AAP as `admin` with the password from
`oc get secret ansible-automation-platform-admin-password -n aap -o jsonpath='{.data.password}' | base64 -d`.
Under **Automation Execution > Templates** you will find the 3 Job Templates and the 2 Workflow
Job Templates; open a Workflow Job Template's **Visualizer** tab to see the graph this README
describes in prose.

### 3. Run it

From Developer Hub: **Create** > **Ansible: install PostgreSQL** (or **Ansible: delete
PostgreSQL**) -- see [demo 11](../docs/demos/11-ansible.md) for the full walkthrough. From the
CLI, for quick iteration while editing a playbook:

```bash
./deploy.sh ansible run install-postgres-safe
./deploy.sh ansible status            # watch for a pending approval
./deploy.sh ansible approve           # or: ./deploy.sh ansible deny
```

---

## How the workflows branch

Both workflows are Workflow Job Templates in AAP Controller; Controller branches on the
**status** of the previous node (`success` / `failure` / `always`), not on a variable, so
`check_postgres.yml`'s only job is to succeed when there is nothing to do and **fail on purpose**
when the database already exists.

```
install-postgres-safe:

  check-postgres --(success, i.e. absent)--------------------------> install-postgres
       |
       +--(failure, i.e. already exists)--> [Workflow Approval] --(approved)--> delete-postgres --> install-postgres
                                                    |
                                                    +--(denied)--> (workflow stops here; database untouched)

delete-postgres (standalone):

  [Workflow Approval] --(approved)--> delete-postgres
       |
       +--(denied)--> (workflow stops here)
```

**The delete step can never run without that approval** in either workflow -- there is no edge
that reaches `delete-postgres` except from an approved `Workflow Approval` node. That is enforced
by the graph itself (see `workflows/*.json`), not by a convention someone could forget to follow.

### Manual approval: how it actually blocks the delete

AAP Controller's **Workflow Approval** is a real node type (`workflow_approval_template`), not a
script: the workflow job literally pauses -- the node shows `pending` -- until a user with the
right permissions calls `POST /api/controller/v2/workflow_approvals/<id>/approve/` (or `/deny/`),
which AAP's own UI, its CLI, or the `ansible.controller` collection all do for you. Nothing
downstream runs, and nothing times out early, until that happens (the node has a 1-hour timeout
here, `workflows/*.json`'s `timeout: 3600`, after which it denies itself automatically).

* **From AAP:** Automation Execution > Jobs > the running workflow job > the paused node >
  **Approve** / **Deny**.
* **From the CLI:** `./deploy.sh ansible approve` (the oldest pending approval) or
  `./deploy.sh ansible approve <id>`; `deny` the same way.
* **From Developer Hub:** the software templates' output links you straight to the AAP job; there
  is currently no in-Backstage approve button for this (AAP's own UI is the place to do it --
  the `ansible-plugin-backstage-self-service` frontend plugin is where Red Hat is adding this kind
  of day-2 AAP interaction over time).

---

## Create and maintain these playbooks and workflows

### Adding or changing a playbook

1. Write it under `playbooks/`, using `group_vars/demo.yml` for anything that might change
   between environments (never hardcode a namespace, image or size in the playbook body).
2. Run it from your laptop first (fast iteration, no AAP round-trip):
   ```bash
   oc login ...                                   # your own cluster credentials, not the demo SA
   cd ansible
   ansible-galaxy collection install -r collections/requirements.yml   # once
   ansible-playbook playbooks/check_postgres.yml   # or install_postgres.yml / delete_postgres.yml
   ```
   This uses *your* `oc` session (via `kubernetes.core`'s default kubeconfig lookup), not the
   scoped `ansible-postgres-admin` ServiceAccount AAP uses -- fine for iterating on the playbook's
   logic, just remember the real run in AAP has a narrower identity, so test
   `oc auth can-i <verb> <resource> -n ansible-demo --as=system:serviceaccount:ansible-demo:ansible-postgres-admin`
   before assuming a new resource kind will work there too.
3. Commit, push (this repo is already the GitLab Project AAP syncs from). Add it to
   `job-templates.json` if it needs its own Job Template, then:
   ```bash
   ./deploy.sh ansible bootstrap
   ```
   `bootstrap()` is idempotent: it looks up every object by name before creating it, so re-running
   it after adding one new entry to `job-templates.json` only creates that one Job Template, it
   does not touch the other two or any workflow.

### Changing a workflow (adding/removing a node or an edge)

`bootstrap()`'s `create_workflow()` only ever *creates* a workflow that does not already exist by
that name in AAP -- on purpose, so a second `bootstrap` run is always safe and never silently
rewrites a workflow someone is in the middle of editing by hand in the Visualizer. To pick up a
change to `workflows/*.json`:

```bash
oc get pods -n aap   # just to confirm AAP's Controller pods are up; optional
# Delete the one workflow you changed (not the whole bootstrap -- Job Templates and the other
# workflow are untouched), then recreate it from the edited JSON:
AAP_URL=$(./deploy.sh ansible urls | awk -F': *' '/^AAP Platform Gateway/{print $2}')
# (or open AAP > Automation Execution > Templates > the workflow > Delete, then:)
./deploy.sh ansible bootstrap
```

For a quick one-off experiment, editing the graph directly in AAP's **Visualizer** is fine --
just copy the result back into `workflows/*.json` afterwards (identifier, `unified_job_template`,
and the edges with their `success`/`failure`/`always` state) so the file stays the source of
truth, and so the next person reading this repository sees what is actually running.

### Credentials

The playbooks' only credential is the `ansible-demo-cluster` Credential in AAP Controller, type
**"OpenShift or Kubernetes API Bearer Token"** (built in) -- its `bearer_token` is the long-lived
token of the `ansible-postgres-admin` ServiceAccount (`stack/ansible/rbac.yaml`), scoped to the
`ansible-demo` namespace only. `bootstrap()` refreshes it from the cluster Secret every run, so
rotating the ServiceAccount's token (`oc delete secret ansible-postgres-admin-token -n
ansible-demo && oc apply -k stack/ansible`) and re-running `./deploy.sh ansible bootstrap` is all
a credential rotation takes. **Never** put a real credential value in a playbook, `group_vars/`,
or either JSON file -- they are all plain Git content.

### Idempotency and re-runs

Every task uses `kubernetes.core.k8s` with `state: present`/`absent`, which only changes what
differs from the live cluster object -- running `install_postgres.yml` twice in a row, or
mid-demo after a failed run, does nothing the second time except (harmlessly) re-assert the same
Deployment/Service/PVC spec. The one exception is the credentials Secret: it is only *created*
when missing (`install_postgres.yml`'s first two tasks), never regenerated, so a re-install after
a partial failure reuses the same database password instead of silently rotating it under a
running application.

### Change the Postgres version or sizing

One file, `group_vars/demo.yml` -- `postgres_image`, `postgres_pvc_size`,
`postgres_cpu_*`/`postgres_memory_*`. Push, then either re-run the Job Template in AAP (Project
syncs the new file automatically before the job starts) or `./deploy.sh ansible run
install-postgres-safe` from the CLI. The Deployment's `strategy: {type: Recreate}` means a sizing
change on an *existing* database causes a short restart, not a rolling update (PostgreSQL + RWO
PVC cannot do more than one pod anyway).

### Day 2: making this production-grade (what this demo deliberately skips)

* **AAP's own database.** `stack/ansible/aap.yaml` uses the operator-managed shared PostgreSQL on
  a single PVC -- fine for a demo, not for anything you depend on; point `spec.database` at an
  external, backed-up PostgreSQL instead (see the AAP Operator's "Configuring the database" docs).
* **Execution environment.** This demo relies on whichever default execution environment your AAP
  instance ships bundling `kubernetes.core` (check Automation Execution > Infrastructure >
  Execution Environments). For anything beyond a demo, build and pin a custom EE with
  `ansible-builder` so a change to the default image never changes what a job template runs.
* **Approvals as a real control, not just a UI pause.** AAP Controller's RBAC decides *who* may
  approve -- give the "Approve" permission on these two Workflow Job Templates only to the team
  that owns this database, not to every AAP user, via an AAP Team/Role, not the shared admin
  account this demo uses throughout.
* **Scheduling and notifications.** AAP Workflow Job Templates support Notifications (Slack,
  email, webhook) on approval-pending and on completion -- wire one to whoever is supposed to act
  on a pending approval, instead of relying on someone noticing it in the UI.
* **High availability and sizing.** This demo's `aap.yaml` is deliberately small (single replica,
  trimmed resource requests). Production AAP sizing (replica counts, `*_resource_requirements`)
  is covered in Red Hat's own AAP Operator sizing guide -- revisit it before depending on this
  instance for anything beyond demos.
