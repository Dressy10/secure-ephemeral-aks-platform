# GitOps: AKS-managed Flux, pulling this (public) repo anonymously over HTTPS. No deploy keys, no tokens.

variable "gitops_repo_url" {
  type    = string
  default = "https://github.com/Dressy10/secure-ephemeral-aks-platform"
}
variable "gitops_branch" {
  type    = string
  default = "main"
}

resource "azurerm_kubernetes_cluster_extension" "flux" {
  name           = "flux"
  cluster_id     = azurerm_kubernetes_cluster.aks.id
  extension_type = "microsoft.flux"
}

resource "azurerm_kubernetes_flux_configuration" "platform" {
  name       = "platform"
  cluster_id = azurerm_kubernetes_cluster.aks.id
  namespace  = "flux-system"
  scope      = "cluster"

  git_repository {
    url                      = var.gitops_repo_url
    reference_type           = "branch"
    reference_value          = var.gitops_branch
    sync_interval_in_seconds = 60
  }

  kustomizations {
    name                       = "infra"
    path                       = "./gitops/clusters/dev"
    sync_interval_in_seconds   = 60
    garbage_collection_enabled = true
  }

  depends_on = [azurerm_kubernetes_cluster_extension.flux]
}
