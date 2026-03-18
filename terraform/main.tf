provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "main" {
  name = var.resource_group
}

# Short suffix for globally-unique Azure resource names
resource "random_id" "suffix" {
  byte_length = 4
}
