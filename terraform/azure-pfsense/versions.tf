terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}

  # azurerm v4 requires the subscription explicitly (it no longer silently
  # inherits the CLI's active subscription). Pinning it here is also a guard:
  # the signed-in account can see more than one subscription, and only this
  # one is in scope for the lab.
  subscription_id = var.subscription_id
}
