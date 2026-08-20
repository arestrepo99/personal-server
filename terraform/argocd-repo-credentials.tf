# Private repo -> ArgoCD needs its own git credentials to clone it (separate
# from the ubuntu user's SSH agent). Reuses the same deploy key already
# generated for `git push` (~/.ssh/github_personal_server) rather than
# minting a second keypair -- one deploy key with write access on the GitHub
# repo covers both the human push and ArgoCD's read-only clone.
#
# This lives in Terraform (not the GitOps repo) deliberately: ArgoCD needs
# repo read access before it can even fetch the first manifest from that
# repo, including the SealedSecret files inside it -- a chicken-and-egg
# problem sealed-secrets can't solve for this one credential. This is
# bootstrap-layer, same class of exception as the root Application.
resource "kubernetes_secret" "gitops_repo_creds" {
  metadata {
    name      = "gitops-repo-creds"
    namespace = var.argocd_namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type          = "git"
    url           = var.gitops_repo_url
    sshPrivateKey = file(pathexpand(var.gitops_repo_ssh_key_path))
  }

  depends_on = [helm_release.argocd]
}
