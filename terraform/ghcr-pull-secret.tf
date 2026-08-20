# Registry credentials so the cluster can pull private GHCR packages
# (e.g. ghcr.io/arestrepo99/cup, see charts/app + gitops/apps/cup.yaml).
#
# Why this is in Terraform rather than a SealedSecret in the GitOps repo:
# same bootstrap-layer exception as argocd-repo-credentials.tf. It is a
# credential the cluster needs in order to run the very workloads the GitOps
# repo describes, and it is tied to a machine-local secret (the PAT) rather
# than to anything version-controlled. It is also the only sane home for a
# value that must not be committed.
#
# If a package is public (`./scripts/publish-container.sh --push --public` in
# the cup repo), none of this is needed for it -- leave github_token empty and
# these resources simply aren't created.

locals {
  # Skip everything unless a token was actually supplied. nonsensitive() is
  # required and safe here: for_each rejects sensitive-derived values, and
  # what leaks is only "was a token set at all", never the token itself.
  ghcr_enabled    = nonsensitive(var.github_token != "")
  ghcr_namespaces = local.ghcr_enabled ? toset(var.ghcr_namespaces) : toset([])

  ghcr_dockerconfigjson = jsonencode({
    auths = {
      "ghcr.io" = {
        username = var.github_username
        password = var.github_token
        # Docker clients read `auth` (base64 of user:pass) in preference to
        # the separate fields; set both so every runtime agrees.
        auth = base64encode("${var.github_username}:${var.github_token}")
      }
    }
  })
}

# The Secret is namespace-scoped, and ArgoCD creates these namespaces itself
# (CreateNamespace=true). Terraform creating them first is safe -- ArgoCD
# adopts an existing namespace rather than failing -- and it resolves the
# ordering problem: the pull secret must exist before the first pod schedules,
# but the namespace must exist before the secret.
resource "kubernetes_namespace" "ghcr_consumer" {
  for_each = local.ghcr_namespaces

  metadata {
    name = each.value
  }

  lifecycle {
    # ArgoCD stamps its own tracking labels/annotations on namespaces it
    # adopts; don't fight it on every apply.
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }
}

resource "kubernetes_secret" "ghcr" {
  for_each = local.ghcr_namespaces

  metadata {
    name      = "ghcr"
    namespace = kubernetes_namespace.ghcr_consumer[each.value].metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = local.ghcr_dockerconfigjson
  }
}
