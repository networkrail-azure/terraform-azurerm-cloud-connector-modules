################################################################################
# Get current Subscription ID
################################################################################
data "azurerm_subscription" "current" {
}

################################################################################
# Create Function App Dependencies
################################################################################
# Create Storage Account to store Function App
resource "azurerm_storage_account" "cc_function_storage_account" {
  count                           = var.existing_storage_account ? 0 : 1
  name                            = "stccvmss${var.resource_tag}"
  resource_group_name             = var.resource_group
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false

  tags = var.global_tags
}

# Or use an existing storage account
data "azurerm_storage_account" "existing_storage_account" {
  count               = var.existing_storage_account ? 1 : 0
  name                = var.existing_storage_account_name
  resource_group_name = var.existing_storage_account_rg
}

# Create Private Storage Container to upload function zip file
resource "azurerm_storage_container" "cc_function_storage_container" {
  count                 = var.upload_function_app_zip ? 1 : 0
  name                  = "function-zip-container"
  storage_account_id    = local.storage_account_id
  container_access_type = "private"
}

# Create Storage Blob to store function zip file
resource "azurerm_storage_blob" "cc_function_storage_blob" {
  count                  = var.upload_function_app_zip ? 1 : 0
  name                   = "zscaler_cc_function_app.zip"
  storage_account_name   = local.storage_account_name
  storage_container_name = azurerm_storage_container.cc_function_storage_container[0].name
  type                   = "Block"
  source                 = "${path.module}/zscaler_cc_function_app.zip"
  content_md5            = filemd5("${path.module}/zscaler_cc_function_app.zip")
}

# Create the content file share the Function App mounts when content is served
# over the integrated VNet (WEBSITE_CONTENTOVERVNET=1). Azure does not auto-
# create this share when the Storage account is private-only, so create it here.
# Using storage_account_id makes this use the Resource Manager API rather than
# the Storage data plane, so it succeeds even when the data plane is only
# reachable via private endpoint.
resource "azurerm_storage_share" "cc_function_content_share" {
  count              = var.content_over_vnet_enabled && !var.existing_storage_account ? 1 : 0
  name               = local.content_share_name
  storage_account_id = azurerm_storage_account.cc_function_storage_account[0].id
  quota              = 5120
}

# Create App Service Plan
resource "azurerm_service_plan" "vmss_orchestration_app_service_plan" {
  name                = "${var.name_prefix}-ccvmss-${var.resource_tag}-app-service-plan"
  resource_group_name = var.resource_group
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.asp_sku_name

  tags = var.global_tags
}

resource "azurerm_log_analytics_workspace" "vmss_orchestration_log_analytics_workspace" {
  count               = var.existing_log_analytics_workspace ? 0 : 1
  name                = "${var.name_prefix}-ccvmss-${var.resource_tag}-workspace"
  location            = var.location
  resource_group_name = var.resource_group
  sku                 = var.log_analytics_sku
  retention_in_days   = var.log_analytics_retention_days
}

