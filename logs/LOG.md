# NetBird / Rancher / ArgoCD Bootstrap — Activity Log

## 2026-07-25 — Session start: recon

Read `task.md` (full brief with pre-answered open questions). Ran environment
recon before touching anything.

**Machine facts:**
- Host: `instance-arm`, Oracle Cloud VM (KVM), **Ubuntu 22.04.5 LTS, arm64/aarch64**
- User: `ubuntu`, passwordless sudo available
- Docker 29.0.4 installed. No k3s/kubectl/helm/terraform present yet.
- Disk: 45G total, 25G free. RAM: 23Gi total, ~14Gi available.
- Public IPv4: `157.151.171.157` (directly reachable, confirmed by task owner).

**Pre-existing services on this box (not mentioned in task.md — this is a shared
personal server, not a dedicated machine):**
- OpenVPN server listening on UDP 1194 (own CA at `~/openvpn-ca`)
- SSH on tcp/22 and tcp/2022
- A Minecraft server (`mcserver-mc-1` docker container) on tcp/25565
- Tor client on 9050 (local only)
- `dynamicdns.py` script present in home dir — likely keeps `arec.me` DNS updated
  with this machine's IP (explains why base domain already resolves).

**Firewall:** `ufw` is inactive, but raw `iptables` INPUT chain has explicit
rules for OpenVPN(1194)/SSH(22,2022)/loopback/related-established/icmp, ending
in a default **REJECT**. Any new port (80, 443, k3s, NetBird relay UDP) will be
silently blocked until an explicit ACCEPT rule is added for it. Must add rules
without disturbing the existing ones.

**DNS check:**
- `arec.me` → `157.151.171.157` (already correct)
- `rancher.arec.me` → **no record yet**
- `netbird.arec.me` → **no record yet**
- Action needed from user: add A records for both subdomains pointing at
  `157.151.171.157` before cert-manager can issue certs.

**Risk flagged to user:** machine is **arm64**, not amd64. Rancher server's
arm64 support needs to be verified before committing to the plan — if
unsupported, this is a genuine blocker per task.md's own instruction to stop
and flag rather than quietly work around it. Kicked off background research on
this plus NetBird's Helm chart, OIDC redirect URI, and required ports.

**Project layout created:**
```
/home/ubuntu/personal-server/
  task.md
  logs/LOG.md          (this file)
  terraform/            (Phase 1 — ArgoCD install only, *.tf.txt convention)
  gitops-repo/          (Phase 2 — app-of-apps repo, to be git-init'd)
```

## 2026-07-25 — Research findings (Rancher arm64, NetBird deployment/OIDC/ports)

