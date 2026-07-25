# The one deliberate exception to "Terraform never touches ArgoCD-managed
# resources": this Application CR is what *hands control over* to ArgoCD.
# Everything it points at (apps/cert-manager.yaml, apps/netbird.yaml, and any
# future child Applications) is then entirely ArgoCD's domain. Re-running
# `terraform apply` only ever reconciles this one CR back to the block below
# -- it never reaches into cert-manager or NetBird resources themselves.

resource "kubectl_manifest" "root_app" {
  count = var.create_root_app ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root-app"
      namespace = var.argocd_namespace
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_repo_revision
        path           = var.gitops_repo_path
        directory = {
          recurse = true
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.argocd_namespace
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
        ]
      }
    }
  })

  depends_on = [helm_release.argocd]
}
