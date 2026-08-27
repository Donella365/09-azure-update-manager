variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "resource_group_id"   { type = string }
variable "dc01_id"             { type = string }
variable "ws01_id"             { type = string }
variable "ws02_id"             { type = string }

# Policy 59efceea = built-in "Configure periodic checking for missing system
# updates on Azure VMs". Assessment only — does not apply patches.
# This is a "Modify" policy, which deploys a Guest Configuration assignment
# under the hood — Azure requires a managed identity + location for that.
resource "azurerm_resource_group_policy_assignment" "aum_assessment" {
  name                 = "aum-periodic-assessment"
  resource_group_id    = var.resource_group_id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/59efceea-0c96-497e-a4a1-4eb2290dac15"
  location             = var.location

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_maintenance_configuration" "weekly" {
  name                     = "aum-weekly-patches"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  scope                    = "InGuestPatch"
  in_guest_user_patch_mode = "User"
  window {
    start_date_time = "2026-09-06 02:00"   # CHANGE THIS to a real future date before you deploy
    time_zone       = "Eastern Standard Time"
    duration        = "03:00"
    recur_every     = "Week"
  }
  install_patches {
    windows { classifications_to_include = ["Critical", "Security", "UpdateRollup"] }
    reboot = "IfRequired"
  }
}

resource "azurerm_maintenance_assignment_virtual_machine" "dc01" {
  location                     = var.location
  maintenance_configuration_id = azurerm_maintenance_configuration.weekly.id
  virtual_machine_id           = var.dc01_id
}
resource "azurerm_maintenance_assignment_virtual_machine" "ws01" {
  location                     = var.location
  maintenance_configuration_id = azurerm_maintenance_configuration.weekly.id
  virtual_machine_id           = var.ws01_id
}
resource "azurerm_maintenance_assignment_virtual_machine" "ws02" {
  location                     = var.location
  maintenance_configuration_id = azurerm_maintenance_configuration.weekly.id
  virtual_machine_id           = var.ws02_id
}