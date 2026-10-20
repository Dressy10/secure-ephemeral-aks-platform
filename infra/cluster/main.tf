# Ephemeral compute: ACR + a single-node AKS cluster. Created by `up`, destroyed by `down`.
# State lives in its own key so the cluster can be destroyed without touching the landing zone.

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}

variable "subscription_id" { type = string }
variable "location" {
  type    = string
  default = "uksouth"
}
variable "node_vm_size" {
  description = "Must be in the landing-zone allowed SKU list."
  type        = string
  default     = "Standard_B2s"
}
variable "tags" {
  type = map(string)
  default = {
    project = "idp-platform"
    owner   = "platform"
    env     = "dev"
  }
}

resource "random_string" "acr" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "platform" {
  name     = "rg-idp-platform"
  location = var.location
  tags     = var.tags
}

# ACR Basic ~ $5/month. It persists across cluster cycles in a real setup; here it is cheap enough to cycle too.
resource "azurerm_container_registry" "acr" {
  name                          = "acridp${random_string.acr.result}"
  resource_group_name           = azurerm_resource_group.platform.name
  location                      = azurerm_resource_group.platform.location
  sku                           = "Basic"
  admin_enabled                 = false # no registry passwords; pulls use the kubelet identity
  anonymous_pull_enabled        = false
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-idp-dev"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  dns_prefix          = "idp-dev"
  sku_tier            = "Free" # free control plane
  tags                = var.tags

  local_account_disabled    = true # no static admin kubeconfig
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.me.tenant_id
  }

  default_node_pool {
    name                 = "system"
    vm_size              = var.node_vm_size
    node_count           = 1
    os_disk_size_gb      = 32
    os_disk_type         = "Managed"
    auto_scaling_enabled = false
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
  }
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

data "azurerm_client_config" "me" {}

# The human running `up` can administer the cluster through Entra RBAC.
resource "azurerm_role_assignment" "cluster_admin" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.me.object_id
}

output "cluster_name" { value = azurerm_kubernetes_cluster.aks.name }
output "resource_group" { value = azurerm_resource_group.platform.name }
output "acr_login_server" { value = azurerm_container_registry.acr.login_server }
output "oidc_issuer_url" { value = azurerm_kubernetes_cluster.aks.oidc_issuer_url }
