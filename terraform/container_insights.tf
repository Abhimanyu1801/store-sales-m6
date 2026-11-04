# Container Insights data collection. With msi_auth_for_monitoring_enabled the AKS addon
# only runs the agent; the rule that routes its logs/metrics to Log Analytics must be
# created separately (the Portal/CLI do this implicitly, Terraform does not).
locals {
  ci_streams = [
    "Microsoft-ContainerLogV2",
    "Microsoft-KubeEvents",
    "Microsoft-KubePodInventory",
    "Microsoft-KubeNodeInventory",
    "Microsoft-Perf",
    "Microsoft-InsightsMetrics",
  ]
}

resource "azurerm_monitor_data_collection_rule" "ci" {
  name                = "MSCI-${azurerm_resource_group.rg.location}-${azurerm_kubernetes_cluster.aks.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  kind                = "Linux"

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.law.id
      name                  = "ciworkspace"
    }
  }

  data_flow {
    streams      = local.ci_streams
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = local.ci_streams
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Off"
          enableContainerLogV2   = true
        }
      })
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "ci" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.aks.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.ci.id
}
