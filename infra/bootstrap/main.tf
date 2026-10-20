# Bootstrap: remote-state storage + GitHub OIDC identities.
# Applied once, by hand, with local state. Everything after this uses the remote backend.

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azuread" {}

variable "subscription_id" { type = string }
variable "location" {
  type    = string
  default = "uksouth"
}
variable "github_repo" {
  description = "owner/name of the GitHub repo allowed to authenticate"
  type        = string
}
variable "tags" {
  type = map(string)
  default = {
    project = "idp-platform"
    owner   = "platform"
    env     = "shared"
  }
}

data "azurerm_subscription" "current" {
  subscription_id = var.subscription_id
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# ---------- Remote state ----------
resource "azurerm_resource_group" "state" {
  name     = "rg-idp-tfstate"
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "state" {
  name                            = "stidptfstate${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.state.name
  location                        = azurerm_resource_group.state.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false # Entra ID auth only: no storage keys exist
  tags                            = var.tags

  blob_properties {
    versioning_enabled = true
    delete_retention_policy { days = 14 }
  }
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

# ---------- GitHub OIDC identities ----------
# Two identities so a PR can never change anything:
#   plan  -> Reader + state access, trusted for pull_request and main
#   apply -> Contributor + Resource Policy Contributor, trusted only for the `production` environment
locals {
  identities = {
    plan = {
      subjects = ["repo:${var.github_repo}:pull_request", "repo:${var.github_repo}:ref:refs/heads/main"]
      roles    = ["Reader"]
    }
    apply = {
      subjects = ["repo:${var.github_repo}:environment:production"]
      roles    = ["Contributor", "Resource Policy Contributor"]
    }
  }

  subject_pairs = merge([
    for id, cfg in local.identities : {
      for s in cfg.subjects : "${id}|${s}" => { id = id, subject = s }
    }
  ]...)

  role_pairs = merge([
    for id, cfg in local.identities : {
      for r in cfg.roles : "${id}|${r}" => { id = id, role = r }
    }
  ]...)
}

resource "azuread_application" "gh" {
  for_each     = local.identities
  display_name = "gh-idp-${each.key}"
}

resource "azuread_service_principal" "gh" {
  for_each  = local.identities
  client_id = azuread_application.gh[each.key].client_id
}

resource "azuread_application_federated_identity_credential" "gh" {
  for_each       = local.subject_pairs
  application_id = azuread_application.gh[each.value.id].id
  display_name   = replace(replace("${each.value.id}-${each.value.subject}", ":", "-"), "/", "-")
  issuer         = "https://token.actions.githubusercontent.com"
  audiences      = ["api://AzureADTokenExchange"]
  subject        = each.value.subject
}

resource "azurerm_role_assignment" "sub" {
  for_each             = local.role_pairs
  scope                = data.azurerm_subscription.current.id
  role_definition_name = each.value.role
  principal_id         = azuread_service_principal.gh[each.value.id].object_id
}

# Both identities need the data-plane role to read/write/lock Terraform state.
resource "azurerm_role_assignment" "state" {
  for_each             = local.identities
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_service_principal.gh[each.key].object_id
}

output "tenant_id" { value = data.azurerm_subscription.current.tenant_id }
output "subscription_id" { value = var.subscription_id }
output "plan_client_id" { value = azuread_application.gh["plan"].client_id }
output "apply_client_id" { value = azuread_application.gh["apply"].client_id }
output "backend_config" {
  value = <<-EOT
    resource_group_name  = "${azurerm_resource_group.state.name}"
    storage_account_name = "${azurerm_storage_account.state.name}"
    container_name       = "${azurerm_storage_container.state.name}"
    use_azuread_auth     = true
  EOT
}
