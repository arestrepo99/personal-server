# `app` — the shared chart for everything with a web UI

One chart, reused by every workload on this cluster that is "a container
listening on a port that should be reachable at `something.arec.me` over
HTTPS". Adding an app should mean writing ~15 lines of values, not another
copy of deployment/service/ingress.yaml.

It renders exactly three objects: a `Deployment`, a `ClusterIP` `Service`
(always port 80, forwarding to whatever port the container uses), and an
`Ingress` annotated for cert-manager.

## How DNS and TLS work — the automatic part

**DNS.** `arec.me` has a wildcard `*` A record in Namecheap pointing at this
host. Any new subdomain therefore already resolves; there is no per-app DNS
step and no Namecheap API credential in the cluster. Explicit host records
(`netbird`, `cloudarm`, …) still take precedence over the wildcard — DNS
resolution always prefers an exact match — so adding the wildcard did not and
cannot override them.

If the host's public IP changes, the existing `dynamic-dns` relay
(`gitops/dynamic-dns/`) updates the record through Namecheap's DDNS endpoint;
add `*` as a DDNS-enabled host there and every subdomain follows the IP at
once.

**TLS.** The `cert-manager.io/cluster-issuer` annotation on the Ingress is the
entire mechanism. cert-manager sees the Ingress, creates a `Certificate` for
the host in `spec.tls`, solves the ACME HTTP-01 challenge over that same
Ingress, and stores the result in `<release>-tls`. It then **re-issues
automatically at roughly two-thirds of the certificate's lifetime** (~30 days
before a 90-day Let's Encrypt cert expires). Renewal needs no cron job, no
manual step, and no redeploy — the refreshed Secret is picked up by Traefik in
place.

The issuer is `letsencrypt-prod` (`gitops/cert-manager/cluster-issuer.yaml`).
Because it is production Let's Encrypt, mind the rate limits when iterating:
50 certificates per registered domain per week, and 5 duplicate-hostname
failures per hour. If you are debugging issuance, add a staging ClusterIssuer
rather than burning prod quota.

## Adding a new app

Copy `gitops/apps/cup.yaml`, change the name, image, and host. That's it —
the root app-of-apps watches `gitops/apps/`, so committing the file deploys it.

```yaml
spec:
  source:
    path: charts/app
    helm:
      releaseName: myapp
      values: |
        image:
          repository: ghcr.io/arestrepo99/myapp
          tag: "abc1234"
        containerPort: 8080
        healthPath: /healthz
        ingress:
          host: myapp.arec.me
  destination:
    namespace: myapp
```

Every value is documented inline in `values.yaml`. Two worth knowing about:

- **`healthPath: ""`** switches both probes to a bare TCP check. Use it for
  any app whose health endpoint makes an *external* round-trip back through
  its own public URL — gating readiness on that deadlocks, because Kubernetes
  only routes Ingress traffic to pods that are already Ready. This is not
  hypothetical; it cost a debugging session on NetBird (see `logs/LOG.md`,
  2026-07-25, bug #4).
- **`imagePullSecrets: [ghcr]`** for a private GHCR package. The Secret is
  created by Terraform, not by this chart — see below.

## Private images

A GHCR package is private by default, and an anonymous pull fails with
`denied`/`unauthorized`. Two options:

1. **Make the package public** — in the source repo,
   `./scripts/publish-container.sh --push --public`. Nothing else to do.
2. **Keep it private** — add the app's namespace to `ghcr_namespaces` in
   `terraform/variables.tf`, set `github_token` in
   `terraform/secrets.auto.tfvars` (gitignored; see
   `secrets.auto.tfvars.example`), `terraform apply`, then set
   `imagePullSecrets: [ghcr]` in the app's values.

A `Secret` is namespace-scoped, so each namespace running a private image
needs its own copy — hence the list rather than a single namespace.

## Deliberate non-goals

No PVCs, no StatefulSet, no ConfigMap mounting, no multi-container pods. This
chart is for stateless HTTP workloads. Anything that needs more than that
belongs in its own directory under `gitops/`, the way NetBird does — forcing
it into this chart would make it worse for the simple case, which is the case
it exists to serve.
