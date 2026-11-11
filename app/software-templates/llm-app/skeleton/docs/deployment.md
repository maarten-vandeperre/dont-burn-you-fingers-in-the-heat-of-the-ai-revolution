# Deployment

The template created an **Argo CD application** `${{ values.name }}` (OpenShift GitOps) that syncs
`deploy/` of this repository into the namespace `${{ values.name }}`:

| Resource | What it does |
|---|---|
| `BuildConfig` + `ImageStream` | builds the image from this repository (Dockerfile) in the cluster; the first build starts on its own |
| `Deployment`, `Service`, `Route` | runs the application; the image trigger rolls it out after every build |

Every change to `deploy/` on `main` is applied by Argo CD (automated sync, self-heal). Developer Hub
shows the sync status on the **CD** tab and the pods on the **Topology** and **Kubernetes** tabs.

## New code

```bash
oc start-build ${{ values.name }} -n ${{ values.name }} --follow
```

## Open the application

https://${{ values.name }}-${{ values.name }}.${{ values.appsDomain }}
