variable "subscription_id" {
  type    = string
  default = "331b9681-cfab-4728-b54c-22d93239c0cc"
}

variable "location" {
  type    = string
  default = "northcentralus" # allowed by the subscription's region policy
}

variable "resource_group_name" {
  type    = string
  default = "m6-storesales-rg"
}

variable "alert_email" {
  type        = string
  description = "Inbox that receives the 5xx alert and budget alerts"
}

variable "aks_vm_size" {
  type    = string
  default = "Standard_B2as_v2" # 2 vCPU / 8 GiB, Basv2 family (regional limit is 6 vCPUs)
}

variable "aks_node_count" {
  type    = number
  default = 2 # 2 x 2 vCPU = 4 of the 6 regional vCPUs
}

variable "pg_sku" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "pg_admin_user" {
  type    = string
  default = "storeadmin"
}

variable "app_namespace" {
  type    = string
  default = "storesales-m5"
}

variable "app_service_account" {
  type    = string
  default = "store-app"
}

variable "budget_amount" {
  type    = number
  default = 60
}

variable "budget_start_date" {
  type        = string
  default     = "2026-11-01T00:00:00Z" # must be the first day of a month
  description = "Budget period start"
}

variable "github_repo" {
  type        = string
  description = "owner/name of the GitHub repo that holds the pipeline, e.g. myuser/store-sales-forecasting"
}

variable "deploy_branch" {
  type    = string
  default = "deploy"
}
