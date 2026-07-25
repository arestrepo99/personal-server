# ============================================================================
# Terraform's ENTIRE scope in this project: install ArgoCD (+ optionally the
# root app-of-apps Application in root-app.tf.txt). Nothing else. cert-manager,
# NetBird, and everything downstream is ArgoCD's problem via GitOps, not
# Terraform's. If a future change seems to require adding a resource here for
# cert-manager/NetBird/anything else ArgoCD should own, that's a signal the
# design has drifted -- stop and put it in the GitOps repo instead.
# ============================================================================

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = kubernetes_namespace.argocd.metadata[0].name
  create_namespace = false

  # ArgoCD server runs in "insecure" mode (plain HTTP inside the cluster) --
  # not exposed via Ingress/public hostname, since task.md never asked for a
  # public ArgoCD UI. Reach it via `kubectl -n argocd port-forward svc/argocd-server 8080:443`.
  # If a public ArgoCD hostname is wanted later, that Ingress belongs in the
  # GitOps repo (ArgoCD managing its own Ingress), not here.
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  timeout = 600
  wait    = true
}