**1. Rancher server on ARM64: experimental, not GA, not recommended for prod.**
Rancher's own docs (current v2.13, and older releases) title the page "Running
on ARM64 Mixed Architecture (**Experimental**)" and explicitly say: *"we do not
recommend using ARM64 mixed architecture based nodes in a production
environment."* Monitoring, alerting, notifiers, pipelines, logging, and
catalog-app installs are untested on arm64. rancher/rancher images do ship
arm64 builds and it does run, but this has sat at "experimental" for years
with no GA path announced. **Flagged to user for a go/no-go decision** — this
is the kind of genuine blocker task.md says to stop and flag rather than
silently work around.
Sources: [Rancher ARM64 docs](https://ranchermanager.docs.rancher.com/how-to-guides/advanced-user-guides/enable-experimental-features/rancher-on-arm64)

**2. NetBird's official Kubernetes deployment path is weak — decided to
hand-write manifests instead of using the stale Helm chart.**
NetBird's actual recommended self-hosted deployment (2026) is **Docker
Compose** with a new "combined container" architecture: one `netbird-server`
image (management+signal+relay+STUN) behind Traefik, configured via a single
`config.yaml`. The official Helm chart (`netbirdio/helms`) is stuck ~20 minor
versions behind current NetBird (open issue
[netbirdio/helms#39](https://github.com/netbirdio/helms/issues/39)), missing
embedded-IdP support entirely. Rather than fight a stale chart or break the
GitOps architecture by running NetBird outside k3s via Compose, the plan is to
**hand-write plain Kubernetes manifests** (Deployment, Service, Ingress,
ConfigMap, Secret) for the current combined-container image and manage them
as a plain-manifest ArgoCD child Application — task.md's own repo layout
comment already anticipates this ("child Application → NetBird
manifests/**Helm**"), so this stays inside originally authorized scope.
Images are confirmed multi-arch (linux/arm64 included), so this is not an
arm64 blocker, just a "the Helm chart is unusable" one.

**3. Known open bug: Google OIDC login is broken on stock config.**
[netbirdio/dashboard#690](https://github.com/netbirdio/dashboard/issues/690) —
NetBird's dashboard CSP `connect-src` only allow-lists the OIDC *authority*
host (`accounts.google.com`), never Google's separate token endpoint
(`oauth2.googleapis.com`) or JWKS host, so the browser-side PKCE token
exchange gets blocked by CSP. Open as of today. **Plan:** set
`NETBIRD_CSP=https://oauth2.googleapis.com https://www.googleapis.com https://openidconnect.googleapis.com`
in the NetBird manifests from the start — this is a known, documented
workaround, not exploratory debugging.

**4. Redirect URIs / OIDC config for Google (final, to give user):**
- Dashboard login: `https://netbird.arec.me/auth` and
  `https://netbird.arec.me/silent-auth` (or `/nb-auth` + `/nb-silent-auth`
  depending on exact version pinned — will confirm exact paths once the
  manifests/image tag are chosen) as Authorized redirect URIs.
- CLI/device flow: `http://localhost:53000` also required as a redirect URI.
- Authorized JavaScript origins: `https://netbird.arec.me`, `http://localhost`.
- Scopes: `openid profile email`. Google does **not** provide a `groups`
  claim — group-based policies in NetBird will need manual group management
  (acceptable, not a blocker, just noting it since task.md flagged to stop on
  genuine OIDC gaps — this one has a documented workaround, not a dead end).
- NetBird docs' own advice: create the OAuth client with redirect URIs
  *empty* first, deploy NetBird, copy the exact URL it displays/generates,
  then paste back into Google Console — safer than hardcoding a guessed path.

**5. Ports — simpler than task.md assumed (no dedicated WireGuard 51820 needed):**
Current combined-container setup only needs, on the single external IP:
- TCP 80, 443 (Traefik/Ingress — dashboard, management, signal, relay all
  multiplexed over 443)
- UDP 3478 (STUN, `NB_STUN_PORTS`)
Legacy ports (33073 mgmt gRPC, 10000 signal, 33080 relay, 49152-65535 TURN
range) only needed for pre-v0.29 client compatibility — skipping those.

Next: presenting consolidated plan + the Rancher arm64 decision to the user
before any system-modifying step (k3s install, firewall rules, terraform
apply).

## 2026-07-25 — Decision: drop Rancher entirely

User's call on the arm64-experimental risk: **do not deploy Rancher at all.**
Cluster management stays plain k3s/kubectl (k3s ships its own lightweight
management, which is sufficient for a single-node box). Scope is now:

- Terraform: k3s (Phase 0, shell) + ArgoCD install (Phase 1) — unchanged.
- ArgoCD-managed apps: **cert-manager** and **NetBird** only. No `rancher.yaml`
  child Application, no `rancher/values.yaml`, no `rancher.arec.me` hostname/
  DNS record needed.
- `netbird.arec.me` is now the only hostname cert-manager needs to issue a
  cert for.

This also removes the biggest unresolved risk (arm64 support) from the
critical path. Proceeding to get user go-ahead on the remaining
system-modifying steps: k3s install, firewall rules (TCP 80/443, UDP 3478),
terraform apply.

User confirmed: go ahead with k3s install, and open 80/443/3478 (user was
skeptical of the need for 80/443 but deferred once I explained: 80 is
required for Let's Encrypt HTTP-01 challenge validation, 443 is the actual
public HTTPS endpoint for the NetBird dashboard/API — both genuinely needed,
not optional).

## 2026-07-25 — Phase 0: k3s installed

- Ran official install script (`curl -sfL https://get.k3s.io | sh -`), default
  options (Traefik + servicelb + local-path-provisioner all enabled — default
  k3s ships these, and Traefik gives us a ready-made Ingress controller/LB
  that binds host ports 80/443 directly via klipper-lb, which lines up with
  our firewall plan and NetBird's own Traefik-based reference setup).
- Result: k3s v1.36.2+k3s1, single control-plane node `instance-arm`, Ready.
  containerd 2.3.2-k3s2, arm64.
- Copied `/etc/rancher/k3s/k3s.yaml` → `~/.kube/config` (chmod 600, owned by
  ubuntu). Note: k3s's embedded `kubectl` (symlinked to the `k3s` binary)
  ignores `~/.kube/config` and defaults to `/etc/rancher/k3s/k3s.yaml`
  (root-only permissions) unless `KUBECONFIG` is explicitly set — added
  `export KUBECONFIG=$HOME/.kube/config` to `~/.bashrc` to fix this
  permanently for the ubuntu user, and installed a real standalone `kubectl`
  via helm/terraform tooling below rather than relying on the k3s symlink.
- Installed supporting CLIs (not present before): `helm` v3.21.3,
  `terraform` v1.15.8 — both arm64 builds, both required for Phase 1.

Next: write Terraform (`.tf.txt` files per convention) to install ArgoCD via
the `helm` provider into an `argocd` namespace — Terraform's entire scope,
nothing else.

## 2026-07-25 — Phase 1: Terraform written (ArgoCD + optional root Application)

Files in `terraform/`: `providers.tf`, `variables.tf`, `argocd.tf`,
`root-app.tf`, `outputs.tf`, `terraform.tfvars`.

- Checked real current chart versions via `helm search repo` rather than
  guessing from training data: ArgoCD Helm chart `10.2.1` (app v3.4.5),
  pinned in `variables.tf`.
- `argocd.tf`: `helm_release` for `argo/argo-cd` into the `argocd` namespace,
  server running in `insecure` mode (no public Ingress/hostname for ArgoCD —
  task.md never asked for one; reachable via `kubectl port-forward`).
- `root-app.tf`: the one authorized exception — a `kubectl_manifest` (not the
  core `kubernetes_manifest`) for the root app-of-apps `Application`. Used the
  `gavinbunney/kubectl` provider specifically to avoid a chicken-and-egg
  problem: `kubernetes_manifest` validates against the target CRD's schema at
  plan time, which doesn't exist until the ArgoCD helm_release in the same
  apply has run. Gated behind `var.create_root_app` (default `false`) until
  the GitOps repo has real content pushed to a real GitHub URL.
- `gitops_repo_path` defaults to `gitops-repo/apps` (not `apps`) since the
  whole `personal-server` directory is the git repo root now, not a
  dedicated GitOps-only repo — see below.

**Deviation from task.md's convention, per explicit user instruction:**
user asked to rename `.tf.txt` → `.tf` (not copy-and-keep-both) and then to
delete the `.tf.txt` originals. Done — only real `.tf`/`terraform.tfvars`
files exist now, no `.tf.txt` source-of-truth copies. Noting this since
task.md's own text describes the opposite convention (keep `.tf.txt` as the
readable source, generate `.tf` at apply time); the user's live instruction
overrides that.

## 2026-07-25 — Git / GitHub setup

- User wants the **entire `personal-server` directory** (task.md, terraform/,
  gitops-repo/, logs/) as one git repo, not a separate dedicated GitOps-only
  repo. `git init` run at `/home/ubuntu/personal-server`, branch renamed to
  `main`. Added `.gitignore` (terraform state/.terraform, Claude Code local
  settings, backstop against accidental plaintext secrets).
- Generated a dedicated SSH keypair for GitHub push access:
  `~/.ssh/github_personal_server` (ed25519), with `~/.ssh/config` pinning
  `github.com` to use it (`IdentitiesOnly yes`). Public key handed to user to
  add to GitHub (as account SSH key or repo deploy key with write access).
  No prior GitHub keys existed on this box, so nothing was overwritten.
- GitHub username: `arestrepo99`. Repo name assumed `personal-server`
  (matching the directory) pending user confirmation/actual remote URL.
- `terraform.tfvars`'s `gitops_repo_url` still holds a PLACEHOLDER — must be
  updated to the real GitHub URL before `create_root_app` is flipped to
  `true`.

Next: build out `gitops-repo/` content (sealed-secrets, cert-manager +
ClusterIssuer, NetBird hand-rolled manifests), get the real GitHub remote
URL from the user, push, then `terraform apply`.

## 2026-07-25 — User ran `terraform apply` directly (Phase 1 live)

User applied Phase 1 themselves while other work was in progress. ArgoCD is
up and healthy in the `argocd` namespace: argocd-server, dex-server,
application-controller, applicationset-controller, notifications-controller,
redis, repo-server, all Running. Confirmed reachable via
`kubectl -n argocd port-forward svc/argocd-server 8080:443` (running in the
background on this VM, bound to loopback only -- reached from the user's
laptop via their own `ssh -L 8080:localhost:8080 ...` tunnel, nothing opened
on the public firewall for this). Admin login retrieved from
`argocd-initial-admin-secret`.

## 2026-07-25 — `gitops-repo/` renamed to `gitops/`

User's call -- the whole `personal-server` directory is the repo, so a
subdirectory named `gitops-repo` was redundant/confusing. Renamed; fixed the
two references that existed at the time (`terraform/variables.tf`'s
`gitops_repo_path` default, and `cert-manager-issuer.yaml`'s `path`). All
GitOps content below lives under `gitops/`, not `gitops-repo/`.

## 2026-07-25 — Phase 2: NetBird manifests + Google Cloud Console info

Hand-wrote plain manifests in `gitops/netbird/` (per the earlier decision to
skip the stale official Helm chart):

- **Image**: confirmed `netbirdio/netbird-server` exists on Docker Hub (the
  2026 "combined container" image: management+signal+relay+STUN in one
  process) via the Docker Hub API directly, since further doc/tag research
  got interrupted mid-session. Pinned to `:latest` in `deployment.yaml` with
  an explicit comment flagging this needs pinning to a real version tag
  before production use -- tag-level lookups were blocked repeatedly this
  session, so this is a known gap, not an oversight.
- **Dashboard** (`netbirdio/dashboard`) confirmed to still be a separate
  container/image even in the combined-container architecture (this is also
  where the CSP/Google bug, dashboard#690, actually lives) --
  `dashboard-deployment.yaml` bakes in the `NETBIRD_CSP` workaround from the
  start.
- **`config.yaml.template`**: schema confirmed directly against
  `netbirdio/netbird` main branch's `combined/config.yaml.example` (fetched
  successfully this session) -- not guessed. Key point: the embedded
  Dex-based auth is *always on*; `auth.issuer` just points at NetBird's own
  URL. Google OIDC is **not** configured via `config.yaml` fields at all --
  it's wired up post-deploy through the dashboard UI (Settings -> Identity
  Providers -> Add Identity Provider), which is exactly what the earlier
  Google Workspace docs research also showed. Set `auth.owner` (email +
  generated password) so there's a non-interactive initial-admin bootstrap
  path (this directly answers task.md's "Rancher bootstrap password" concern
  -- same underlying problem, now on NetBird since Rancher was dropped).
- **Secrets handling**: rather than split ConfigMap (non-secret) vs Secret
  (secret) and risk getting NetBird's env-var-interpolation-in-config.yaml
  support wrong (unconfirmed either way), the *entire* rendered config.yaml
  goes into one Kubernetes Secret, sealed via `kubeseal` into
  `secret-config.sealed.yaml`. Exact generate-and-seal steps written to
  `gitops/netbird/README.md`, to run once the `sealed-secrets` Application
  (wave 0) is confirmed Healthy.
- **Ingress path routing** (`ingress.yaml`): reconstructed from NetBird's
  well-known Traefik routing convention (API/gRPC/OIDC paths -> backend,
  everything else -> dashboard SPA) -- explicitly flagged in the file's
  header comment as the single piece of this deployment that's a best-effort
  reconstruction rather than confirmed against a fetched doc, since doc
  lookups kept getting interrupted. Expect to need adjustment based on real
  404s after first deploy.
- **STUN**: exposed via a dedicated `type: LoadBalancer` Service
  (`netbird-stun`) so k3s's built-in `servicelb` binds UDP/3478 straight to
  the host's public IP -- a ClusterIP alone can't be reached from the
  internet for non-Ingress UDP traffic.
- **PVC**: 5Gi via k3s's default `local-path` StorageClass, `Recreate`
  deployment strategy (sqlite store on ReadWriteOnce -- never run 2 pods).

**Google OAuth client instructions for the user** (once the dashboard is
reachable): Google Cloud Console -> APIs & Services -> Credentials -> Create
Credentials -> OAuth client ID -> Application type "Web application". Leave
redirect URIs empty at creation time. Deploy NetBird, log in with the
`owner` account, go to Settings -> Identity Providers -> Add Identity
Provider -> Google, copy the exact redirect URI NetBird displays, paste it
back into the Google Cloud Console client's Authorized redirect URIs, save,
then paste the resulting Client ID + Client Secret into the NetBird identity
provider form. Full detail in `gitops/netbird/README.md`.

## 2026-07-25 — Git remote + ArgoCD repo credentials

- Repo confirmed: `git@github.com:arestrepo99/personal-server.git`,
  **private**.
- Since it's private, ArgoCD (running in-cluster, separate from the ubuntu
  user's own SSH agent) needs its own git credentials to clone it --
  `terraform/argocd-repo-credentials.tf` creates a `kubernetes_secret`
  labeled `argocd.argoproj.io/secret-type: repository` in the `argocd`
  namespace, reusing the *same* deploy key already generated for `git push`
  (`~/.ssh/github_personal_server`) via Terraform's `file()` function --
  no second keypair, no key material pasted into any tracked file. This is
  bootstrap-layer (same class of exception as the root Application):
  ArgoCD needs repo read access before it can fetch even the first manifest
  from that repo, so this credential can't itself be delivered as a
  SealedSecret sitting inside the repo it's needed to read.
- `terraform.tfvars`'s `gitops_repo_url` updated to the SSH form
  (`git@github.com:...`, not `https://...`) to match the SSH-based repo
  credential.
- All `repoURL` fields in `gitops/apps/*.yaml` (netbird, cert-manager-issuer)
  updated to match.

Next: `git add`/commit everything, push to the new GitHub remote, then
`terraform apply` again with `create_root_app = true` so the root
Application starts syncing.
