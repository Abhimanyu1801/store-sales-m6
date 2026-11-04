terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    time    = { source = "hashicorp/time", version = "~> 0.12" }
  }
}

provider "azurerm" {
  subscription_id     = var.subscription_id
  storage_use_azuread = true # storage has key auth disabled
  features {
    key_vault {
      purge_soft_delete_on_destroy = true # lets us destroy and recreate with the same vault name
    }
  }
}
