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
