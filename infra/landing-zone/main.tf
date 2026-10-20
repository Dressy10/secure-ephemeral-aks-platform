# Landing zone: Azure Policy guardrails + hard $50 budget.

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
  backend "azurerm" {} # supplied via -backend-config (see Makefile / CI)
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}

variable "subscription_id" { type = string }
variable "allowed_locations" {
  type    = list(string)
  default = ["uksouth", "ukwest"]
}
variable "allowed_vm_skus" {
  description = "VM sizes allowed anywhere in scope (AKS node pools are VMSS, so this caps compute cost)."
  type        = list(string)
  default     = ["Standard_B2s", "Standard_B2ms", "Standard_B2s_v2", "Standard_B2as_v2"]
}
variable "required_tags" {
  type    = list(string)
  default = ["project", "owner", "env"]
}
variable "policy_enforce" {
  description = "false = audit only (DoNotEnforce). Review compliance, then flip to true."
  type        = bool
  default     = false
}
variable "budget_amount" {
  type    = number
  default = 50
}
variable "budget_contacts" { type = list(string) }

data "azurerm_subscription" "current" {
  subscription_id = var.subscription_id
}

# Look up built-ins by display name rather than hard-coding GUIDs.
data "azurerm_policy_definition" "allowed_locations" { display_name = "Allowed locations" }
data "azurerm_policy_definition" "allowed_vm_skus" { display_name = "Allowed virtual machine size SKUs" }
data "azurerm_policy_definition" "require_tag_rg" { display_name = "Require a tag on resource groups" }
data "azurerm_policy_definition" "storage_no_public" { display_name = "Storage account public access should be disallowed" }

locals {
  scope = data.azurerm_subscription.current.id
  mode  = var.policy_enforce
}

resource "azurerm_subscription_policy_assignment" "locations" {
  name                 = "idp-allowed-locations"
  subscription_id      = local.scope
  policy_definition_id = data.azurerm_policy_definition.allowed_locations.id
  enforce              = local.mode
  parameters = jsonencode({
    listOfAllowedLocations = { value = var.allowed_locations }
  })
}

resource "azurerm_subscription_policy_assignment" "vm_skus" {
  name                 = "idp-allowed-vm-skus"
  subscription_id      = local.scope
  policy_definition_id = data.azurerm_policy_definition.allowed_vm_skus.id
  enforce              = local.mode
  parameters = jsonencode({
    listOfAllowedSKUs = { value = var.allowed_vm_skus }
  })
}

# One assignment per required tag (the built-in takes a single tag name).
resource "azurerm_subscription_policy_assignment" "require_tag_rg" {
  for_each             = toset(var.required_tags)
  name                 = "idp-rg-tag-${each.key}"
  subscription_id      = local.scope
  policy_definition_id = data.azurerm_policy_definition.require_tag_rg.id
  enforce              = local.mode
  parameters = jsonencode({
    tagName = { value = each.key }
  })
}

resource "azurerm_subscription_policy_assignment" "storage_no_public" {
  name                 = "idp-storage-no-public"
  subscription_id      = local.scope
  policy_definition_id = data.azurerm_policy_definition.storage_no_public.id
  enforce              = local.mode
}

# ---------- Budget ----------
resource "azurerm_consumption_budget_subscription" "main" {
  name            = "idp-monthly-budget"
  subscription_id = local.scope
  amount          = var.budget_amount
  time_grain      = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00'Z'", timestamp())
  }

  # $25 and $40 of a $50 budget = 50% and 80%
  dynamic "notification" {
    for_each = { half = 50, eighty = 80 }
    content {
      enabled        = true
      threshold      = notification.value
      threshold_type = "Actual"
      operator       = "GreaterThanOrEqualTo"
      contact_emails = var.budget_contacts
    }
  }

  notification {
    enabled        = true
    threshold      = 100
    threshold_type = "Forecasted"
    operator       = "GreaterThanOrEqualTo"
    contact_emails = var.budget_contacts
  }

  lifecycle {
    ignore_changes = [time_period] # start_date is derived from timestamp(); don't churn the plan
  }
}

# oidc smoke test
