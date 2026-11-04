locals {
  # One JSON log line per request from the API: {"ts":..,"level":..,"path":..,"status":503,...}
  q_5xx = <<-KQL
    ContainerLogV2
    | where PodNamespace == "${var.app_namespace}" and ContainerName == "api"
    | extend j = parse_json(LogMessage)
    | where isnotnull(j.status) and toint(j.status) >= 500
  KQL
}

resource "azurerm_monitor_action_group" "email" {
  name                = "ag-storesales"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "salesalert"
  email_receiver {
    name                    = "team"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# The "log-based metric": counts API log lines whose JSON status is >= 500.
resource "azurerm_log_analytics_saved_search" "five_xx" {
  name                       = "http5xxcount"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  category                   = "Milestone6"
  display_name               = "HTTP 5xx count (API, 5-minute bins)"
  query                      = "${local.q_5xx} | summarize errors = count() by bin(TimeGenerated, 5m)"
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "five_xx" {
  name                 = "alert-api-5xx"
  display_name         = "API returned HTTP 5xx"
  description          = "Fires when at least one API log line has status >= 500 in a 5-minute window."
  resource_group_name  = azurerm_resource_group.rg.name
  location             = azurerm_resource_group.rg.location
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  scopes               = [azurerm_log_analytics_workspace.law.id]
  severity             = 2
  enabled              = true

  criteria {
    query                   = local.q_5xx
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }
}

resource "random_uuid" "workbook" {}

resource "azurerm_application_insights_workbook" "dash" {
  name                = random_uuid.workbook.result
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  display_name        = "Store Sales Forecasting - errors and resources"
  source_id           = lower(azurerm_log_analytics_workspace.law.id)

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type    = 1
        content = { json = "## Store Sales Forecasting: errors and resource usage\nAPI HTTP 5xx counts from JSON logs, plus container CPU and memory." }
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          title         = "HTTP 5xx errors (5-minute bins)"
          query         = "${local.q_5xx} | summarize errors = count() by bin(TimeGenerated, 5m)"
          size          = 1
          timeContext   = { durationMs = 3600000 }
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "columnchart"
        }
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          title         = "API requests by status code"
          query         = "ContainerLogV2 | where PodNamespace == \"${var.app_namespace}\" and ContainerName == \"api\" | extend j = parse_json(LogMessage) | where isnotnull(j.status) | summarize requests = count() by status = tostring(j.status)"
          size          = 1
          timeContext   = { durationMs = 3600000 }
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "piechart"
        }
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          title         = "Container CPU (cores)"
          query         = "Perf | where ObjectName == \"K8SContainer\" and CounterName == \"cpuUsageNanoCores\" | summarize cores = avg(CounterValue) / 1e9 by bin(TimeGenerated, 5m), InstanceName"
          size          = 1
          timeContext   = { durationMs = 3600000 }
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "timechart"
        }
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          title         = "Container memory (MiB)"
          query         = "Perf | where ObjectName == \"K8SContainer\" and CounterName == \"memoryWorkingSetBytes\" | summarize MiB = avg(CounterValue) / 1048576 by bin(TimeGenerated, 5m), InstanceName"
          size          = 1
          timeContext   = { durationMs = 3600000 }
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "timechart"
        }
      }
    ]
  })
}

# ---------------------------------------------------------------- budget guardrail
resource "azurerm_consumption_budget_resource_group" "budget" {
  name              = "m6-budget"
  resource_group_id = azurerm_resource_group.rg.id
  amount            = var.budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }
  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }
  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }
}