locals {
  storage_account_name                      = var.existing_storage_account ? data.azurerm_storage_account.existing_storage_account[0].name : azurerm_storage_account.cc_function_storage_account[0].name
  storage_account_id                        = var.existing_storage_account ? data.azurerm_storage_account.existing_storage_account[0].id : azurerm_storage_account.cc_function_storage_account[0].id
  storage_account_access_key                = var.existing_storage_account ? data.azurerm_storage_account.existing_storage_account[0].primary_access_key : azurerm_storage_account.cc_function_storage_account[0].primary_access_key
  storage_account_primary_connection_string = var.existing_storage_account ? data.azurerm_storage_account.existing_storage_account[0].primary_connection_string : azurerm_storage_account.cc_function_storage_account[0].primary_connection_string
  log_analytics_workspace_id                = var.existing_log_analytics_workspace ? var.existing_log_analytics_workspace_id : azurerm_log_analytics_workspace.vmss_orchestration_log_analytics_workspace[0].id

  # Base application settings shared by both Function App variants.
  function_app_base_settings = {
    "SUBSCRIPTION_ID"                              = data.azurerm_subscription.current.id
    "MANAGED_IDENTITY"                             = var.managed_identity_client_id
    "RESOURCE_GROUP"                               = var.resource_group
    "VMSS_NAME"                                    = jsonencode(var.vmss_names)
    "TERMINATE_UNHEALTHY_INSTANCES"                = var.terminate_unhealthy_instances
    "VAULT_URL"                                    = var.azure_vault_url
    "CC_URL"                                       = var.cc_vm_prov_url
    "APPLICATIONINSIGHTS_CONNECTION_STRING"        = azurerm_application_insights.vmss_orchestration_app_insights.connection_string
    "ApplicationInsightsAgent_EXTENSION_VERSION"   = "~3"
    "XDT_MicrosoftApplicationInsights_Mode"        = "recommended"
    "WEBSITE_RUN_FROM_PACKAGE"                     = var.upload_function_app_zip ? azurerm_storage_blob.cc_function_storage_blob[0].url : var.zscaler_cc_function_public_url
    "WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID" = var.managed_identity_id
  }

  # Name of the content file share the Function App mounts when serving content
  # over the integrated VNet.
  content_share_name = lower("${var.name_prefix}-ccvmss-${var.resource_tag}-content")

  # When the backing Storage account is private-only, route the content file
  # share over the integrated VNet and pin the share explicitly.
  function_app_content_settings = var.content_over_vnet_enabled ? {
    "WEBSITE_CONTENTOVERVNET"                  = "1"
    "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING" = local.storage_account_primary_connection_string
    "WEBSITE_CONTENTSHARE"                     = local.content_share_name
  } : {}

  # Optional custom DNS servers so the Function App resolves private endpoint
  # records (e.g. the content file share and storage) via a custom/hub resolver.
  # Without this, content-over-VNet mounts resolve to the public IP and fail when
  # Storage public network access is disabled.
  function_app_dns_settings = merge(
    length(var.function_app_dns_servers) > 0 ? { "WEBSITE_DNS_SERVER" = var.function_app_dns_servers[0] } : {},
    length(var.function_app_dns_servers) > 1 ? { "WEBSITE_DNS_ALT_SERVER" = var.function_app_dns_servers[1] } : {},
  )

  function_app_settings = merge(
    local.function_app_base_settings,
    local.function_app_content_settings,
    local.function_app_dns_settings,
  )
}

# Create Application Insights resource
resource "azurerm_application_insights" "vmss_orchestration_app_insights" {
  name                = "${var.name_prefix}-ccvmss-${var.resource_tag}-app-insights"
  location            = var.location
  resource_group_name = var.resource_group
  workspace_id        = local.log_analytics_workspace_id
  application_type    = "web"

  tags = var.global_tags
}


################################################################################
# Create Function App
################################################################################
resource "azurerm_linux_function_app" "vmss_orchestration_app" {
  count               = var.run_manual_sync ? 0 : 1
  name                = "${var.name_prefix}-ccvmss-${var.resource_tag}-function-app"
  resource_group_name = var.resource_group
  location            = var.location

  storage_account_name          = local.storage_account_name
  storage_account_access_key    = local.storage_account_access_key
  service_plan_id               = azurerm_service_plan.vmss_orchestration_app_service_plan.id
  public_network_access_enabled = false
  virtual_network_subnet_id     = var.function_app_subnet_id

  https_only = true

  identity {
    type         = "UserAssigned"
    identity_ids = [var.managed_identity_id]
  }

  app_settings = local.function_app_settings

  site_config {
    application_stack {
      python_version = "3.11"
    }
    application_insights_connection_string = azurerm_application_insights.vmss_orchestration_app_insights.connection_string
    vnet_route_all_enabled                 = var.vnet_route_all_enabled
  }

  lifecycle {
    ignore_changes = [
      app_settings["APPLICATIONINSIGHTS_CONNECTION_STRING"],
      tags["hidden-link: /app-insights-resource-id"],
    ]
  }

  depends_on = [azurerm_storage_share.cc_function_content_share]

  tags = var.global_tags
}

resource "azurerm_linux_function_app" "vmss_orchestration_app_with_manual_sync" {
  count               = var.run_manual_sync ? 1 : 0
  name                = "${var.name_prefix}-ccvmss-${var.resource_tag}-function-app"
  resource_group_name = var.resource_group
  location            = var.location

  storage_account_name          = local.storage_account_name
  storage_account_access_key    = local.storage_account_access_key
  service_plan_id               = azurerm_service_plan.vmss_orchestration_app_service_plan.id
  public_network_access_enabled = false
  virtual_network_subnet_id     = var.function_app_subnet_id

  https_only = true

  identity {
    type         = "UserAssigned"
    identity_ids = [var.managed_identity_id]
  }

  app_settings = local.function_app_settings

  site_config {
    application_stack {
      python_version = "3.11"
    }
    application_insights_connection_string = azurerm_application_insights.vmss_orchestration_app_insights.connection_string
    vnet_route_all_enabled                 = var.vnet_route_all_enabled
  }

  lifecycle {
    ignore_changes = [
      app_settings["APPLICATIONINSIGHTS_CONNECTION_STRING"],
      # Azure automatically adds this tag to link the App Insights resource to
      # the Function App. Ignore it so Terraform does not try to remove it.
      tags["hidden-link: /app-insights-resource-id"],
    ]
  }

  depends_on = [azurerm_storage_share.cc_function_content_share]

  provisioner "local-exec" {
    command = "${var.path_to_scripts}/manual_sync.sh ${data.azurerm_subscription.current.subscription_id} ${var.resource_group} ${azurerm_linux_function_app.vmss_orchestration_app_with_manual_sync[0].name} 2>${var.path_to_scripts}/stderr >${var.path_to_scripts}/stdout; echo $? >${var.path_to_scripts}/exitstatus"
  }

  tags = var.global_tags
}

