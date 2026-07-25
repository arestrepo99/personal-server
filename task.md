# NetBird Self-Hosted on Rancher + ArgoCD — Agent Bootstrap Brief

## Goal

Deploy a self-hosted [NetBird](https://netbird.io) instance (WireGuard-based mesh VPN control plane: management server, signal server, dashboard, and identity provider) onto a **Rancher-managed Kubernetes cluster**, following GitOps via **ArgoCD**, bootstrapped with **Terraform**.

**Starting state of the machine: Docker is already installed, nothing else.**

**Architecture — the boundary between Terraform and ArgoCD is strict and narrow:**

- **Terraform's only job is to get a Kubernetes cluster running and install ArgoCD onto it.** Nothing else. Not cert-manager, not Rancher, not NetBird.
- **ArgoCD then deploys everything else** — cert-manager, Rancher, NetBird, and any future workloads — via GitOps (an "app of apps" pattern: one root ArgoCD `Application` that points at a repo containing child `Application` manifests for cert-manager, Rancher, and NetBird).

Sequence:

1. Install **k3s** on the machine (this one step can't be done by Terraform's Kubernetes/Helm providers, since no cluster exists yet — do it via the official install script or a `local-exec`/shell step).
2. Use **Terraform** to install **ArgoCD** into the freshly created k3s cluster (Helm chart via Terraform's `helm` provider, or the ArgoCD install manifest via `kubernetes_manifest`). This is Terraform's entire scope — stop here.
3. Everything downstream — **cert-manager**, **Rancher** (hostname `rancher.arec.me`), and **NetBird** (hostname `netbird.arec.me`) — is deployed and managed by ArgoCD, driven by manifests/Helm values living in a Git repo that ArgoCD watches. Terraform never touches these resources directly, and re-running Terraform should not conflict with what ArgoCD manages.

**Domain / hostnames:**
- Rancher UI: `rancher.arec.me`
- NetBird dashboard/management: `netbird.arec.me`
Both need DNS A records pointing at this machine's reachable IP before cert-manager can issue TLS certs for them.

**Identity provider decision: Google login (OIDC via Google Identity) — final, decided.** Creating a Google OAuth 2.0 client and using it for login is free for standard/personal usage (no cost for OAuth client creation or normal-volume sign-ins). No Zitadel fallback — build directly against Google OIDC. If the agent hits a genuine technical blocker (e.g. NetBird requiring an OIDC claim/scope Google doesn't provide), stop and flag it to the user rather than silently switching providers.

## Why this architecture

- **Rancher** manages the underlying cluster(s) — RBAC, cluster lifecycle, multi-cluster visibility.
- **ArgoCD** owns continuous deployment of the NetBird Helm chart/manifests from a Git repo — so any change to NetBird config is a git commit, not a manual `kubectl apply`.
- **Terraform** only runs once (or on infra changes) to stand up the bootstrap layer: namespace, TLS/secret prerequisites, and the ArgoCD `Application` CR pointing at the NetBird manifests repo.

## Prerequisites the agent must gather before starting

Already decided — do not re-ask these:

- **Terraform scope: install k3s (via script) + ArgoCD only.** Everything else (cert-manager, Rancher, NetBird) is deployed by ArgoCD via GitOps, not Terraform.
- **Hostnames:** Rancher → `rancher.arec.me`, NetBird → `netbird.arec.me`. Confirm DNS A records for both point at this machine's reachable IP before requesting TLS certs.
- **Identity provider:** Google OIDC login for NetBird (no Zitadel fallback).
- **Starting point:** machine has Docker only — no k8s, no ArgoCD, no Rancher yet.

Still ask the user (or check environment) for:

1. **Machine specs / access** — single node (k3s is the right call) or will more nodes join later? SSH/root access confirmed?
2. **Public IP / networking** — is this machine directly internet-reachable, or behind NAT/a router needing port forwarding for 80/443 and the WireGuard UDP port?
3. **Git repo for GitOps** — where do the ArgoCD `Application` manifests (root "app of apps" + child apps for cert-manager, Rancher, NetBird) live? If none exists, agent should create one and confirm the branch. This is the single source of truth ArgoCD watches.
4. **Rancher admin bootstrap password** — Rancher's first-run setup needs an initial admin password; since Rancher itself is now deployed by ArgoCD (not interactively), agent needs a plan for setting this non-interactively (e.g. a Helm value or a Secret pre-created for Rancher to pick up) — flag this as a design detail to work out, not something to hand-wave.
5. **Google OAuth client** — the user needs to create an OAuth 2.0 Client ID in Google Cloud Console (APIs & Services → Credentials) with `netbird.arec.me`'s callback URL as an authorized redirect URI. Agent should tell the user the exact redirect URI to register once NetBird's OIDC callback path is known, then collect the resulting Client ID/Secret from the user to store as a Kubernetes Secret (created how? — see open questions; likely a manually-applied Secret or external-secrets integration, since ArgoCD apps shouldn't have raw secrets committed to git).
6. **Google Cloud project** — existing project or new one for the OAuth client?
7. **cert-manager issuer preference** — Let's Encrypt staging vs prod to start (recommend staging first to avoid rate limits while testing).

**Do not assume defaults for anything not explicitly decided above — confirm with the user first**, since wrong DNS/IdP/repo choices are expensive to unwind later.

## High-level task sequence

### Phase 0 — k3s install (outside Terraform's scope, cluster doesn't exist yet)

1. **Install k3s** (single-node Kubernetes) via the official install script (`curl -sfL https://get.k3s.io | sh -`). Confirm resulting kubeconfig at `/etc/rancher/k3s/k3s.yaml` is copied/merged somewhere Terraform, Helm, and kubectl can all target it.

### Phase 1 — Terraform: install ArgoCD only

This is Terraform's **entire** scope. Nothing else gets created here.

- Use Terraform's `helm` provider (or `kubernetes_manifest` with the official install YAML) to install ArgoCD into an `argocd` namespace on the k3s cluster.
- Optionally, also create the **root "app of apps" `Application`** resource here (still within ArgoCD's own CRDs, still a thin bootstrap step) pointing at the GitOps repo — this is the one exception, since it's what hands control over to ArgoCD. Everything that root Application references (cert-manager, Rancher, NetBird) is then ArgoCD's problem, not Terraform's.
- **Important per user convention: write all Terraform files with a `.txt` extension (e.g. `main.tf.txt`) instead of `.tf`, so they're readable/copyable in the chat UI.** Rename to `.tf` only at actual `terraform apply` time, or keep a symlink/copy step in the workflow.
- Terraform state should only ever contain: the ArgoCD install, and (if used) the single root Application. Re-running `terraform apply` should never touch cert-manager/Rancher/NetBird resources — if it would, something's leaking out of scope and needs fixing.

### Phase 2 — Git repo content (ArgoCD's domain, not Terraform's)

Structure as an "app of apps": a root `Application` (installed by Terraform in Phase 1) that points at a directory containing child `Application` manifests, e.g.:

```
gitops-repo/
  root-app.yaml            # what Terraform points ArgoCD at
  apps/
    cert-manager.yaml       # child Application → cert-manager Helm chart
    rancher.yaml             # child Application → Rancher Helm chart (host: rancher.arec.me)
    netbird.yaml              # child Application → NetBird manifests/Helm (host: netbird.arec.me, Google OIDC)
  cert-manager/
    values.yaml
  rancher/
    values.yaml
  netbird/
    values.yaml
```

- **cert-manager** deployed first (or with a sync-wave ordering) since Rancher and NetBird both depend on it for TLS.
- **Rancher** Helm values set `hostname: rancher.arec.me`.
- **NetBird** Helm values set the dashboard/management hostname to `netbird.arec.me` and OIDC config pointing at Google (issuer URL, client ID — reference a Secret, never inline the client secret in git).
- Use ArgoCD **sync waves** (`argocd.argoproj.io/sync-wave` annotations) to sequence cert-manager before Rancher/NetBird if dependency ordering matters.

### Phase 3 — Verification

- Confirm ArgoCD shows all child Applications `Synced`/`Healthy`.
- Confirm `https://rancher.arec.me` and `https://netbird.arec.me` are both reachable with valid TLS.
- Confirm Google OIDC login works end-to-end on the NetBird dashboard.

### Phase 4 — WireGuard networking specifics to verify post-deploy

- UDP port 51820 (or whatever NetBird's relay/signal uses) reachable from client networks. Since this is a single Docker-only machine with no cloud load balancer, expect **NodePort or hostNetwork** for the WireGuard-facing service, with the actual port opened at the OS firewall (ufw/iptables) and any router/NAT layer in front of it. Flag explicitly for the user to confirm.
- Management API (gRPC, typically 33073) and dashboard (443) exposed via Ingress.

## Guardrails for the agent

- **Terraform's scope is ArgoCD only (plus, optionally, the single root Application).** It must never directly manage cert-manager, Rancher, or NetBird resources — those belong entirely to ArgoCD via the GitOps repo. If a task seems to require Terraform to touch one of those, that's a signal the design has drifted — stop and flag it instead of proceeding.
- Never put secrets (Google OAuth client secret, WireGuard keys, TLS private keys) directly in Terraform `.tfvars` files or in the GitOps repo in plaintext — use a secret manager, `sealed-secrets`/`external-secrets`, or at minimum a `.gitignore`'d/manually-applied Secret, and say so explicitly if the user's repo doesn't already have a secrets strategy.
- Confirm firewall/security-group changes (UDP 51820 open to the internet) explicitly with the user before applying — this is a deliberately exposed port and worth a sanity check.
- Rancher's first-run admin bootstrap being driven by ArgoCD (not an interactive `kubectl` session) needs a concrete non-interactive plan — don't hand-wave it.

## Resolved decisions (do not re-ask)

- [x] Domain/hostnames: Rancher → `rancher.arec.me`, NetBird → `netbird.arec.me`
- [x] IdP: Google OIDC — final decision, no Zitadel fallback
- [x] Starting state: Docker-only machine; k3s installed via script, ArgoCD via Terraform, everything else via ArgoCD GitOps
- [x] Terraform scope: ArgoCD install (+ optionally the root "app of apps" Application) — nothing more

## Open questions to resolve with the user before writing code

- [ ] Single node or multi-node cluster (confirms k3s is the right choice)?
single node this computer is the only node, for now
- [ ] Public IP directly reachable, or NAT/port-forwarding needed?
Yes 
- [ ] Git repo URL for the GitOps "app of apps" structure — create new or use existing infra repo?
Create new git repo i will then link the origin to my github project
- [ ] Secrets strategy for the GitOps repo (sealed-secrets, external-secrets, or manual apply) — needed for Google OAuth client secret and Rancher bootstrap password
sealed secrets 
- [ ] Let's Encrypt staging vs prod issuer to start with?
Lets encrypt
- [ ] Google Cloud project to use for the OAuth Client ID (existing project or new one)?
Tell me where to go in this stage and how to generate the client id i will follow the instructions
- [ ] Confirm exact WireGuard/relay UDP port(s) NetBird's chosen version uses, and how they'll be exposed (NodePort + firewall rule, given no cloud LB on a single Docker host)?
The docker has public ip so run it on top of that 
- [ ] Sync-wave/ordering plan: does cert-manager strictly need to be Synced before Rancher/NetBird apps sync, or does ArgoCD's retry handle eventual consistency fine?
OK i dont really know you figure this out and include me in the process


Keep a log of every activity you do explaing what has been done so far in md files
