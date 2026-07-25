output "argocd_namespace" {
  value = kubernetes_namespace.argocd.metadata[0].name
}

output "argocd_initial_admin_password_command" {
  description = "Run this to retrieve ArgoCD's auto-generated initial admin password"
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

output "argocd_port_forward_command" {
  value = "kubectl -n ${var.argocd_namespace} port-forward svc/argocd-server 8080:443"
}
