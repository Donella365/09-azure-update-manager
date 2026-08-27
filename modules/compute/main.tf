variable "location"            { type = string }
variable "resource_group_name" { type = string }
variable "subnet_id"           { type = string }
variable "admin_username"      { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "domain_name"    { type = string }
variable "domain_netbios" { type = string }

resource "azurerm_public_ip" "dc01" {
  name                = "pip-dc01"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}
resource "azurerm_public_ip" "ws01" {
  name                = "pip-ws01"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}
resource "azurerm_public_ip" "ws02" {
  name                = "pip-ws02"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "dc01" {
  name                = "nic-dc01"
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_configuration {
    name                           = "internal"
    subnet_id                      = var.subnet_id
    private_ip_address_allocation  = "Static"
    private_ip_address             = "10.0.1.4"
    public_ip_address_id           = azurerm_public_ip.dc01.id
  }
}
resource "azurerm_network_interface" "ws01" {
  name                = "nic-ws01"
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ws01.id
  }
  depends_on = [azurerm_network_interface.dc01]
}
resource "azurerm_network_interface" "ws02" {
  name                = "nic-ws02"
  location            = var.location
  resource_group_name = var.resource_group_name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ws02.id
  }
  depends_on = [azurerm_network_interface.dc01]
}

# DC01 and WS02 use the Gen2 image (their sizes support it).
# WS01's size (Standard_D2_v3) only supports Gen1, so it gets the Gen1 SKU.
# patch_mode = AutomaticByPlatform + bypass_platform_safety_checks are REQUIRED
# for Azure Update Manager's scheduled maintenance assignments to accept the VM —
# Terraform's default patch_mode (AutomaticByOS) is rejected by the Maintenance
# Assignment resource with a 400 error.
resource "azurerm_windows_virtual_machine" "dc01" {
  name                                                    = "DC01"
  location                                                = var.location
  resource_group_name                                     = var.resource_group_name
  size                                                     = "Standard_D2s_v3"
  admin_username                                           = var.admin_username
  admin_password                                           = var.admin_password
  network_interface_ids                                    = [azurerm_network_interface.dc01.id]
  patch_mode                                               = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled   = true
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-g2"
    version   = "latest"
  }
}
resource "azurerm_windows_virtual_machine" "ws01" {
  name                                                    = "WS01"
  location                                                = var.location
  resource_group_name                                     = var.resource_group_name
  size                                                     = "Standard_D2_v3"
  admin_username                                           = var.admin_username
  admin_password                                           = var.admin_password
  network_interface_ids                                    = [azurerm_network_interface.ws01.id]
  patch_mode                                               = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled   = true
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }
}
resource "azurerm_windows_virtual_machine" "ws02" {
  name                                                    = "WS02"
  location                                                = var.location
  resource_group_name                                     = var.resource_group_name
  size                                                     = "Standard_D2as_v4"
  admin_username                                           = var.admin_username
  admin_password                                           = var.admin_password
  network_interface_ids                                    = [azurerm_network_interface.ws02.id]
  patch_mode                                               = "AutomaticByPlatform"
  bypass_platform_safety_checks_on_user_schedule_enabled   = true
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-g2"
    version   = "latest"
  }
}

# LAB ONLY: DSRM password hardcoded here. Never do this in production —
# this specific value is only used once during forest creation and never reused.
resource "azurerm_virtual_machine_extension" "setup_dc" {
  name                 = "SetupDC"
  virtual_machine_id   = azurerm_windows_virtual_machine.dc01.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"
  settings = jsonencode({ commandToExecute = join(" ", [
    "powershell -ExecutionPolicy Unrestricted -Command",
    "\"Install-WindowsFeature AD-Domain-Services -IncludeManagementTools;",
    "Import-Module ADDSDeployment;",
    "Install-ADDSForest -DomainName '${var.domain_name}'",
    "-DomainNetBiosName '${var.domain_netbios}'",
    "-SafeModeAdministratorPassword (ConvertTo-SecureString 'P@ssw0rd123!' -AsPlainText -Force)",
    "-InstallDns -Force\""
  ]) })
}

# Domain join with a bounded DNS wait, an extra 60s buffer for AD DS services
# to fully stabilize after DNS resolves, and up to 5 retries on the actual
# Add-Computer call. Plain DNS resolution isn't proof AD is ready to accept
# a join yet — this is the fix for the timing failure WS02 hit.
locals {
  join_cmd = join(" ", [
    "powershell -ExecutionPolicy Unrestricted -Command",
    "\"$a=Get-NetAdapter|?{$_.Status -eq 'Up'}|Select -First 1;",
    "Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ServerAddresses '10.0.1.4';",
    "$retries=0;$resolved=$false;",
    "do{Start-Sleep 15;$retries++;$resolved=[bool](Resolve-DnsName '${var.domain_name}' -ErrorAction SilentlyContinue)}until($resolved -or $retries -ge 20);",
    "Start-Sleep 60;",
    "$joined=$false;$attempt=0;",
    "do{try{Add-Computer -DomainName '${var.domain_name}'",
    "-Credential (New-Object PSCredential('${var.domain_netbios}\\${var.admin_username}',",
    "(ConvertTo-SecureString '${var.admin_password}' -AsPlainText -Force)))",
    "-Restart -Force -ErrorAction Stop;$joined=$true}",
    "catch{Start-Sleep 30;$attempt++}}until($joined -or $attempt -ge 5)\""
  ])
}
resource "azurerm_virtual_machine_extension" "join_ws01" {
  name                  = "JoinDomain"
  virtual_machine_id    = azurerm_windows_virtual_machine.ws01.id
  publisher             = "Microsoft.Compute"
  type                  = "CustomScriptExtension"
  type_handler_version  = "1.10"
  settings              = jsonencode({ commandToExecute = local.join_cmd })
  depends_on            = [azurerm_virtual_machine_extension.setup_dc]
}
resource "azurerm_virtual_machine_extension" "join_ws02" {
  name                  = "JoinDomain"
  virtual_machine_id    = azurerm_windows_virtual_machine.ws02.id
  publisher             = "Microsoft.Compute"
  type                  = "CustomScriptExtension"
  type_handler_version  = "1.10"
  settings              = jsonencode({ commandToExecute = local.join_cmd })
  depends_on            = [azurerm_virtual_machine_extension.setup_dc]
}

output "dc01_id"        { value = azurerm_windows_virtual_machine.dc01.id }
output "ws01_id"        { value = azurerm_windows_virtual_machine.ws01.id }
output "ws02_id"        { value = azurerm_windows_virtual_machine.ws02.id }
output "dc01_public_ip" { value = azurerm_public_ip.dc01.ip_address }
output "ws01_public_ip" { value = azurerm_public_ip.ws01.ip_address }
output "ws02_public_ip" { value = azurerm_public_ip.ws02.ip_address }