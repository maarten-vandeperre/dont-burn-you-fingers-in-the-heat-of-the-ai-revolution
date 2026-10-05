# Trusted software supply chain (TSSC)

From a signed commit to a signed, checked, deployed image, on the same cluster as the AI platform.

```
Dev Spaces ──git commit -S (gitsign, Keycloak login)──> GitLab ──webhook──> Tekton (tssc-ci)
                    │                                                          │
                    └─ certificate from Fulcio, entry in Rekor                 │
                                                                               ▼
 clone ─> verify-commit ─> ci-tests ─> build-image ─> sign-image ─> sbom ─> tpa-check ─> acs-checks ─> push-release ─> argocd-sync
          gitsign verify    Gradle      buildah        cosign +       syft +   Trusted     ACS (or       :release      Argo CD app
          (RHTAS)                                      Rekor          attest   Profile     simulated)    tag           ai-demo
                                                                               Analyzer
```

| Component | Role | Installed by |
|---|---|---|
| Red Hat Trusted Artifact Signer | Sigstore: Fulcio (certificates for Keycloak identities), Rekor (transparency log), TUF (trust root), CLI server | `tssc setup` (operator + `Securesign`) |
| Red Hat Trusted Profile Analyzer 2 | SBOM store and vulnerability analysis | `tssc setup` (Helm chart, needs `helm` 3.17+) |
| OpenShift Dev Spaces | browser IDE; commits signed with gitsign | `tssc setup` (operator + `CheCluster`) |
| OpenShift Pipelines | the pipeline and the GitLab trigger | platform stack |
| Red Hat build of Keycloak | identities: realm `demo`, user `admin@demo.example.com` | platform stack (`tssc setup` adds clients) |
| Advanced Cluster Security | image and deployment checks | optional: Secret `acs-central` in `tssc-ci`, otherwise simulated |
| OpenShift GitOps | deploys the signed digest | platform stack (`./deploy.sh app gitops <url>` for the app; otherwise simulated) |

## Commands

```bash
./deploy.sh tssc setup              # everything (repeatable); --tpa-importers, --skip-tpa, --skip-devspaces
./deploy.sh tssc run                # start the pipeline on main; --allow-unsigned, --gate fail, --revision
./deploy.sh tssc verify             # verify ai-demo/coffee-menu:release: signature, SBOM attestation, Rekor
./deploy.sh tssc urls               # all links
./deploy.sh tssc destroy            # CI namespace, RHTPA, RHTAS instance (operators stay)
```

Prerequisites: the platform (`./deploy.sh stack`), the demo apps (`./deploy.sh app all`), GitLab
(`./deploy.sh gitlab`), and `helm` 3.17+ on your machine for Trusted Profile Analyzer.

## Design choices

* **Commits are signed keyless by a person** (gitsign, Keycloak login). The signature certificate
  names the user's verified email and is recorded in Rekor; the pipeline checks identity and issuer.
* **In Dev Spaces, gitsign uses the copy-the-code login**: the browser login cannot call back into a
  workspace, so `sign-setup.sh` makes the browser openers fail and gitsign prints a link and asks
  for the code Keycloak shows (redirect URI `urn:ietf:wg:oauth:2.0:oob`). Works with every gitsign.
* **The image is signed by the pipeline with a cosign key** kept in Secret `tssc-ci/cosign-signing`
  (generated in the cluster) and still recorded in RHTAS Rekor. Keyless signing for the pipeline
  itself would need extra Keycloak audience mappings.
* **The tools image** is built in the cluster with the cosign, gitsign, rekor-cli and ec clients
  from this cluster's RHTAS CLI server, so client and server versions always match.
* **Trusted Profile Analyzer API**: `/api/v3` with fallback to `/api/v2`. Vulnerability data comes from
  importers that are off by default (several GB); `--tpa-importers` turns on the CVE list and GitHub
  advisories. Without them the SBOM is stored and browsable, with no advisories yet.
* **The pipeline runs in `tssc-ci`, outside the service mesh** (no sidecars in pipeline pods) and
  pushes to the `ai-demo` image streams.

## Files

| Path | Contains |
|---|---|
| `tssc.sh` | setup, run, verify, urls, destroy |
| `operators/` | subscriptions: `rhtas-operator`, `devspaces` |
| `rhtas/securesign-v1.yaml`, `-v1alpha1.yaml` | the RHTAS instance; the script picks the version the operator serves |
| `rhtpa/` | PostgreSQL, Helm values, importers |
| `devspaces/` | `CheCluster`; `sign-setup.sh`, `sign-commit.sh`, `verify-commit.sh` (devfile commands) |
| `ci/` | namespace, RBAC, tools image build, the pipeline, the GitLab trigger |
| `generated/signing.env` | the RHTAS endpoints of this cluster, written by `tssc setup` |
| `../../devfile.yaml` | the Dev Spaces workspace definition with the three signing commands |

Demo guide: [docs/demos/08-trusted-software-supply-chain.md](../../docs/demos/08-trusted-software-supply-chain.md).
