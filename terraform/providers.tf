terraform {
  required_version = ">= 1.5.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    # Used only for the root Application CR. The plain hashicorp/kubernetes
    # `kubernetes_manifest` resource validates against the target CRD's
    # OpenAPI schema at plan time, which doesn't exist yet on a fresh
    # cluster until the ArgoCD helm_release below has applied -- a
    # chicken-and-egg problem in a single apply. kubectl_manifest applies
    # raw YAML with no such pre-validation, so it works in the same apply
    # as the CRD-installing helm_release.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
}
