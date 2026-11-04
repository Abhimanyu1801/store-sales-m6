# Identity GitHub Actions uses to deploy. No password or secret: GitHub proves who it is
# with an OIDC token, and this identity trusts only the deploy branch of our repo.
resource "azurerm_user_assigned_identity" "github" {
  name                = "id-github-deploy"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_federated_identity_credential" "github" {
  name                = "github-deploy-branch"
  resource_group_name = azurerm_resource_group.rg.name
  parent_id           = azurerm_user_assigned_identity.github.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_repo}:ref:refs/heads/${var.deploy_branch}"
}

resource "azurerm_role_assignment" "github_rg" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Contributor" # build in ACR, read cluster credentials, deploy
  principal_id         = azurerm_user_assigned_identity.github.principal_id
}
