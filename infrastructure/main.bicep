@description('Der Standort für alle Ressourcen')
param location string = resourceGroup().location

@description('Der Name des App Service Plans')
param appServicePlanName string = 'asp-bcl-reviewer}'

@description('Der Name der Web App')
param webAppName string = 'app-bcl-reviewer}'

// App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'B2'
    tier: 'Basic'
  }
}

// Web App
resource webApp 'Microsoft.Web/sites@2021-02-01' = {
  name: webAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      pythonVersion: '3.11'
      linuxFxVersion: 'PYTHON|3.11'
      alwaysOn: true
    }
  }
}

// Outputs für die Managed Identity Principal ID (wird für RBAC-Berechtigungen benötigt)
output managedIdentityPrincipalId string = webApp.identity.principalId 