data "local_file" "manual_sync_exist_status" {
  count    = var.run_manual_sync && fileexists("${var.path_to_scripts}/exitstatus") ? 1 : 0
  filename = "${var.path_to_scripts}/exitstatus"
  depends_on = [
    azurerm_linux_function_app.vmss_orchestration_app_with_manual_sync[0]
  ]
}

################################################################################
# Private Endpoints for Storage Account
################################################################################
resource "azurerm_private_endpoint" "storage_blob" {
  count               = var.existing_storage_account ? 0 : 1
  name                = "${var.name_prefix}-ccvmss-${var.resource_tag}-storage-blob-pe"
  location            = var.location
  resource_group_name = var.resource_group
  subnet_id           = var.storage_private_endpoint_subnet_id

  private_service_connection {
    name                           = "${var.name_prefix}-ccvmss-${var.resource_tag}-storage-blob-psc"
    private_connection_resource_id = azurerm_storage_account.cc_function_storage_account[0].id
    is_manual_connection           = false
    subresource_names              = ["blob"]
  }

  lifecycle {
    ignore_changes = [private_dns_zone_group]
  }

  tags = var.global_tags
}

resource "azurerm_private_endpoint" "storage_file" {
  count               = var.existing_storage_account ? 0 : 1
  name                = "${var.name_prefix}-ccvmss-${var.resource_tag}-storage-file-pe"
  location            = var.location
  resource_group_name = var.resource_group
  subnet_id           = var.storage_private_endpoint_subnet_id

  private_service_connection {
    name                           = "${var.name_prefix}-ccvmss-${var.resource_tag}-storage-file-psc"
    private_connection_resource_id = azurerm_storage_account.cc_function_storage_account[0].id
    is_manual_connection           = false
    subresource_names              = ["file"]
  }

  lifecycle {
    ignore_changes = [private_dns_zone_group]
  }

  tags = var.global_tags
}

resource "azurerm_private_endpoint" "storage_queue" {
  count               = var.existing_storage_account ? 0 : 1
  name                = var.storage_queue_private_endpoint_name
  location            = var.location
  resource_group_name = var.resource_group
  subnet_id           = var.storage_private_endpoint_subnet_id

  private_service_connection {
    name                           = "${var.storage_queue_private_endpoint_name}-psc"
    private_connection_resource_id = azurerm_storage_account.cc_function_storage_account[0].id
    is_manual_connection           = false
    subresource_names              = ["queue"]
  }

  lifecycle {
    ignore_changes = [private_dns_zone_group]
    precondition {
      condition     = var.storage_queue_private_endpoint_name != null
      error_message = "var.storage_queue_private_endpoint_name is required when the module creates a new Storage Account (existing_storage_account = false)."
    }
  }

  tags = var.global_tags
}

resource "azurerm_private_endpoint" "storage_table" {
  count               = var.existing_storage_account ? 0 : 1
  name                = var.storage_table_private_endpoint_name
  location            = var.location
  resource_group_name = var.resource_group
  subnet_id           = var.storage_private_endpoint_subnet_id

  private_service_connection {
    name                           = "${var.storage_table_private_endpoint_name}-psc"
    private_connection_resource_id = azurerm_storage_account.cc_function_storage_account[0].id
    is_manual_connection           = false
    subresource_names              = ["table"]
  }

  lifecycle {
    ignore_changes = [private_dns_zone_group]
    precondition {
      condition     = var.storage_table_private_endpoint_name != null
      error_message = "var.storage_table_private_endpoint_name is required when the module creates a new Storage Account (existing_storage_account = false)."
    }
  }

  tags = var.global_tags
}
