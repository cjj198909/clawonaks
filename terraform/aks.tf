resource "azurerm_kubernetes_cluster" "openclaw" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = data.azurerm_resource_group.main.name
  dns_prefix          = "openclaw"
  kubernetes_version  = "1.32"

  default_node_pool {
    name                        = "system"
    vm_size                     = "Standard_D2s_v3"
    node_count                  = 1
    os_sku                      = "AzureLinux"
    vnet_subnet_id              = azurerm_subnet.aks.id
    temporary_name_for_rotation = "systemtmp"
  }

  identity {
    type = "SystemAssigned"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  network_profile {
    network_plugin = "azure"
    service_cidr   = "10.1.0.0/16"
    dns_service_ip = "10.1.0.10"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.openclaw.id
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }
}
