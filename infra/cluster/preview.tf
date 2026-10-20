# Least-privilege access for the PR preview workflow (identity gh-idp-preview, created in bootstrap).
# It can push images, fetch cluster credentials, and write only inside the `previews` namespace.
# It has no cluster-wide rights and cannot create namespaces: all previews share `previews`,
# with per-PR resources suffixed and labelled pr-<N> (see ADR 0002).

variable "preview_principal_id" {
  description = "Object ID of the gh-idp-preview service principal (bootstrap output preview_object_id). Empty disables preview access."
  type        = string
  default     = ""
}

locals {
  preview_roles = var.preview_principal_id == "" ? {} : {
    acr_push     = { scope = azurerm_container_registry.acr.id, role = "AcrPush" }
    cluster_user = { scope = azurerm_kubernetes_cluster.aks.id, role = "Azure Kubernetes Service Cluster User Role" }
    ns_writer    = { scope = "${azurerm_kubernetes_cluster.aks.id}/namespaces/previews", role = "Azure Kubernetes Service RBAC Writer" }
    rg_reader    = { scope = azurerm_resource_group.platform.id, role = "Reader" }
  }
}

resource "azurerm_role_assignment" "preview" {
  for_each             = local.preview_roles
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = var.preview_principal_id
}
