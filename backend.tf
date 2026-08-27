terraform {
  backend "azurerm" {
    resource_group_name  = "RG-TerraformState"
    storage_account_name = "tfstatentfslab07"
    container_name       = "tfstate"
    key                  = "aum-lab.tfstate"
  }
}