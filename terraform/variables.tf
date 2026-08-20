variable "kubeconfig_path" {
  description = "Path to the kubeconfig for the k3s cluster (installed outside Terraform's scope, in Phase 0)"
  type        = string
  default     = "~/.kube/config"
}

variable "argocd_namespace" {
  description = "Namespace ArgoCD is installed into"
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "Pinned version of the argo-cd Helm chart (argoproj.github.io/argo-helm) -- bump deliberately, never float. Latest as of 2026-07-25: 10.2.1 (app v3.4.5)."
  type        = string
  default     = "10.2.1"
}

variable "gitops_repo_url" {
  description = "Git repo URL the root ArgoCD Application (app-of-apps) watches. This is the single source of truth ArgoCD manages everything else from -- cert-manager, NetBird, and any future workloads."
  type        = string
}

variable "gitops_repo_revision" {
  description = "Branch/ref ArgoCD tracks in the GitOps repo"
  type        = string
  default     = "main"
}

variable "gitops_repo_path" {
  description = "Path within the GitOps repo containing child Application manifests. The repo root is the whole personal-server project dir (task.md, terraform/, logs/ live alongside it), so this points at the gitops/ subdirectory, not the repo root."
  type        = string
  default     = "gitops/apps"
}

variable "create_root_app" {
  description = "Whether to create the root app-of-apps Application. Leave false until the GitOps repo has real content pushed to gitops_repo_url -- ArgoCD will otherwise sit in a permanent error state trying to sync a repo/path that doesn't exist yet. Flip to true and re-apply once the repo is pushed."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# GitHub credentials. Both of the below are for the SAME GitHub account
# (arestrepo99) but are deliberately two different credentials with two
# different jobs:
#   - the deploy key below lets ArgoCD *clone the GitOps repo* (git/SSH);
#   - the PAT lets the *cluster's container runtime pull images from GHCR*
#     (registry/HTTPS). Kubelet cannot use an SSH key for a registry pull.
# Set the secret ones in terraform/secrets.auto.tfvars, which is gitignored --
# see terraform/secrets.auto.tfvars.example.
# ---------------------------------------------------------------------------

variable "gitops_repo_ssh_key_path" {
  description = "Path to the SSH private key ArgoCD uses to clone gitops_repo_url. Kept outside the repo (in ~/.ssh) so the key material never lands in git; only this path does."
  type        = string
  default     = "~/.ssh/github_personal_server"
}

variable "github_username" {
  description = "GitHub username that owns the private GHCR packages (same account as the GitOps repo deploy key)."
  type        = string
  default     = "arestrepo99"
}

variable "github_token" {
  description = "GitHub PAT with the read:packages scope, used only to pull private images from ghcr.io. Never commit this -- set it in terraform/secrets.auto.tfvars (gitignored). Leave empty to skip creating the pull secret entirely, which is correct if every image is a public package."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ghcr_namespaces" {
  description = "Namespaces that get a copy of the `ghcr` imagePullSecret. A Secret is namespace-scoped, so every namespace running a private GHCR image needs its own copy -- add the namespace here when you add such an app, and reference it as `imagePullSecrets: [ghcr]` in the app's chart values."
  type        = list(string)
  default     = ["cup"]
}
